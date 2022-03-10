// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IFantasticTreasury {
    function balanceOf(address _token) external view returns (uint256);

    function requestFund(address _token, uint256 _amount) external;
}
