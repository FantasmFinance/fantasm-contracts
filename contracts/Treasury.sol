// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMasterOracle.sol";
import "./interfaces/IXftm.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IMultiFeeDistribution.sol";
import "./libs/WethUtils.sol";

contract Treasury is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IWETH;

    /// @notice precision of CR, various fees
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;
    uint256 private constant RATIO_PRECISION = 1e6;
    uint256 private constant PRICE_PRECISION = 1e18;

    IMasterOracle public oracle;
    IXftm public xftm;

    uint256 public maxXftmSupply = 50_000_000 ether; // limit the maximum Xftm Supply
    // collateral ratios
    uint256 public collateralRatio = 1e6;
    uint256 public lastRefreshCrTimestamp;
    uint256 public refreshCooldown = 3600; // = 1 hour
    uint256 public ratioStep = 1000; // = 0.001 or 0.1%
    uint256 public priceTarget = 1e18; // = 1; 1 XFTM pegged to the value of 1 FTM
    uint256 public priceBand = 5e15; // = 0.005; CR will be adjusted if XFTM > 1.005 FTM or XFTM < 0.995 FTM

    /**
     * @notice CR not allowed to go below this value to be safe. Set to 100% at genesis then tune down upon running by timelock
     */
    uint256 public minCollateralRatio = 1e6;
    bool public collateralRatioPaused = false;

    // fees
    uint256 public redemptionFee = 5000; // 6 decimals of precision
    uint256 public constant REDEMPTION_FEE_MAX = 9000; // 0.9%
    uint256 public mintingFee = 3000; // 6 decimals of precision
    uint256 public constant MINTING_FEE_MAX = 5000; // 0.5%

    IMultiFeeDistribution public feeDistributor;

    constructor(IXftm _xftm) {
        xftm = _xftm;
    }

    // ========== PUBLIC VIEW FUNCTIONS ============

    /// @notice Return protocol quick info
    /// @return _collateralRatio : Current Collateral Ratio
    /// @return _mintingFee : Current minting fee
    /// @return _redemptionFee : Current redemption fee
    function info()
        external
        view
        returns (
            uint256 _collateralRatio,
            uint256 _mintingFee,
            uint256 _redemptionFee
        )
    {
        _collateralRatio = collateralRatio;
        _mintingFee = mintingFee;
        _redemptionFee = redemptionFee;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update collateral ratio and adjust based on the TWAP price of XFTM
    function refreshCollateralRatio() public {
        require(collateralRatioPaused == false, "Treasury::refreshCollateralRatio: Collateral Ratio has been paused");
        require(block.timestamp - lastRefreshCrTimestamp >= refreshCooldown, "Treasury::refreshCollateralRatio: Must wait for the refresh cooldown since last refresh");

        uint256 _xftmPrice = oracle.getXftmTWAP();
        if (_xftmPrice > priceTarget.add(priceBand)) {
            if (collateralRatio <= ratioStep) {
                collateralRatio = 0;
            } else {
                uint256 _newCR = collateralRatio.sub(ratioStep);
                if (_newCR <= minCollateralRatio) {
                    collateralRatio = minCollateralRatio;
                } else {
                    collateralRatio = _newCR;
                }
            }
        } else if (_xftmPrice < priceTarget.sub(priceBand)) {
            if (collateralRatio.add(ratioStep) >= COLLATERAL_RATIO_MAX) {
                collateralRatio = COLLATERAL_RATIO_MAX;
            } else {
                collateralRatio = collateralRatio.add(ratioStep);
            }
        }

        lastRefreshCrTimestamp = block.timestamp;
        emit NewCollateralRatioSet(collateralRatio);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Distribute protocol's fee to stakers
    /// @param amount Amount of fee (in FTM) will be distributed
    function allocateFee(uint256 amount) external onlyOwner {
        require(address(feeDistributor) != address(0), "Treasury::allocateFee:Fee distributor not set");
        require(amount > 0, "Treasury::allocateFee: invalid amount");
        WethUtils.weth.safeIncreaseAllowance(address(feeDistributor), amount);
        feeDistributor.notifyRewardAmount(address(WethUtils.weth), amount);
    }

    /// @notice Configure variables related to Collateral Ratio
    /// @param _ratioStep Step which Collateral Ratio will be adjusted each updates
    /// @param _priceBand The collateral ratio will only be adjusted if current price move out of this band
    /// @param _refreshCooldown The minimum delay between each Collateral Ratio updates
    function setCollateralRatioOptions(
        uint256 _ratioStep,
        uint256 _priceBand,
        uint256 _refreshCooldown
    ) public onlyOwner {
        ratioStep = _ratioStep;
        priceBand = _priceBand;
        refreshCooldown = _refreshCooldown;
        emit NewCollateralRatioOptions(_ratioStep, _priceBand, _refreshCooldown);
    }

    /// @notice Pause or unpause collateral ratio updates
    /// @param _collateralRatioPaused `true` or `false`
    function toggleCollateralRatio(bool _collateralRatioPaused) public onlyOwner {
        if (collateralRatioPaused != _collateralRatioPaused) {
            collateralRatioPaused = _collateralRatioPaused;
            emit UpdateCollateralRatioPaused(_collateralRatioPaused);
        }
    }

    /// @notice Set the address of Fantasm Oracle
    /// @param _oracle address of Fantasm Oracle
    function setOracle(IMasterOracle _oracle) public onlyOwner {
        require(address(_oracle) != address(0), "Treasury::setOracle: invalidAddress");
        oracle = _oracle;
        emit OracleChanged(address(_oracle));
    }

    /// @notice Set the minimum Collateral Ratio
    /// @param _minCollateralRatio value of minimum Collateral Ratio in 1e6 precision
    function setMinCollateralRatio(uint256 _minCollateralRatio) external onlyOwner {
        require(_minCollateralRatio <= COLLATERAL_RATIO_MAX, "Treasury::setMinCollateralRatio: >COLLATERAL_RATIO_MAX");
        minCollateralRatio = _minCollateralRatio;
        emit MinCollateralRatioUpdated(_minCollateralRatio);
    }

    /// @notice Set the maxium XFTM supply
    /// @param _newValue value of maxium XFTM supply
    function setMaxXftmSupply(uint256 _newValue) external onlyOwner {
        require(_newValue > xftm.totalSupply(), "Treasury::setMaxXftmSupply: Cannot smaller than current limit");
        maxXftmSupply = _newValue;
        emit MaxXftmSupplyUpdated(_newValue);
    }

    /// @notice Set the protocol fees
    /// @param _mintingFee Minting fee in percentage
    /// @param _redemptionFee Redemption fee in percentage
    function setFees(uint256 _mintingFee, uint256 _redemptionFee) public onlyOwner {
        require(_mintingFee <= MINTING_FEE_MAX, "Treasury::setFees:>MINTING_FEE_MAX");
        require(_redemptionFee <= REDEMPTION_FEE_MAX, "Treasury::setFees:>REDEMPTION_FEE_MAX");
        redemptionFee = _redemptionFee;
        mintingFee = _mintingFee;
        emit FeesUpdated(_mintingFee, _redemptionFee);
    }

    /// @notice Set fee distributor contract (Only can be set once)
    /// @param _feeDistributor address of MultiFeeDistributor contract
    function setFeeDistributor(address _feeDistributor) external {
        require(address(feeDistributor) == address(0), "Treasury::allocateFee: Cannot redefine address");
        feeDistributor = IMultiFeeDistribution(_feeDistributor);
    }

    // EVENTS
    event OracleChanged(address indexed _oracle);
    event UpdateCollateralRatioPaused(bool _collateralRatioPaused);
    event NewCollateralRatioOptions(uint256 _ratioStep, uint256 _priceBand, uint256 _refreshCooldown);
    event MinCollateralRatioUpdated(uint256 _minCollateralRatio);
    event NewCollateralRatioSet(uint256 _cr);
    event FeesUpdated(uint256 _mintingFee, uint256 _redemptionFee);
    event MaxXftmSupplyUpdated(uint256 _value);
}
