// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IXftm.sol";
import "./interfaces/IFantasm.sol";
import "./interfaces/IMasterOracle.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPoolUtils.sol";
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
    ITreasury public treasury;

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

    // zap
    IPoolUtils public poolUtils;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _xftm,
        address _fantasm,
        address _treasury
    ) {
        require(_xftm != address(0), "Pool::initialize: invalidAddress");
        require(_fantasm != address(0), "Pool::initialize: invalidAddress");
        require(_treasury != address(0), "Pool::initialize: invalidAddress");
        xftm = IXftm(_xftm);
        fantasm = IFantasm(_fantasm);
        treasury = ITreasury(_treasury);
        xftm.setMinter(address(this));
        fantasm.setPool(address(this));
    }

    /* ========== VIEWS ========== */

    function usableFtmBalance() public view returns (uint256) {
        return WethUtils.weth.balanceOf(address(this)) - unclaimedFtm;
    }

    function calcExcessFtmBalance() public view returns (uint256 _delta, bool _exceeded) {
        (uint256 _cr, , ) = treasury.info();
        uint256 _requiredFtmBal = (xftm.totalSupply() * _cr) / COLLATERAL_RATIO_MAX;
        uint256 _usableFtmBal = usableFtmBalance();
        if (_usableFtmBal >= _requiredFtmBal) {
            _delta = _usableFtmBal - _requiredFtmBal;
            _exceeded = true;
        } else {
            _delta = _requiredFtmBal - _usableFtmBal;
            _exceeded = false;
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function mint(uint256 _fantasmIn, uint256 _minXftmOut) external payable nonReentrant {
        require(!mintPaused, "Pool::mint: Minting is paused");
        uint256 _ftmIn = msg.value;
        address _minter = msg.sender;

        (uint256 _xftmOut, uint256 _minFantasmIn, uint256 _ftmFee) = calcMint(_ftmIn, _fantasmIn);
        require(_minXftmOut <= _xftmOut, "Pool::mint: slippage");
        require(_minFantasmIn <= _fantasmIn, "Pool::mint: Not enough Fantasm input");
        require(treasury.maxXftmSupply() >= xftm.totalSupply() + _xftmOut, "Pool::mint: > Xftm supply limit");

        WethUtils.wrap(_ftmIn);
        userInfo[_minter].lastAction = block.number;

        if (_xftmOut > 0) {
            userInfo[_minter].xftmBalance = userInfo[_minter].xftmBalance + _xftmOut;
            unclaimedXftm = unclaimedXftm + _xftmOut;
        }

        if (_minFantasmIn > 0) {
            fantasm.safeTransferFrom(_minter, address(this), _minFantasmIn);
        }

        if (_ftmFee > 0) {
            WethUtils.transfer(address(treasury), _ftmFee);
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
            WethUtils.weth.safeIncreaseAllowance(address(poolUtils), _ftmSwapIn);
            poolUtils.swap(_ftmSwapIn, _fantasmOut);
        }

        if (_xftmOut > 0) {
            userInfo[_sender].xftmBalance = userInfo[_sender].xftmBalance + _xftmOut;
            unclaimedXftm = unclaimedXftm + _xftmOut;
        }

        if (_fee > 0) {
            WethUtils.transfer(address(treasury), _fee);
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
        (uint256 _ftmOut, uint256 _fantasmOut, uint256 _fee) = calcRedeem(_xftmIn);

        // Check if collateral balance meets and meet output expectation
        require(_ftmOut <= usableFtmBalance(), "Pool::redeem: > FTM balance");
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
            WethUtils.transfer(address(treasury), _fee);
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

    /* ========== INTERNAL FUNCTIONS ============ */

    /// @notice Calculate the expected results for minting
    /// @param _ftmIn Amount of FTM input.
    /// @param _fantasmIn Amount of FSM input.
    /// @return _xftmOut : the amount of XFTM output.
    /// @return _minFantasmIn : the required amount of FSM input.
    /// @return _fee : the fee amount in FTM.
    function calcMint(uint256 _ftmIn, uint256 _fantasmIn)
        internal
        view
        returns (
            uint256 _xftmOut,
            uint256 _minFantasmIn,
            uint256 _fee
        )
    {
        (uint256 _cr, uint256 _mintingFee, ) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcMint: Invalid Fantasm price");
        uint256 _totalValue = 0; // total value in FTM

        if (_cr > 0) {
            _totalValue = (_ftmIn * COLLATERAL_RATIO_MAX) / _cr;
            _minFantasmIn = ((_totalValue - _ftmIn) * PRICE_PRECISION) / _fantasmPrice;
        } else {
            _totalValue = (_fantasmIn * _fantasmPrice) / PRICE_PRECISION;
            _minFantasmIn = _fantasmIn;
        }
        _xftmOut = _totalValue - ((_totalValue * _mintingFee) / PRECISION);
        _fee = (_ftmIn * _mintingFee) / PRECISION;
    }

    function calcZapMint(uint256 _ftmIn)
        internal
        view
        returns (
            uint256 _xftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee,
            uint256 _ftmSwapIn
        )
    {
        (uint256 _cr, uint256 _mintingFee, ) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcZapMint: Invalid Fantasm price");
        _ftmSwapIn = (_ftmIn * (COLLATERAL_RATIO_MAX - _cr)) / COLLATERAL_RATIO_MAX;
        _fantasmOut = (_ftmSwapIn * PRICE_PRECISION) / _fantasmPrice;
        _ftmFee = (_ftmIn * _mintingFee * _cr) / COLLATERAL_RATIO_MAX / PRECISION;
        _xftmOut = _ftmIn - ((_ftmIn * _mintingFee) / PRECISION);
    }

    function calcRedeem(uint256 _xftmIn)
        internal
        view
        returns (
            uint256 _ftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee
        )
    {
        (uint256 _cr, , uint256 _redemptionFee) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "Pool::calcRedeem: Invalid Fantasm price");

        if (_cr < COLLATERAL_RATIO_MAX) {
            uint256 _fantasmValueOut = (_xftmIn - ((_xftmIn * _cr) / PRECISION));
            uint256 _fantasmOutPostFee = (_fantasmValueOut * PRICE_PRECISION) / _fantasmPrice; // before fee
            _fantasmOut = _fantasmOutPostFee - ((_fantasmOutPostFee * _redemptionFee) / PRECISION); // after fee
        }

        if (_cr > 0) {
            uint256 _ftmOutPostFee = ((_xftmIn * _cr) / PRECISION);
            _ftmFee = (_ftmOutPostFee * _redemptionFee) / PRECISION; // redemption fee in FTM
            _ftmOut = _ftmOutPostFee - _ftmFee; // after fee
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function toggle(bool _mintPaused, bool _redeemPaused) public onlyOwner {
        mintPaused = _mintPaused;
        redeemPaused = _redeemPaused;
        emit Toggled(_mintPaused, _redeemPaused);
    }

    function reduceExcessFtm(uint256 _amount) external onlyOwner {
        (uint256 _excessFtmBal, bool exceeded) = calcExcessFtmBalance();
        if (exceeded && _excessFtmBal > 0) {
            require(_amount <= _excessFtmBal, "Pool::reduceExcessFtm: The amount is too large");
            require(address(treasury) != address(0), "Pool::reduceExcessFtm: invalid address");
            WethUtils.transfer(address(treasury), _amount);
        }
    }

    function setOracle(IMasterOracle _oracle) external onlyOwner {
        require(address(_oracle) != address(0), "Pool::setOracle: invalid address");
        oracle = _oracle;
        emit OracleChanged(address(_oracle));
    }

    function setPoolHelper(IPoolUtils _poolUtils) external onlyOwner {
        require(address(_poolUtils) != address(0), "Pool:setPoolHelper: invalid address");
        poolUtils = _poolUtils;
        emit PoolUtilsChanged(address(_poolUtils));
    }

    receive() external payable {}

    // EVENTS
    event OracleChanged(address indexed _oracle);
    event Toggled(bool _mintPaused, bool _redeemPaused);
    event Mint(address minter, uint256 amount, uint256 ftmIn, uint256 fantasmIn, uint256 fee);
    event ZapMint(address minter, uint256 amount, uint256 ftmIn, uint256 fee);
    event Redeem(address redeemer, uint256 amount, uint256 ftmOut, uint256 fantasmOut, uint256 fee);
    event PoolUtilsChanged(address indexed _addr);
}
