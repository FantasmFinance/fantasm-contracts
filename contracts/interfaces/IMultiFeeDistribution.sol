// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMultiFeeDistribution {
    function addReward(address rewardsToken, address distributor) external;

    function mint(address user, uint256 amount) external;

    function notifyRewardAmount(address rewardsToken, uint256 reward) external;
}
