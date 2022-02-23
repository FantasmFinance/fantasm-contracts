// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFantasm.sol";

contract TreasuryFund is Ownable {
    using SafeERC20 for IFantasm;

    uint256 public immutable ALLOCATION;
    uint256 public immutable VESTING_DURATION;
    uint256 public immutable VESTING_START;

    uint256 public claimed_amount;
    IFantasm public fantasm;

    // ======== CONSTRUCTOR ==================

    constructor(IFantasm _fantasm) {
        require(address(_fantasm) != address(0), "DevFund::constructor: Invalid address");
        fantasm = _fantasm;
        (ALLOCATION, VESTING_DURATION, VESTING_START) = fantasm.setTreasuryFund(address(this));
    }

    // ========= VIEWS ==================

    function currentBalance() public view returns (uint256) {
        return fantasm.balanceOf(address(this));
    }

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
        require(_receiver != address(0), "DevFund::transfer: Invalid address");
        require(_amount > 0, "DevFund::transfer: invalid amount");
        require(_amount <= claimable(), "DevFund::transfer: > vestedAmount");

        claimed_amount = claimed_amount + _amount;
        fantasm.mint(_receiver, _amount);
    }
}
