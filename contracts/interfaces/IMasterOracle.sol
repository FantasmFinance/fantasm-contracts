// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IMasterOracle {
    function getFantasmPrice() external view returns (uint256);

    function getFantasmTWAP() external view returns (uint256);

    function getXftmTWAP() external view returns (uint256);
}
