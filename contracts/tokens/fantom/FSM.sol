// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../YToken.sol";

contract FSM is YToken {
    uint256 public constant MAX_TOTAL_SUPPLY = 30_000_000 ether;

    constructor(
        string memory _name,
        string memory _symbol,
        address _reserve
    ) YToken(_name, _symbol) {
        _mint(_reserve, maxTotalSupply());
    }

    // ===== OVERRIDEN =============

    function maxTotalSupply() internal pure override returns (uint256) {
        return MAX_TOTAL_SUPPLY;
    }
}
