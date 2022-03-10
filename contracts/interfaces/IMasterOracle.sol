// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IMasterOracle {
    function getXTokenPrice() external view returns (uint256);

    function getYTokenPrice() external view returns (uint256);

    function getYTokenTWAP() external view returns (uint256);

    function getXTokenTWAP() external view returns (uint256);
}
