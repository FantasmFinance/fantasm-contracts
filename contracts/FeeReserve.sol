// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IMultiFeeDistribution.sol";
import "./libs/WethUtils.sol";

contract FeeReserve is Ownable {
    using SafeERC20 for IWETH;

    IMultiFeeDistribution public feeDistributor;
    IPool public pool;

    constructor(IMultiFeeDistribution _feeDistribution, IPool _pool) {
        require(address(_feeDistribution) != address(0), "FeeReserve::constructor: Invalid address");
        require(address(_pool) != address(0), "FeeReserve::constructor: Invalid address");
        pool = _pool;
        feeDistributor = _feeDistribution;
        pool.setFeeReserve(address(this));
    }

    // ========== PUBLIC VIEW FUNCTIONS ============

    /// @notice Return WFTM balance of FeeReserve
    /// @return WFTM Balance of the FeeReserve
    function ftmBalance() external view returns (uint256) {
        return WethUtils.weth.balanceOf(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Distribute protocol's fee to stakers
    /// @param amount Amount of fee (in FTM) will be distributed
    function allocateFtm(uint256 amount) external onlyOwner {
        require(address(feeDistributor) != address(0), "FeeReserve::allocateFee:Fee distributor not set");
        require(amount > 0, "FeeReserve::allocateFee: invalid amount");
        WethUtils.weth.safeIncreaseAllowance(address(feeDistributor), amount);
        feeDistributor.notifyRewardAmount(address(WethUtils.weth), amount);
    }

    /// @notice Recollateralize the minting pool
    /// @param amount Amount of FTM will be used to recollateralize
    function recollateralize(uint256 amount) external onlyOwner {
        require(address(pool) != address(0), "FeeReserve::recollateralize:pool not set");
        require(amount > 0, "FeeReserve::recollateralize: invalid amount");
        WethUtils.weth.safeIncreaseAllowance(address(pool), amount);
        pool.recollateralize(amount);
    }
}
