// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface ITreasury {
    function maxXftmSupply() external view returns (uint256);

    function info()
        external
        view
        returns (
            uint256 _collateralRatio,
            uint256 _mintingFee,
            uint256 _redemptionFee
        );
}
