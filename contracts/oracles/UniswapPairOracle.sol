// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../libs/FixedPoint.sol";
import "../libs/UQ112x112.sol";

contract UniswapPairOracle is Ownable {
    using FixedPoint for *;

    uint256 public PERIOD = 3600; // 60-minute TWAP (Time-Weighted Average Price)
    uint256 private constant MAXIMUM_PERIOD = 3600 * 48; // 48 hours
    uint256 private constant LENIENCY = 3600 * 12; // 12 hours

    IUniswapV2Pair public immutable pair;
    address public immutable token0;
    address public immutable token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(address pairAddress) {
        IUniswapV2Pair _pair = IUniswapV2Pair(pairAddress);
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        price0CumulativeLast = _pair.price0CumulativeLast(); // Fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // Fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "PairOracle: NO_RESERVES"); // Ensure that there's liquidity in the pair
    }

    function setPeriod(uint256 _period) external onlyOwner {
        require(_period <= MAXIMUM_PERIOD, "PairOracle::setPeriod: > MAXIMUM_PERIOD");
        PERIOD = _period;
        emit PeriodUpdated(_period);
    }

    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices(address(pair));
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // Overflow is desired

            // Ensure that at least one full period has passed since the last update
            require(timeElapsed >= PERIOD, "PairOracle: PERIOD_NOT_ELAPSED");

            // Overflow is desired, casting never truncates
            // Cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
            price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
            price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));
            price0CumulativeLast = price0Cumulative;
            price1CumulativeLast = price1Cumulative;
            blockTimestampLast = blockTimestamp;
        }
    }

    // Note this will always return 0 before update has been called successfully for the first time.
    function twap(address token, uint256 pricePrecision) external view returns (uint256 amountOut) {
        uint32 timeElapsed = currentBlockTimestamp() - blockTimestampLast;
        require(timeElapsed > PERIOD + LENIENCY, "PairOracle::twap: Oracle was staled");
        if (token == token0) {
            amountOut = price0Average.mul(pricePrecision).decode144();
        } else {
            require(token == token1, "PairOracle: INVALID_TOKEN");
            amountOut = price1Average.mul(pricePrecision).decode144();
        }
    }

    function spot(address token, uint256 pricePrecision) external view returns (uint256 amountOut) {
        IUniswapV2Pair uniswapPair = IUniswapV2Pair(pair);
        address _token0 = uniswapPair.token0();
        address _token1 = uniswapPair.token1();
        require(_token0 == token || _token1 == token, "Invalid pair");
        (uint256 _reserve0, uint256 _reserve1, ) = uniswapPair.getReserves();
        require(_reserve0 > 0 && _reserve1 > 0, "No reserves");
        uint8 _token0MissingDecimals = 18 - (ERC20(_token0).decimals());
        uint8 _token1MissingDecimals = 18 - (ERC20(_token1).decimals());
        uint256 _price = 0;
        if (token == _token0) {
            _price = (_reserve1 * (10**_token1MissingDecimals) * pricePrecision) / _reserve0;
        } else {
            _price = (_reserve0 * (10**_token0MissingDecimals) * pricePrecision) / _reserve1;
        }
        return _price;
    }

    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(address _pair)
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        blockTimestamp = currentBlockTimestamp();
        IUniswapV2Pair uniswapPair = IUniswapV2Pair(_pair);
        price0Cumulative = uniswapPair.price0CumulativeLast();
        price1Cumulative = uniswapPair.price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 _blockTimestampLast) = uniswapPair.getReserves();
        unchecked {
            if (_blockTimestampLast != blockTimestamp) {
                // subtraction overflow is desired
                uint32 timeElapsed = blockTimestamp - _blockTimestampLast;
                // addition overflow is desired
                // counterfactual
                price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
                // counterfactual
                price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
            }
        }
    }

    // EVENTS
    event PeriodUpdated(uint256 _period);
}
