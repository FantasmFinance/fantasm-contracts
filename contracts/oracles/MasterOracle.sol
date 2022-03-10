// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPairOracle.sol";

contract MasterOracle is Ownable {
    uint256 private constant PRICE_PRECISION = 1e18;

    IPairOracle public oracleXToken;
    IPairOracle public oracleYToken;

    address public xToken;
    address public yToken;

    constructor(
        address _xToken,
        address _yToken,
        address _oracleXToken,
        address _oracleYToken
    ) {
        require(_xToken != address(0), "Invalid address");
        require(_yToken != address(0), "Invalid address");
        require(_oracleXToken != address(0), "Invalid address");
        require(_oracleYToken != address(0), "Invalid address");
        xToken = _xToken;
        yToken = _yToken;
        oracleXToken = IPairOracle(_oracleXToken);
        oracleYToken = IPairOracle(_oracleYToken);
    }

    function getXTokenPrice() public view returns (uint256) {
        return oracleXToken.spot(xToken, PRICE_PRECISION);
    }

    function getYTokenPrice() public view returns (uint256) {
        return oracleYToken.spot(yToken, PRICE_PRECISION);
    }

    function getXTokenTWAP() public view returns (uint256) {
        return oracleXToken.twap(xToken, PRICE_PRECISION);
    }

    function getYTokenTWAP() public view returns (uint256) {
        return oracleYToken.twap(yToken, PRICE_PRECISION);
    }
}
