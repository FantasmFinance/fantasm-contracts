// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interfaces/IXToken.sol";
import "./interfaces/IYToken.sol";
import "./interfaces/IYTokenReserve.sol";
import "./interfaces/IMasterOracle.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/ISwapStrategy.sol";
import "./libs/WethUtils.sol";

contract Pool is Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IXToken;
    using SafeERC20 for IYToken;

    struct UserInfo {
        uint256 xTokenBalance;
        uint256 yTokenBalance;
        uint256 ethBalance;
        uint256 lastAction;
    }

    /* ========== ADDRESSES ================ */

    IMasterOracle public oracle;
    IXToken public xToken;
    IYToken public yToken;
    IYTokenReserve public yTokenReserve;
    ISwapStrategy public swapStrategy;
    address public treasury;

    /* ========== STATE VARIABLES ========== */

    mapping(address => UserInfo) public userInfo;

    uint256 public unclaimedEth;
    uint256 public unclaimedXToken;
    uint256 public unclaimedYToken;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;
    uint256 private constant PRECISION = 1e6;

    // AccessControl state variables
    bool public mintPaused = false;
    bool public redeemPaused = false;

    // Collateral ratio
    uint256 public collateralRatio = 1e6;
    uint256 public lastRefreshCrTimestamp;
    uint256 public refreshCooldown = 3600; // = 1 hour
    uint256 public ratioStepUp = 2000; // = 0.002 or 0.2% -> ratioStep when CR increase
    uint256 public ratioStepDown = 1000; // = 0.001 or 0.1% -> ratioStep when CR decrease
    uint256 public priceTarget = 1e18; // = 1; 1 XToken pegged to the value of 1 ETH
    uint256 public priceBand = 5e15; // = 0.005; CR will be adjusted if XToken > 1.005 ETH or XToken < 0.995 ETH
    uint256 public minCollateralRatio = 1e6;
    bool public collateralRatioPaused = false;

    // fees
    uint256 public redemptionFee = 5000; // 6 decimals of precision
    uint256 public constant REDEMPTION_FEE_MAX = 9000; // 0.9%
    uint256 public mintingFee = 3000; // 6 decimals of precision
    uint256 public constant MINTING_FEE_MAX = 5000; // 0.5%

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _xToken,
        address _yToken,
        address _yTokenReserve
    ) {
        require(_xToken != address(0), "Pool::initialize: invalidAddress");
        require(_yToken != address(0), "Pool::initialize: invalidAddress");
        require(_yTokenReserve != address(0), "Pool::initialize: invalidAddress");
        xToken = IXToken(_xToken);
        xToken.setMinter(address(this));
        yToken = IYToken(_yToken);
        yTokenReserve = IYTokenReserve(_yTokenReserve);
        yTokenReserve.setPool(address(this));
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
            uint256 _collateralBalance
        )
    {
        _collateralRatio = collateralRatio;
        _lastRefreshCrTimestamp = lastRefreshCrTimestamp;
        _mintingFee = mintingFee;
        _redemptionFee = redemptionFee;
        _mintingPaused = mintPaused;
        _redemptionPaused = redeemPaused;
        _collateralBalance = usableCollateralBalance();
    }

    function usableCollateralBalance() public view returns (uint256) {
        uint256 _balance = WethUtils.weth.balanceOf(address(this));
        return _balance > unclaimedEth ? (_balance - unclaimedEth) : 0;
    }

    /// @notice Calculate the expected results for zap minting
    /// @param _ethIn Amount of Collateral token input.
    /// @return _xTokenOut : the amount of XToken output.
    /// @return _yTokenOut : the amount of YToken output by swapping
    /// @return _ethFee : the fee amount in Collateral token.
    /// @return _ethSwapIn : the amount of Collateral token to swap
    function calcMint(uint256 _ethIn)
        public
        view
        returns (
            uint256 _xTokenOut,
            uint256 _yTokenOut,
            uint256 _ethFee,
            uint256 _ethSwapIn
        )
    {
        uint256 _yTokenPrice = oracle.getYTokenPrice();
        require(_yTokenPrice > 0, "Pool::calcMint: Invalid YToken price");
        _ethSwapIn = (_ethIn * (COLLATERAL_RATIO_MAX - collateralRatio)) / COLLATERAL_RATIO_MAX;
        _yTokenOut = (_ethSwapIn * PRICE_PRECISION) / _yTokenPrice;
        _ethFee = (_ethIn * mintingFee * collateralRatio) / COLLATERAL_RATIO_MAX / PRECISION;
        _xTokenOut = _ethIn - ((_ethIn * mintingFee) / PRECISION);
    }

    /// @notice Calculate the expected results for redemption
    /// @param _xTokenIn Amount of XToken input.
    /// @return _ethOut : the amount of Eth output
    /// @return _yTokenOut : the amount of YToken output
    /// @return _ethFee : the fee amount in Eth
    /// @return _requiredEthBalance : required Eth balance in the pool
    function calcRedeem(uint256 _xTokenIn)
        public
        view
        returns (
            uint256 _ethOut,
            uint256 _yTokenOut,
            uint256 _ethFee,
            uint256 _requiredEthBalance
        )
    {
        uint256 _yTokenPrice = oracle.getYTokenPrice();
        require(_yTokenPrice > 0, "Pool::calcRedeem: Invalid YToken price");

        _requiredEthBalance = (_xTokenIn * collateralRatio) / PRECISION;
        if (collateralRatio < COLLATERAL_RATIO_MAX) {
            _yTokenOut = (_xTokenIn * (COLLATERAL_RATIO_MAX - collateralRatio) * (PRECISION - redemptionFee) * PRICE_PRECISION) / COLLATERAL_RATIO_MAX / PRECISION / _yTokenPrice;
        }

        if (collateralRatio > 0) {
            _ethOut = (_xTokenIn * collateralRatio * (PRECISION - redemptionFee)) / COLLATERAL_RATIO_MAX / PRECISION;
            _ethFee = (_xTokenIn * collateralRatio * redemptionFee) / COLLATERAL_RATIO_MAX / PRECISION;
        }
    }

    /// @notice Calculate the excess collateral balance
    function calcExcessCollateralBalance() public view returns (uint256 _delta, bool _exceeded) {
        uint256 _requiredCollateralBal = (xToken.totalSupply() * collateralRatio) / COLLATERAL_RATIO_MAX;
        uint256 _usableCollateralBal = usableCollateralBalance();
        if (_usableCollateralBal >= _requiredCollateralBal) {
            _delta = _usableCollateralBal - _requiredCollateralBal;
            _exceeded = true;
        } else {
            _delta = _requiredCollateralBal - _usableCollateralBal;
            _exceeded = false;
        }
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update collateral ratio and adjust based on the TWAP price of XToken
    function refreshCollateralRatio() public {
        require(collateralRatioPaused == false, "Pool::refreshCollateralRatio: Collateral Ratio has been paused");
        require(block.timestamp - lastRefreshCrTimestamp >= refreshCooldown, "Pool::refreshCollateralRatio: Must wait for the refresh cooldown since last refresh");

        uint256 _xTokenPrice = oracle.getXTokenTWAP();
        if (_xTokenPrice > priceTarget + priceBand) {
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
        } else if (_xTokenPrice < priceTarget - priceBand) {
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

    function mint(uint256 _minXTokenOut) external payable nonReentrant {
        require(!mintPaused, "Pool::mint: Minting is paused");
        uint256 _ethIn = msg.value;
        address _sender = msg.sender;

        (uint256 _xTokenOut, uint256 _yTokenOut, uint256 _fee, uint256 _wethSwapIn) = calcMint(_ethIn);
        require(_xTokenOut >= _minXTokenOut, "Pool::mint: > slippage");

        WethUtils.wrap(_ethIn);
        if (_yTokenOut > 0 && _wethSwapIn > 0) {
            WethUtils.weth.safeIncreaseAllowance(address(swapStrategy), _wethSwapIn);
            swapStrategy.execute(_wethSwapIn, _yTokenOut);
        }

        if (_xTokenOut > 0) {
            userInfo[_sender].xTokenBalance = userInfo[_sender].xTokenBalance + _xTokenOut;
            unclaimedXToken = unclaimedXToken + _xTokenOut;
        }

        transferToTreasury(_fee);

        emit Mint(_sender, _xTokenOut, _ethIn, _fee);
    }

    function redeem(
        uint256 _xTokenIn,
        uint256 _minYTokenOut,
        uint256 _minEthOut
    ) external nonReentrant {
        require(!redeemPaused, "Pool::redeem: Redeeming is paused");

        address _sender = msg.sender;
        (uint256 _ethOut, uint256 _yTokenOut, uint256 _fee, uint256 _requiredEthBalance) = calcRedeem(_xTokenIn);

        // Check if collateral balance meets and meet output expectation
        require(_requiredEthBalance <= usableCollateralBalance(), "Pool::redeem: > ETH balance");
        require(_minEthOut <= _ethOut && _minYTokenOut <= _yTokenOut, "Pool::redeem: >slippage");

        if (_ethOut > 0) {
            userInfo[_sender].ethBalance = userInfo[_sender].ethBalance + _ethOut;
            unclaimedEth = unclaimedEth + _ethOut;
        }

        if (_yTokenOut > 0) {
            userInfo[_sender].yTokenBalance = userInfo[_sender].yTokenBalance + _yTokenOut;
            unclaimedYToken = unclaimedYToken + _yTokenOut;
        }

        userInfo[_sender].lastAction = block.number;

        // Move all external functions to the end
        xToken.burn(_sender, _xTokenIn);
        transferToTreasury(_fee);

        emit Redeem(_sender, _xTokenIn, _ethOut, _yTokenOut, _fee);
    }

    /**
     * @notice collect all minting and redemption
     */
    function collect() external nonReentrant {
        address _sender = msg.sender;
        require(userInfo[_sender].lastAction < block.number, "Pool::collect: <minimum_delay");

        bool _sendXToken = false;
        bool _sendYToken = false;
        bool _sendEth = false;
        uint256 _xTokenAmount;
        uint256 _yTokenAmount;
        uint256 _ethAmount;

        // Use Checks-Effects-Interactions pattern
        if (userInfo[_sender].xTokenBalance > 0) {
            _xTokenAmount = userInfo[_sender].xTokenBalance;
            userInfo[_sender].xTokenBalance = 0;
            unclaimedXToken = unclaimedXToken - _xTokenAmount;
            _sendXToken = true;
        }

        if (userInfo[_sender].yTokenBalance > 0) {
            _yTokenAmount = userInfo[_sender].yTokenBalance;
            userInfo[_sender].yTokenBalance = 0;
            unclaimedYToken = unclaimedYToken - _yTokenAmount;
            _sendYToken = true;
        }

        if (userInfo[_sender].ethBalance > 0) {
            _ethAmount = userInfo[_sender].ethBalance;
            userInfo[_sender].ethBalance = 0;
            unclaimedEth = unclaimedEth - _ethAmount;
            _sendEth = true;
        }

        if (_sendXToken) {
            xToken.mint(_sender, _xTokenAmount);
        }

        if (_sendYToken) {
            yTokenReserve.transfer(_sender, _yTokenAmount);
        }

        if (_sendEth) {
            WethUtils.unwrap(_ethAmount);
            payable(_sender).transfer(_ethAmount);
        }
    }

    /// @notice Function to recollateralize the pool by receiving ETH
    function recollateralize() external payable {
        uint256 _amount = msg.value;
        require(_amount > 0, "Pool::recollateralize: Invalid amount");
        WethUtils.wrap(_amount);
        emit Recollateralized(msg.sender, _amount);
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

    /// @notice Transfer the excess balance of WETH to FeeReserve
    /// @param _amount amount of WETH to reduce
    function reduceExcessCollateral(uint256 _amount) external onlyOwner {
        (uint256 _excessWethBal, bool exceeded) = calcExcessCollateralBalance();
        if (exceeded && _excessWethBal > 0) {
            require(_amount <= _excessWethBal, "Pool::reduceExcessCollateral: The amount is too large");
            transferToTreasury(_amount);
        }
    }

    /// @notice Set the address of Swapper utils
    /// @param _swapStrategy address of Swapper utils contract
    function setSwapStrategy(ISwapStrategy _swapStrategy) external onlyOwner {
        require(address(_swapStrategy) != address(0), "Pool::setSwapStrategy: invalid address");
        swapStrategy = _swapStrategy;
        emit SwapStrategyChanged(address(_swapStrategy));
    }

    /// @notice Set new oracle address
    /// @param _oracle address of the oracle
    function setOracle(IMasterOracle _oracle) external onlyOwner {
        require(address(_oracle) != address(0), "Pool::setOracle: invalid address");
        oracle = _oracle;
        emit OracleChanged(address(_oracle));
    }

    /// @notice Set the address of Treasury
    /// @param _treasury address of Treasury contract
    function setTreasury(address _treasury) external {
        require(treasury == address(0), "Pool::setTreasury: not allowed");
        treasury = _treasury;
    }

    /// @notice Move weth to treasury
    function transferToTreasury(uint256 _amount) internal {
        require(treasury != address(0), "Pool::transferToTreasury:Invalid address");
        if (_amount > 0) {
            WethUtils.weth.safeTransfer(treasury, _amount);
        }
    }

    // EVENTS
    event OracleChanged(address indexed _oracle);
    event Toggled(bool _mintPaused, bool _redeemPaused);
    event Mint(address minter, uint256 amount, uint256 ethIn, uint256 fee);
    event Redeem(address redeemer, uint256 amount, uint256 ethOut, uint256 yTokenOut, uint256 fee);
    event UpdateCollateralRatioPaused(bool _collateralRatioPaused);
    event NewCollateralRatioOptions(uint256 _ratioStepUp, uint256 _ratioStepDown, uint256 _priceBand, uint256 _refreshCooldown);
    event MinCollateralRatioUpdated(uint256 _minCollateralRatio);
    event NewCollateralRatioSet(uint256 _cr);
    event FeesUpdated(uint256 _mintingFee, uint256 _redemptionFee);
    event Recollateralized(address indexed _sender, uint256 _amount);
    event SwapStrategyChanged(address indexed _swapper);
}
