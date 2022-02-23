// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interfaces/IFantasm.sol";
import "./interfaces/IWETH.sol";
import "./libs/WethUtils.sol";

contract PoolUtils is Ownable {
    using SafeERC20 for IWETH;
    IUniswapV2Router02 public swapRouter;
    address[] public swapPaths;
    uint256 public swapSlippage;
    uint256 private constant SWAP_TIMEOUT = 10 minutes;
    uint256 private constant SLIPPAGE_PRECISION = 1e6;

    IFantasm public fantasm;

    constructor(IFantasm _fantasm) {
        fantasm = _fantasm;
    }

    /// @notice Function to take input FTM to swap to FSM and burn
    /// @param _ftmIn Amount of FTM input
    /// @param _fantasmOut Amount of FSM output expected
    function swap(uint256 _ftmIn, uint256 _fantasmOut) external {
        uint256 _minFantasmOut = (_fantasmOut * (SLIPPAGE_PRECISION - swapSlippage)) / SLIPPAGE_PRECISION;
        WethUtils.weth.safeTransferFrom(msg.sender, address(this), _ftmIn);
        WethUtils.weth.safeIncreaseAllowance(address(swapRouter), _ftmIn);
        swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(_ftmIn, _minFantasmOut, swapPaths, address(this), block.timestamp + SWAP_TIMEOUT);
        _burnAllFantasm();
    }

    /// @notice Config poolHelper parameters
    /// @param _swapRouter Address of DEX router
    /// @param _swapSlippage slippage
    /// @param _swapPaths paths to swap
    function config(
        IUniswapV2Router02 _swapRouter,
        uint256 _swapSlippage,
        address[] memory _swapPaths
    ) external onlyOwner {
        swapRouter = _swapRouter;
        swapSlippage = _swapSlippage;
        swapPaths = _swapPaths;
        emit ConfigUpdated(address(_swapRouter), _swapSlippage, _swapPaths);
    }

    function _burnAllFantasm() internal {
        uint256 _balance = fantasm.balanceOf(address(this));
        if (_balance > 0) {
            fantasm.burn(_balance);
        }
    }

    event ConfigUpdated(address indexed _router, uint256 _slippage, address[] _paths);
}
