// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IPool {
    function setFeeReserve(address _addr) external;

    function recollateralize(uint256 _amount) external;
}
