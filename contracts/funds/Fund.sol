// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Fund is Ownable, Initializable {
    using SafeERC20 for IERC20;
    IERC20 public fsm;
    uint256 public claimedAmount;

    /*===================== CONSTRUCTOR =====================*/

    function initialize(address _fsm) external initializer {
        require(_fsm != address(0), "Fund::constructor: Invalid address");
        fsm = IERC20(_fsm);
    }

    /*===================== VIEWS =====================*/

    function allocation() public view virtual returns (uint256);

    function vestingStart() public view virtual returns (uint256);

    function vestingDuration() public view virtual returns (uint256);

    function currentBalance() public view returns (uint256) {
        return fsm.balanceOf(address(this));
    }

    function vestedBalance() public view returns (uint256) {
        uint256 _allocation = allocation();
        uint256 _start = vestingStart();
        uint256 _duration = vestingDuration();
        if (block.timestamp <= _start) {
            return 0;
        }
        if (block.timestamp > _start + _duration) {
            return _allocation;
        }
        return (_allocation * (block.timestamp - _start)) / _duration;
    }

    function claimable() public view returns (uint256) {
        return vestedBalance() - claimedAmount;
    }

    /*===================== MUTATIVE =====================*/
    function transfer(address receiver, uint256 amount) external onlyOwner {
        require(receiver != address(0), "Fund::transfer: Invalid address");
        require(amount > 0, "Fund::transfer: Invalid amount");
        require(amount <= claimable(), "Fund::transfer: > vestedAmount");

        claimedAmount = claimedAmount + amount;
        fsm.safeTransfer(receiver, amount);
    }
}
