// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./Fund.sol";

contract FsmDaoFund is Fund {
    uint256 public constant ALLOCATION = 6_000_000 ether; // 20%
    uint256 public constant VESTING_DURATION = 3 * 365 * 24 * 3600; // 3 years
    uint256 public constant VESTING_START = 1647871200; // 21th Mar 2022, 2PM UTC

     /*===================== CONSTRUCTOR =====================*/
    constructor(address _fsm) Fund(_fsm) {}

    /*===================== VIEWS =====================*/

    function allocation() public pure override returns (uint256) {
        return ALLOCATION;
    }

    function vestingStart() public pure override returns (uint256) {
        return VESTING_START;
    }

    function vestingDuration() public pure override returns (uint256) {
        return VESTING_DURATION;
    }
}
