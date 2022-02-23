// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPairOracle.sol";

contract MasterOracle is Ownable {
    uint256 private constant PRICE_PRECISION = 1e18;

    IPairOracle public oracleXftm;
    IPairOracle public oracleFantasm;

    address public xftm;
    address public fantasm;

    constructor(
        address _xftm,
        address _fantasm,
        address _oracleXftm,
        address _oracleFantasm
    ) {
        require(_xftm != address(0), "Invalid address");
        require(_fantasm != address(0), "Invalid address");
        require(_oracleXftm != address(0), "Invalid address");
        require(_oracleFantasm != address(0), "Invalid address");
        xftm = _xftm;
        fantasm = _fantasm;
        oracleXftm = IPairOracle(_oracleXftm);
        oracleFantasm = IPairOracle(_oracleFantasm);
    }

    function getFantasmPrice() public view returns (uint256) {
        return oracleFantasm.spot(fantasm, PRICE_PRECISION);
    }

    function getXftmPrice() public view returns (uint256) {
        return oracleXftm.spot(xftm, PRICE_PRECISION);
    }

    function getXftmTWAP() public view returns (uint256) {
        return oracleXftm.twap(xftm, PRICE_PRECISION);
    }

    function getFantasmTWAP() public view returns (uint256) {
        return oracleFantasm.twap(fantasm, PRICE_PRECISION);
    }
}
