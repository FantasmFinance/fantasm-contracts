// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../XToken.sol";

contract XFTM is XToken {
    uint256 public constant GENESIS_SUPPLY = 100 ether; // 100 will be minted at genesis for liq pool seeding

    constructor(string memory _name, string memory _symbol) XToken(_name, _symbol) {
        _mint(msg.sender, GENESIS_SUPPLY);
    }
}
