// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IWETH.sol";

library WethUtils {
    using SafeERC20 for IWETH;

    // unit test only
    // IWETH public constant weth = IWETH(0x77eb900076Cf04865f3491f47e18024C01ac0ae7);
    IWETH public constant weth = IWETH(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    function isWeth(address token) internal pure returns (bool) {
        return address(weth) == token;
    }

    function wrap(uint256 amount) internal {
        weth.deposit{value: amount}();
    }

    function unwrap(uint256 amount) internal {
        weth.withdraw(amount);
    }

    function transfer(address to, uint256 amount) internal {
        weth.safeTransfer(to, amount);
    }
}
