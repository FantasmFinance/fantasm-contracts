// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IPool {
    function setTreasury(address _addr) external;

    function recollateralize() external payable;
}
