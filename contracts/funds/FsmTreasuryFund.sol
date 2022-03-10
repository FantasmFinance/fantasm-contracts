// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./FsmReserve.sol";

contract FsmTreasuryFund is Ownable {
    uint256 public constant ALLOCATION = 3_000_000 ether; // 10%
    uint256 public constant VESTING_DURATION = 3 * 365 * 24 * 3600; // 3 years
    uint256 public constant VESTING_START = 1647007200; // 11th Mar 2022, 2PM UTC

    uint256 public claimed_amount;
    FsmReserve public reserve;

    // ======== CONSTRUCTOR ==================

    constructor(FsmReserve _reserve) {
        require(address(_reserve) != address(0), "FsmTreasuryFund::constructor: Invalid address");
        reserve = _reserve;
        reserve.setTreasuryFund(address(this));
    }

    // ========= VIEWS ==================

    function vestedBalance() public view returns (uint256) {
        if (block.timestamp <= VESTING_START) {
            return 0;
        }
        if (block.timestamp > VESTING_START + VESTING_DURATION) {
            return ALLOCATION;
        }
        return (ALLOCATION * (block.timestamp - VESTING_START)) / VESTING_DURATION;
    }

    function claimable() public view returns (uint256) {
        return vestedBalance() - claimed_amount;
    }

    // ========= RESTRICTED FUNC ==================

    function transfer(address _receiver, uint256 _amount) external onlyOwner {
        require(_receiver != address(0), "FsmTreasuryFund::transfer: Invalid address");
        require(_amount > 0, "FsmTreasuryFund::transfer: invalid amount");
        require(_amount <= claimable(), "FsmTreasuryFund::transfer: > vestedAmount");

        claimed_amount = claimed_amount + _amount;
        reserve.transfer(_receiver, _amount);
    }
}
