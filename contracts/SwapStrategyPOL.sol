// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interfaces/ISwapStrategy.sol";
import "./interfaces/IMasterOracle.sol";
import "./libs/WethUtils.sol";

/*
    Swapper: Protocol Owned Liquidity
    - Swap WETH -> YToken
    - Add liquidity for YToken/WETH pair
    - Transfer LP to Treasury
*/
contract SwapStrategyPOL is ISwapStrategy {
    using SafeERC20 for IWETH;
    using SafeERC20 for IERC20;

    IERC20 public immutable yToken;
    IERC20 public immutable lp;
    IUniswapV2Router02 public immutable swapRouter;
    address[] public swapPaths;
    address public immutable treasury;
    uint256 public immutable swapSlippage;
    uint256 private constant SLIPPAGE_PRECISION = 1e6;

    IMasterOracle public oracle;

    constructor(
        address _yToken,
        address _lp,
        address _treasury,
        address _swapRouter,
        uint256 _swapSlippage,
        address[] memory _swapPaths,
        address _oracle
    ) {
        yToken = IERC20(_yToken);
        lp = IERC20(_lp);
        treasury = _treasury;
        swapRouter = IUniswapV2Router02(_swapRouter);
        swapSlippage = _swapSlippage;
        swapPaths = _swapPaths;
        oracle = IMasterOracle(_oracle);
    }

    /* ========== VIEW FUNCTIONS ============ */

    function lpBalance() public view returns (uint256) {
        return lp.balanceOf(address(this));
    }

    /* ========== PUBLIC FUNCTIONS ============ */

    /// @notice Function to take input WETH to swap to YToken then add liquidity
    /// @param _wethIn Amount of WETH input
    /// @param _yTokenOut Amount of YToken output expected
    function execute(uint256 _wethIn, uint256 _yTokenOut) external override {
        WethUtils.weth.safeTransferFrom(msg.sender, address(this), _wethIn);

        // 1. swap 50% of WETH to YToken
        uint256 _wethToSwap = _wethIn / 2;
        uint256 _minYTokenOut = (_yTokenOut * (SLIPPAGE_PRECISION - swapSlippage)) / 2 / SLIPPAGE_PRECISION;
        swap(_wethToSwap, _minYTokenOut);

        // 2. add liquidity for YToken/WETH LP
        addLiquidity();
    }

    /* ========== INTERNAL FUNCTIONS ============ */

    /// @notice Add liquidity for YToken/WETH with the current balance
    function swap(uint256 _wethToSwap, uint256 _minYTokenOut) internal {
        WethUtils.weth.safeIncreaseAllowance(address(swapRouter), _wethToSwap);
        swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(_wethToSwap, _minYTokenOut, swapPaths, address(this), block.timestamp);
    }

    /// @notice Add liquidity for YToken/WETH with the current balance and Move LP to Treasury
    function addLiquidity() internal {
        require(treasury != address(0), "SwapStrategyPOL::addLiquidity:Invalid treasury address");
        uint256 yTokenAmt = yToken.balanceOf(address(this));
        uint256 wethAmt = WethUtils.weth.balanceOf(address(this));
        if (yTokenAmt > 0 && wethAmt > 0) {
            uint256 _minYTokenOut = (yTokenAmt * (SLIPPAGE_PRECISION - swapSlippage)) / SLIPPAGE_PRECISION;
            uint256 _minWethOut = (yTokenAmt * (SLIPPAGE_PRECISION - swapSlippage)) / SLIPPAGE_PRECISION;
            yToken.safeIncreaseAllowance(address(swapRouter), yTokenAmt);
            WethUtils.weth.safeIncreaseAllowance(address(swapRouter), wethAmt);
            (uint256 _amountA, uint256 _amountB, uint256 _liquidity) = swapRouter.addLiquidity(
                address(yToken),
                address(WethUtils.weth),
                yTokenAmt,
                wethAmt,
                _minYTokenOut,
                _minWethOut,
                treasury,
                block.timestamp
            );
            emit LiquidityAdded(_liquidity, _amountA, _amountB);
        }
    }

    /* ========== EVENTS ============ */

    event LiquidityAdded(uint256 _lpBalance, uint256 _wethAmt, uint256 _yTokenAmt);
}
