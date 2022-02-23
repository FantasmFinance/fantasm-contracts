// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IPairOracle {
    function twap(address token, uint256 pricePrecision) external view returns (uint256 amountOut);

    function spot(address token, uint256 pricePrecision) external view returns (uint256 amountOut);

    function update() external;
}
