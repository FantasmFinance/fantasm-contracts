// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IFantasticStaking {
    function addReward(address rewardsToken, address distributor) external;

    function mint(address user, uint256 amount) external;

    function notifyRewardAmount(address rewardsToken, uint256 reward) external;
}
