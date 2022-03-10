// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFantasticTreasury.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IWETH.sol";
import "../libs/WethUtils.sol";

contract StratRecollateralize is Ownable {
    using SafeERC20 for IWETH;

    IPool public immutable pool;
    IFantasticTreasury public immutable treasury;

    constructor(IFantasticTreasury _treasury, IPool _pool) {
        treasury = _treasury;
        pool = _pool;
    }

    /// @notice Recollateralize the minting pool
    /// @param _amount Amount of ETH will be used to recollateralize
    function recollateralize(uint256 _amount) external onlyOwner {
        require(address(pool) != address(0), "StratRecollateralize::recollateralize:pool not set");
        require(_amount > 0, "StratRecollateralize::recollateralize:invalid amount");
        treasury.requestFund(address(WethUtils.weth), _amount);
        WethUtils.weth.safeTransferFrom(address(treasury), address(this), _amount);
        WethUtils.unwrap(_amount);
        pool.recollateralize{value: _amount}();
        emit Recollateralized(_amount);
    }

    /// @notice fallback for payable -> required to unwrap WETH
    receive() external payable {}

    // EVENTS
    event Recollateralized(uint256 amount);
}
