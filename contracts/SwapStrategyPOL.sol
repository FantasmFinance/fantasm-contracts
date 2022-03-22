// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./interfaces/ISwapStrategy.sol";
import "./libs/WethUtils.sol";

/*
    Swapper: Protocol Owned Liquidity
    - Swap WETH -> YToken
    - Add liquidity for YToken/WETH pair
    - Transfer LP to Treasury
*/
contract SwapStrategyPOL is ISwapStrategy, Ownable {
    using SafeERC20 for IWETH;
    using SafeERC20 for IERC20;

    IERC20 public immutable yToken;
    IERC20 public immutable lp;
    IUniswapV2Router02 public immutable swapRouter;
    address[] public swapPaths;
    address public immutable treasury;
    uint256 public swapSlippage = 200000; // 20%
    uint256 private constant SLIPPAGE_PRECISION = 1e6;

    constructor(
        address _yToken,
        address _lp,
        address _treasury,
        address _swapRouter,
        address[] memory _swapPaths
    ) {
        yToken = IERC20(_yToken);
        lp = IERC20(_lp);
        treasury = _treasury;
        swapRouter = IUniswapV2Router02(_swapRouter);
        swapPaths = _swapPaths;
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
        uint256 _wethToAdd = _wethIn - _wethToSwap;
        uint256 _minYTokenOut = (_yTokenOut * (SLIPPAGE_PRECISION - swapSlippage)) /
            2 /
            SLIPPAGE_PRECISION;
        uint256 _yTokenReceived = swap(_wethToSwap, _minYTokenOut);

        // 2. add liquidity for YToken/WETH LP
        addLiquidity(_yTokenReceived, _wethToAdd, swapSlippage);
    }

    /* ========== INTERNAL FUNCTIONS ============ */

    /// @notice Add liquidity for YToken/WETH with the current balance
    function swap(uint256 _wethToSwap, uint256 _minYTokenOut) internal returns (uint256) {
        WethUtils.weth.safeIncreaseAllowance(address(swapRouter), _wethToSwap);
        uint256[] memory _amounts = swapRouter.swapExactTokensForTokens(
            _wethToSwap,
            _minYTokenOut,
            swapPaths,
            address(this),
            block.timestamp
        );
        return _amounts[1];
    }

    /// @notice Add liquidity for YToken/WETH with the current balance and Move LP to Treasury
    function addLiquidity(
        uint256 yTokenAmt,
        uint256 wethAmt,
        uint256 slippage
    ) internal {
        require(treasury != address(0), "SwapStrategyPOL::addLiquidity:Invalid treasury address");
        if (yTokenAmt > 0 && wethAmt > 0) {
            uint256 _minYTokenOut = (yTokenAmt * (SLIPPAGE_PRECISION - slippage)) /
                SLIPPAGE_PRECISION;
            uint256 _minWethOut = (wethAmt * (SLIPPAGE_PRECISION - slippage)) / SLIPPAGE_PRECISION;
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

    function cleanDust() external onlyOwner {
        yToken.safeTransfer(treasury, yToken.balanceOf(address(this)));
        WethUtils.weth.safeTransfer(treasury, WethUtils.weth.balanceOf(address(this)));
    }

    function changeSlippage(uint256 _newSlippage) external onlyOwner {
        require(
            _newSlippage <= SLIPPAGE_PRECISION,
            "SwapStrategyPOL::changeSlippage: Invalid slippage"
        );
        swapSlippage = _newSlippage;
        emit SlippageChanged(_newSlippage);
    }

    /* ========== EVENTS ============ */

    event LiquidityAdded(uint256 _lpBalance, uint256 _wethAmt, uint256 _yTokenAmt);
    event SlippageChanged(uint256 _newSlippage);
}
