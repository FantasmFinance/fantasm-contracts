// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "../interfaces/IXftm.sol";
import "../interfaces/IFantasm.sol";
import "../interfaces/IMasterOracle.sol";
import "../interfaces/ITreasury.sol";

// To provide views with current on-chain data
contract FantasmLens {
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;
    uint256 private constant PRECISION = 1e6;

    IMasterOracle public oracle;
    ITreasury public treasury;

    constructor(address _treasury, address _oracle) {
        treasury = ITreasury(_treasury);
        oracle = IMasterOracle(_oracle);
    }

    /// @notice Calculate the expected results for minting
    /// @param _ftmIn Amount of FTM input.
    /// @param _fantasmIn Amount of FSM input.
    /// @return _xftmOut : the amount of XFTM output.
    /// @return _minFtmIn : the required amount of FSM input.
    /// @return _minFantasmIn : the required amount of FSM input.
    /// @return _fee : the fee amount in FTM.
    function calcMint(uint256 _ftmIn, uint256 _fantasmIn)
        public
        view
        returns (
            uint256 _xftmOut,
            uint256 _minFtmIn,
            uint256 _minFantasmIn,
            uint256 _fee
        )
    {
        (uint256 _cr, uint256 _mintingFee, ) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "FantasmLens::calcMint: Invalid Fantasm price");
        uint256 _totalValue = 0; // total value in FTM

        if (_cr == COLLATERAL_RATIO_MAX || (_cr > 0 && _ftmIn > 0)) {
            _totalValue = (_ftmIn * COLLATERAL_RATIO_MAX) / _cr;
            _minFtmIn = _ftmIn;
            _minFantasmIn = ((_totalValue - _ftmIn) * PRICE_PRECISION) / _fantasmPrice;
        } else {
            uint256 _fantasmValue = (_fantasmIn * _fantasmPrice) / PRICE_PRECISION;
            _totalValue = (_fantasmValue * COLLATERAL_RATIO_MAX) / (COLLATERAL_RATIO_MAX - _cr);
            _minFantasmIn = _fantasmIn;
            _minFtmIn = _totalValue - _fantasmValue;
        }
        _xftmOut = _totalValue - ((_totalValue * _mintingFee) / PRECISION);
        _fee = (_ftmIn * _mintingFee) / PRECISION;
    }

    function calcZapMint(uint256 _ftmIn)
        public
        view
        returns (
            uint256 _xftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee,
            uint256 _ftmSwapIn
        )
    {
        (uint256 _cr, uint256 _mintingFee, ) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "FantasmLens::calcZapMint: Invalid Fantasm price");
        _ftmSwapIn = (_ftmIn * (COLLATERAL_RATIO_MAX - _cr)) / COLLATERAL_RATIO_MAX;
        _fantasmOut = (_ftmSwapIn * PRICE_PRECISION) / _fantasmPrice;
        _ftmFee = (_ftmIn * _mintingFee * _cr) / COLLATERAL_RATIO_MAX / PRECISION;
        _xftmOut = _ftmIn - ((_ftmIn * _mintingFee) / PRECISION);
    }

    function calcRedeem(uint256 _xftmIn)
        external
        view
        returns (
            uint256 _ftmOut,
            uint256 _fantasmOut,
            uint256 _ftmFee
        )
    {
        (uint256 _cr, , uint256 _redemptionFee) = treasury.info();
        uint256 _fantasmPrice = oracle.getFantasmPrice();
        require(_fantasmPrice > 0, "FantasmLens::calcRedeem: Invalid Fantasm price");

        if (_cr < COLLATERAL_RATIO_MAX) {
            uint256 _fantasmValueOut = (_xftmIn - ((_xftmIn * _cr) / PRECISION));
            uint256 _fantasmOutPostFee = (_fantasmValueOut * PRICE_PRECISION) / _fantasmPrice; // before fee
            _fantasmOut = _fantasmOutPostFee - ((_fantasmOutPostFee * _redemptionFee) / PRECISION); // after fee
        }

        if (_cr > 0) {
            uint256 _ftmOutPostFee = ((_xftmIn * _cr) / PRECISION);
            _ftmFee = (_ftmOutPostFee * _redemptionFee) / PRECISION; // redemption fee in FTM
            _ftmOut = _ftmOutPostFee - _ftmFee; // after fee
        }
    }
}
