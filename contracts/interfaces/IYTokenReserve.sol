// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IYTokenReserve {
    function transfer(address _address, uint256 _amount) external;

    function setRewarder(address _rewarder) external returns (bool);

    function setPool(address _pool) external returns (bool);
}
