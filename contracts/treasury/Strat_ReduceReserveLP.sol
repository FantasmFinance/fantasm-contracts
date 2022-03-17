// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IFantasticTreasury.sol";
import "../libs/WethUtils.sol";

contract StratReduceReserveLP is Ownable {
    using SafeERC20 for IWETH;
    using SafeERC20 for IERC20;

    IFantasticTreasury public treasury;
    IERC20 public yToken;
    address public yTokenFund;
    IERC20 public lp;
    IUniswapV2Router02 public swapRouter;
    address[] public swapPaths;

    uint256 private constant SWAP_TIMEOUT = 10 minutes;
    uint256 private constant SLIPPAGE_PRECISION = 1e6;

    constructor(
        IERC20 _yToken,
        address _yTokenFund,
        IERC20 _lp,
        IUniswapV2Router02 _swapRouter,
        address[] memory _swapPaths,
        IFantasticTreasury _treasury
    ) {
        yToken = _yToken;
        lp = _lp;
        yTokenFund = _yTokenFund;
        swapRouter = _swapRouter;
        swapPaths = _swapPaths;
        treasury = _treasury;
    }

    /* ========== RESTRICTIVE FUNCTIONS ============ */

    /// @notice Remove liqudity, buyback YToken and burn
    /// @param _amount Amount of Liquidity LP token
    function reduceReserve(uint256 _amount, uint256 _minYTokenAmount) external onlyOwner {
        require(_amount > 0, "StratReduceReserveLP::reduceReserve:invalid amount");
        require(yTokenFund != address(0), "StratReduceReserveLP::reduceReserve:invalid address");

        treasury.requestFund(address(lp), _amount);
        lp.safeTransferFrom(address(treasury), address(this), _amount);

        // 1. remove liquidity
        lp.safeIncreaseAllowance(address(swapRouter), _amount);
        swapRouter.removeLiquidity(address(yToken), address(WethUtils.weth), _amount, 0, 0, address(this), block.timestamp + SWAP_TIMEOUT);

        // 2. swap Weth -> YToken
        swap(WethUtils.weth.balanceOf(address(this)), _minYTokenAmount);

        // 3. Burn YToken in the contract
        uint256 _yTokenAmt = yToken.balanceOf(address(this));
        yToken.safeTransfer(yTokenFund, _yTokenAmt);

        emit ReserveReduced(_amount, _yTokenAmt);
    }

    /* ========== INTERNAL FUNCTIONS ============ */

    /// @notice Add liquidity for YToken/WETH with the current balance
    function swap(uint256 _wethToSwap, uint256 _minYTokenOut) internal {
        WethUtils.weth.safeIncreaseAllowance(address(swapRouter), _wethToSwap);
        swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(_wethToSwap, _minYTokenOut, swapPaths, address(this), block.timestamp + SWAP_TIMEOUT);
    }

    /* ========== EVENTS ============ */

    event ReserveReduced(uint256 _lpAmount, uint256 _yTokenBurnAmt);
}
