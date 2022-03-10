// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface ISwapStrategy {
    function execute(uint256 _wethIn, uint256 _yTokenOut) external;
}
