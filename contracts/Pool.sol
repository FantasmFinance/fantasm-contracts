// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interfaces/IXftm.sol";
import "./interfaces/IFantasm.sol";
import "./interfaces/IMasterOracle.sol";
import "./interfaces/IWETH.sol";
import "./libs/WethUtils.sol";

contract Pool is Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IXftm;
    using SafeERC20 for IFantasm;

    struct UserInfo {
        uint256 xftmBalance;
        uint256 fantasmBalance;
        uint256 ftmBalance;
        uint256 lastAction;
    }

    /* ========== ADDRESSES ================ */

    IMasterOracle public oracle;
    IXftm public xftm;
    IFantasm public fantasm;
    address public feeReserve;

    /* ========== STATE VARIABLES ========== */

    mapping(address => UserInfo) public userInfo;

    uint256 public unclaimedFtm;
    uint256 public unclaimedXftm;
    uint256 public unclaimedFantasm;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;
    uint256 private constant PRECISION = 1e6;

    // AccessControl state variables
    bool public mintPaused = false;
    bool public redeemPaused = false;

    uint256 public maxXftmSupply = 100_000_000 ether; // limit the maximum Xftm Supply

    // Collateral ratio
    uint256 public collateralRatio = 1e6;
    uint256 public lastRefreshCrTimestamp;
    uint256 public refreshCooldown = 3600; // = 1 hour
    uint256 public ratioStepUp = 2000; // = 0.002 or 0.2% -> ratioStep when CR increase
    uint256 public ratioStepDown = 1000; // = 0.001 or 0.1% -> ratioStep when CR decrease
    uint256 public priceTarget = 1e18; // = 1; 1 XFTM pegged to the value of 1 FTM
    uint256 public priceBand = 5e15; // = 0.005; CR will be adjusted if XFTM > 1.005 FTM or XFTM < 0.995 FTM
    uint256 public minCollateralRatio = 1e6;
    bool public collateralRatioPaused = false;

    // fees
    uint256 public redemptionFee = 5000; // 6 decimals of precision
    uint256 public constant REDEMPTION_FEE_MAX = 9000; // 0.9%
    uint256 public mintingFee = 3000; // 6 decimals of precision
    uint256 public constant MINTING_FEE_MAX = 5000; // 0.5%

    // zap
    IUniswapV2Router02 public swapRouter;
    address[] public swapPaths;
    uint256 public swapSlippage;
    uint256 private constant SWAP_TIMEOUT = 10 minutes;
    uint256 private constant SLIPPAGE_PRECISION = 1e6;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _xftm, address _fantasm) {
        require(_xftm != address(0), "Pool::initialize: invalidAddress");
        require(_fantasm != address(0), "Pool::initialize: invalidAddress");
        xftm = IXftm(_xftm);
        fantasm = IFantasm(_fantasm);
        xftm.setMinter(address(this));
        fantasm.setPool(address(this));
    }

    /* ========== VIEWS ========== */

    function info()
        external
        view
        returns (
            uint256 _collateralRatio,
            uint256 _lastRefreshCrTimestamp,
            uint256 _mintingFee,
            uint256 _redemptionFee,
            bool _mintingPaused,
            bool _redemptionPaused,
            uint256 _collateralBalance,
            uint256 _maxXftmSupply
        )
    {
        _collateralRatio = collateralRatio;
        _lastRefreshCrTimestamp = lastRefreshCrTimestamp;
        _mintingFee = mintingFee;
        _redemptionFee = redemptionFee;
        _mintingPaused = mintPaused;
        _redemptionPaused = redeemPaused;
        _collateralBalance = usableFtmBalance();
        _maxXftmSupply = maxXftmSupply;
    }

    function usableFtmBalance() public view returns (uint256) {
        uint256 _ftmBalance = WethUtils.weth.balanceOf(address(this));
        return _ftmBalance > unclaimedFtm ? (_ftmBalance - unclaimedFtm) : 0;
    }

    /// @param _ftmIn Amount of FTM input.
    /// @param _fantasmIn Amount of FSM input.
    /// @return _xftmOut : the amount of XFTM output.
    /// @return _minFtmIn : the required amount of FSM input.
    /// @return _minFantasmIn : the required amount of FSM input.
    /// @return _fee : the fee amount in FTM.
    function calcMint(uint256 _ftmIn, uint256 _fantasmIn)
        public
        view
        returns (
            uint256 _xftmOut,
            uint256 _minFtmIn,
            uint256 _minFantasmIn,
            uint256 _fee
        )
    {
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcMint: Invalid Fantasm price");

        if (collateralRatio == COLLATERAL_RATIO_MAX || (collateralRatio > 0 && _ftmIn > 0)) {
            _minFtmIn = _ftmIn;
            _minFantasmIn = (_ftmIn * (COLLATERAL_RATIO_MAX - collateralRatio) * PRICE_PRECISION) / collateralRatio / _fantasmPrice;
            _xftmOut = (_ftmIn * COLLATERAL_RATIO_MAX * (PRECISION - mintingFee)) / collateralRatio / PRECISION;
            _fee = (_ftmIn * mintingFee) / PRECISION;
        } else {
            _minFantasmIn = _fantasmIn;
            _xftmOut = (_fantasmIn * _fantasmPrice * COLLATERAL_RATIO_MAX * (PRECISION - mintingFee)) / PRECISION / (COLLATERAL_RATIO_MAX - collateralRatio) / PRICE_PRECISION;
            _minFtmIn = (_fantasmIn * _fantasmPrice * collateralRatio) / (COLLATERAL_RATIO_MAX - collateralRatio) / PRICE_PRECISION;
            _fee = (_fantasmIn * _fantasmPrice * collateralRatio * mintingFee) / PRECISION / (COLLATERAL_RATIO_MAX - collateralRatio) / PRICE_PRECISION;
        }
    }

    /// @notice Calculate the expected results for zap minting
    /// @param _ftmIn Amount of FTM input.
    /// @return _xftmOut : the amount of XFTM output.
    /// @return _fantasmOut : the amount of Fantasm output by swapping
    /// @return _ftmFee : the fee amount in FTM.
    /// @return _ftmSwapIn : the amount of FTM to swap
    function calcZapMint(uint256 _ftmIn)
        public
        view
        returns (
            uint256 _xftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee,
            uint256 _ftmSwapIn
        )
    {
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcZapMint: Invalid Fantasm price");
        _ftmSwapIn = (_ftmIn * (COLLATERAL_RATIO_MAX - collateralRatio)) / COLLATERAL_RATIO_MAX;
        _fantasmOut = (_ftmSwapIn * PRICE_PRECISION) / _fantasmPrice;
        _ftmFee = (_ftmIn * mintingFee * collateralRatio) / COLLATERAL_RATIO_MAX / PRECISION;
        _xftmOut = _ftmIn - ((_ftmIn * mintingFee) / PRECISION);
    }

    /// @notice Calculate the expected results for redemption
    /// @param _xftmIn Amount of XFTM input.
    /// @return _ftmOut : the amount of FTM output.
    /// @return _fantasmOut : the amount of Fantasm output by swapping
    /// @return _ftmFee : the fee amount in FTM
    /// @return _requiredFtmBalance : required FTM balance in the pool
    function calcRedeem(uint256 _xftmIn)
        public
        view
        returns (
            uint256 _ftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee,
            uint256 _requiredFtmBalance
        )
    {
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcRedeem: Invalid Fantasm price");

        _requiredFtmBalance = (_xftmIn * collateralRatio) / PRECISION;
        if (collateralRatio < COLLATERAL_RATIO_MAX) {
            _fantasmOut = (_xftmIn * (COLLATERAL_RATIO_MAX - collateralRatio) * (PRECISION - redemptionFee) * PRICE_PRECISION) / COLLATERAL_RATIO_MAX / PRECISION / _fantasmPrice;
        }

        if (collateralRatio > 0) {
            _ftmOut = (_xftmIn * collateralRatio * (PRECISION - redemptionFee)) / COLLATERAL_RATIO_MAX / PRECISION;
            _ftmFee = (_xftmIn * collateralRatio * redemptionFee) / COLLATERAL_RATIO_MAX / PRECISION;
        }
    }

    /// @notice Calculate the expected results for minting
    function calcExcessFtmBalance() public view returns (uint256 _delta, bool _exceeded) {
        uint256 _requiredFtmBal = (xftm.totalSupply() * collateralRatio) / COLLATERAL_RATIO_MAX;
        uint256 _usableFtmBal = usableFtmBalance();
        if (_usableFtmBal >= _requiredFtmBal) {
            _delta = _usableFtmBal - _requiredFtmBal;
            _exceeded = true;
        } else {
            _delta = _requiredFtmBal - _usableFtmBal;
            _exceeded = false;
        }
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update collateral ratio and adjust based on the TWAP price of XFTM
    function refreshCollateralRatio() public {
        require(collateralRatioPaused == false, "Pool::refreshCollateralRatio: Collateral Ratio has been paused");
        require(block.timestamp - lastRefreshCrTimestamp >= refreshCooldown, "Pool::refreshCollateralRatio: Must wait for the refresh cooldown since last refresh");

        uint256 _xftmPrice = oracle.getXftmTWAP();
        if (_xftmPrice > priceTarget + priceBand) {
            if (collateralRatio <= ratioStepDown) {
                collateralRatio = 0;
            } else {
                uint256 _newCR = collateralRatio - ratioStepDown;
                if (_newCR <= minCollateralRatio) {
                    collateralRatio = minCollateralRatio;
                } else {
                    collateralRatio = _newCR;
                }
            }
        } else if (_xftmPrice < priceTarget - priceBand) {
            if (collateralRatio + ratioStepUp >= COLLATERAL_RATIO_MAX) {
                collateralRatio = COLLATERAL_RATIO_MAX;
            } else {
                collateralRatio = collateralRatio + ratioStepUp;
            }
        }

        lastRefreshCrTimestamp = block.timestamp;
        emit NewCollateralRatioSet(collateralRatio);
    }

    /// @notice fallback for payable -> required to unwrap WETH
    receive() external payable {}

    /* ========== MUTATIVE FUNCTIONS ========== */

    function mint(uint256 _fantasmIn, uint256 _minXftmOut) external payable nonReentrant {
        require(!mintPaused, "Pool::mint: Minting is paused");
        uint256 _ftmIn = msg.value;
        address _minter = msg.sender;

        (uint256 _xftmOut, , uint256 _minFantasmIn, uint256 _ftmFee) = calcMint(_ftmIn, _fantasmIn);
        require(_minXftmOut <= _xftmOut, "Pool::mint: slippage");
        require(_minFantasmIn <= _fantasmIn, "Pool::mint: Not enough Fantasm input");
        require(maxXftmSupply >= xftm.totalSupply() + _xftmOut, "Pool::mint: > Xftm supply limit");

        WethUtils.wrap(_ftmIn);
        userInfo[_minter].lastAction = block.number;

        if (_xftmOut > 0) {
            userInfo[_minter].xftmBalance = userInfo[_minter].xftmBalance + _xftmOut;
            unclaimedXftm = unclaimedXftm + _xftmOut;
        }

        if (_minFantasmIn > 0) {
            fantasm.safeTransferFrom(_minter, address(this), _minFantasmIn);
            fantasm.burn(_minFantasmIn);
        }

        if (_ftmFee > 0) {
            WethUtils.transfer(feeReserve, _ftmFee);
        }

        emit Mint(_minter, _xftmOut, _ftmIn, _fantasmIn, _ftmFee);
    }

    function zap(uint256 _minXftmOut) external payable nonReentrant {
        require(!mintPaused, "Pool::zap: Minting is paused");
        uint256 _ftmIn = msg.value;
        address _sender = msg.sender;

        (uint256 _xftmOut, uint256 _fantasmOut, uint256 _fee, uint256 _ftmSwapIn) = calcZapMint(_ftmIn);
        require(_xftmOut >= _minXftmOut, "Pool::zap: slippage");

        WethUtils.wrap(_ftmIn);
        if (_fantasmOut > 0 && _ftmSwapIn > 0) {
            uint256 _fantasmReceived = swap(_ftmSwapIn, _fantasmOut);
            fantasm.burn(_fantasmReceived);
        }

        if (_xftmOut > 0) {
            userInfo[_sender].xftmBalance = userInfo[_sender].xftmBalance + _xftmOut;
            unclaimedXftm = unclaimedXftm + _xftmOut;
        }

        if (_fee > 0) {
            WethUtils.transfer(feeReserve, _fee);
        }

        emit ZapMint(_sender, _xftmOut, _ftmIn, _fee);
    }

    function redeem(
        uint256 _xftmIn,
        uint256 _minFantasmOut,
        uint256 _minFtmOut
    ) external nonReentrant {
        require(!redeemPaused, "Pool::redeem: Redeeming is paused");

        address _sender = msg.sender;
        (uint256 _ftmOut, uint256 _fantasmOut, uint256 _fee, uint256 _requiredFtmBalance) = calcRedeem(_xftmIn);

        // Check if collateral balance meets and meet output expectation
        require(_requiredFtmBalance <= usableFtmBalance(), "Pool::redeem: > FTM balance");
        require(_minFtmOut <= _ftmOut && _minFantasmOut <= _fantasmOut, "Pool::redeem: >slippage");

        if (_ftmOut > 0) {
            userInfo[_sender].ftmBalance = userInfo[_sender].ftmBalance + _ftmOut;
            unclaimedFtm = unclaimedFtm + _ftmOut;
        }

        if (_fantasmOut > 0) {
            userInfo[_sender].fantasmBalance = userInfo[_sender].fantasmBalance + _fantasmOut;
            unclaimedFantasm = unclaimedFantasm + _fantasmOut;
        }

        userInfo[_sender].lastAction = block.number;

        // Move all external functions to the end
        IXftm(xftm).burn(_sender, _xftmIn);
        if (_fee > 0) {
            WethUtils.transfer(feeReserve, _fee);
        }

        emit Redeem(_sender, _xftmIn, _ftmOut, _fantasmOut, _fee);
    }

    /**
     * @notice collect all minting and redemption
     */
    function collect() external nonReentrant {
        address _sender = msg.sender;
        require(userInfo[_sender].lastAction < block.number, "Pool::collect: <minimum_delay");

        bool _sendXftm = false;
        bool _sendFantasm = false;
        bool _sendFtm = false;
        uint256 _xftmAmount;
        uint256 _fantasmAmount;
        uint256 _ftmAmount;

        // Use Checks-Effects-Interactions pattern
        if (userInfo[_sender].xftmBalance > 0) {
            _xftmAmount = userInfo[_sender].xftmBalance;
            userInfo[_sender].xftmBalance = 0;
            unclaimedXftm = unclaimedXftm - _xftmAmount;
            _sendXftm = true;
        }

        if (userInfo[_sender].fantasmBalance > 0) {
            _fantasmAmount = userInfo[_sender].fantasmBalance;
            userInfo[_sender].fantasmBalance = 0;
            unclaimedFantasm = unclaimedFantasm - _fantasmAmount;
            _sendFantasm = true;
        }

        if (userInfo[_sender].ftmBalance > 0) {
            _ftmAmount = userInfo[_sender].ftmBalance;
            userInfo[_sender].ftmBalance = 0;
            unclaimedFtm = unclaimedFtm - _ftmAmount;
            _sendFtm = true;
        }

        if (_sendXftm) {
            xftm.mint(_sender, _xftmAmount);
        }

        if (_sendFantasm) {
            fantasm.mint(_sender, _fantasmAmount);
        }

        if (_sendFtm) {
            WethUtils.unwrap(_ftmAmount);
            payable(_sender).transfer(_ftmAmount);
        }
    }

    /// @notice Function to recollateralize the pool by receiving WFTM
    /// @param _amount Amount of WFTM input
    function recollateralize(uint256 _amount) external {
        require(_amount > 0, "Pool::recollateralize: Invalid amount");
        WethUtils.weth.safeTransferFrom(msg.sender, address(this), _amount);
        emit Recollateralized(msg.sender, _amount);
    }

    /// @notice Function to recollateralize the pool by receiving FTM
    function recollateralizeETH() external payable {
        uint256 _amount = msg.value;
        require(_amount > 0, "Pool::recollateralize: Invalid amount");
        WethUtils.wrap(_amount);
        emit Recollateralized(msg.sender, _amount);
    }

    /* ========== INTERNAL FUNCTIONS ============ */

    /// @notice Function to take input FTM to swap to FSM and burn
    /// @param _ftmIn Amount of FTM input
    /// @param _fantasmOut Amount of FSM output expected
    function swap(uint256 _ftmIn, uint256 _fantasmOut) internal returns (uint256 _fsmOut) {
        uint256 _minFantasmOut = (_fantasmOut * (SLIPPAGE_PRECISION - swapSlippage)) / SLIPPAGE_PRECISION;
        WethUtils.weth.safeIncreaseAllowance(address(swapRouter), _ftmIn);
        uint256 _fsmBefore = fantasm.balanceOf(address(this));
        swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(_ftmIn, _minFantasmOut, swapPaths, address(this), block.timestamp + SWAP_TIMEOUT);
        _fsmOut = fantasm.balanceOf(address(this)) - _fsmBefore;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Turn on / off minting and redemption
    /// @param _mintPaused Paused or NotPaused Minting
    /// @param _redeemPaused Paused or NotPaused Redemption
    function toggle(bool _mintPaused, bool _redeemPaused) public onlyOwner {
        mintPaused = _mintPaused;
        redeemPaused = _redeemPaused;
        emit Toggled(_mintPaused, _redeemPaused);
    }

    /// @notice Configure variables related to Collateral Ratio
    /// @param _ratioStepUp Step which Collateral Ratio will be increased each updates
    /// @param _ratioStepDown Step which Collateral Ratio will be decreased each updates
    /// @param _priceBand The collateral ratio will only be adjusted if current price move out of this band
    /// @param _refreshCooldown The minimum delay between each Collateral Ratio updates
    function setCollateralRatioOptions(
        uint256 _ratioStepUp,
        uint256 _ratioStepDown,
        uint256 _priceBand,
        uint256 _refreshCooldown
    ) public onlyOwner {
        ratioStepUp = _ratioStepUp;
        ratioStepDown = _ratioStepDown;
        priceBand = _priceBand;
        refreshCooldown = _refreshCooldown;
        emit NewCollateralRatioOptions(_ratioStepUp, _ratioStepDown, _priceBand, _refreshCooldown);
    }

    /// @notice Pause or unpause collateral ratio updates
    /// @param _collateralRatioPaused `true` or `false`
    function toggleCollateralRatio(bool _collateralRatioPaused) public onlyOwner {
        if (collateralRatioPaused != _collateralRatioPaused) {
            collateralRatioPaused = _collateralRatioPaused;
            emit UpdateCollateralRatioPaused(_collateralRatioPaused);
        }
    }

    /// @notice Set the protocol fees
    /// @param _mintingFee Minting fee in percentage
    /// @param _redemptionFee Redemption fee in percentage
    function setFees(uint256 _mintingFee, uint256 _redemptionFee) public onlyOwner {
        require(_mintingFee <= MINTING_FEE_MAX, "Pool::setFees:>MINTING_FEE_MAX");
        require(_redemptionFee <= REDEMPTION_FEE_MAX, "Pool::setFees:>REDEMPTION_FEE_MAX");
        redemptionFee = _redemptionFee;
        mintingFee = _mintingFee;
        emit FeesUpdated(_mintingFee, _redemptionFee);
    }

    /// @notice Set the minimum Collateral Ratio
    /// @param _minCollateralRatio value of minimum Collateral Ratio in 1e6 precision
    function setMinCollateralRatio(uint256 _minCollateralRatio) external onlyOwner {
        require(_minCollateralRatio <= COLLATERAL_RATIO_MAX, "Pool::setMinCollateralRatio: >COLLATERAL_RATIO_MAX");
        minCollateralRatio = _minCollateralRatio;
        emit MinCollateralRatioUpdated(_minCollateralRatio);
    }

    /// @notice Set the maxium XFTM supply
    /// @param _newValue value of maxium XFTM supply
    function setMaxXftmSupply(uint256 _newValue) external onlyOwner {
        require(_newValue > xftm.totalSupply(), "Pool::setMaxXftmSupply: Cannot smaller than current limit");
        maxXftmSupply = _newValue;
        emit MaxXftmSupplyUpdated(_newValue);
    }

    /// @notice Transfer the excess balance of FTM to FeeReserve
    /// @param _amount amount of FTM to reduce
    function reduceExcessFtm(uint256 _amount) external onlyOwner {
        (uint256 _excessFtmBal, bool exceeded) = calcExcessFtmBalance();
        if (exceeded && _excessFtmBal > 0) {
            require(_amount <= _excessFtmBal, "Pool::reduceExcessFtm: The amount is too large");
            require(address(feeReserve) != address(0), "Pool::reduceExcessFtm: invalid address");
            WethUtils.transfer(address(feeReserve), _amount);
        }
    }

    /// @notice Set the address of FeeReserve
    /// @param _feeReserve address of FeeReserve contract
    function setFeeReserve(address _feeReserve) external {
        require(feeReserve == address(0), "Pool::setFeeReserve: not allowed");
        feeReserve = _feeReserve;
    }

    /// @notice Set new oracle address
    /// @param _oracle address of the oracle
    function setOracle(IMasterOracle _oracle) external onlyOwner {
        require(address(_oracle) != address(0), "Pool::setOracle: invalid address");
        oracle = _oracle;
        emit OracleChanged(address(_oracle));
    }

    /// @notice Config poolHelper parameters
    /// @param _swapRouter Address of DEX router
    /// @param _swapSlippage slippage
    /// @param _swapPaths paths to swap
    function configSwap(
        IUniswapV2Router02 _swapRouter,
        uint256 _swapSlippage,
        address[] memory _swapPaths
    ) external onlyOwner {
        swapRouter = _swapRouter;
        swapSlippage = _swapSlippage;
        swapPaths = _swapPaths;
        emit SwapConfigUpdated(address(_swapRouter), _swapSlippage, _swapPaths);
    }

    // EVENTS
    event OracleChanged(address indexed _oracle);
    event Toggled(bool _mintPaused, bool _redeemPaused);
    event Mint(address minter, uint256 amount, uint256 ftmIn, uint256 fantasmIn, uint256 fee);
    event ZapMint(address minter, uint256 amount, uint256 ftmIn, uint256 fee);
    event Redeem(address redeemer, uint256 amount, uint256 ftmOut, uint256 fantasmOut, uint256 fee);
    event PoolUtilsChanged(address indexed _addr);
    event SwapConfigUpdated(address indexed _router, uint256 _slippage, address[] _paths);
    event UpdateCollateralRatioPaused(bool _collateralRatioPaused);
    event NewCollateralRatioOptions(uint256 _ratioStepUp, uint256 _ratioStepDown, uint256 _priceBand, uint256 _refreshCooldown);
    event MinCollateralRatioUpdated(uint256 _minCollateralRatio);
    event NewCollateralRatioSet(uint256 _cr);
    event FeesUpdated(uint256 _mintingFee, uint256 _redemptionFee);
    event MaxXftmSupplyUpdated(uint256 _value);
    event Recollateralized(address indexed _sender, uint256 _amount);
}
