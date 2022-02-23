// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Fantasm is ERC20Burnable {
    using SafeMath for uint256;

    uint256 public constant MAX_TOTAL_SUPPLY = 30_000_000 ether;
    uint256 public constant GENESIS_SUPPLY = 1000 ether; // to provide liquidity at the beginning

    uint256 public constant DEV_ALLOCATION = 6_000_000 ether; // 20%
    uint256 public constant DEV_VESTING_DURATION = 3 * 365 * 24 * 3600; // 3 years
    uint256 public constant DEV_VESTING_START = 1645333200;

    uint256 public constant TREASURY_ALLOCATION = 3_000_000 ether; // 10%
    uint256 public constant TREASURY_VESTING_DURATION = 3 * 365 * 24 * 3600; // 3 years
    uint256 public constant TREASURY_VESTING_START = 1645246800;

    address public rewarder;
    address public pool;
    address public devFund;
    address public treasuryFund;

    /* ========== CONSTRUCTOR ========== */

    constructor() ERC20("FOO", "FOO") {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    /* =========== MODIFIER ========== */

    modifier onlyMinters() {
        require(rewarder == msg.sender || treasuryFund == msg.sender || devFund == msg.sender || pool == msg.sender, "Fantasm::onlyMinters: Only minters allowed");
        _;
    }

    /* ============ MUTATIVE ========== */

    function setRewarder(address _rewarder) external returns (bool) {
        require(rewarder == address(0), "Fantasm::setRewarder: NOT_ALLOWED");
        rewarder = _rewarder;
        return true;
    }

    function setTreasuryFund(address _treasuryFund)
        external
        returns (
            uint256 _allocation,
            uint256 _vestingDuration,
            uint256 _vestingStart
        )
    {
        require(treasuryFund == address(0), "Fantasm::setTreasuryFund: NOT_ALLOWED");
        treasuryFund = _treasuryFund;
        _allocation = TREASURY_ALLOCATION;
        _vestingDuration = TREASURY_VESTING_DURATION;
        _vestingStart = TREASURY_VESTING_START;
    }

    function setDevFund(address _devFund)
        external
        returns (
            uint256 _allocation,
            uint256 _vestingDuration,
            uint256 _vestingStart
        )
    {
        require(devFund == address(0), "Fantasm::setDevFund: NOT_ALLOWED");
        devFund = _devFund;
        _allocation = DEV_ALLOCATION;
        _vestingDuration = DEV_VESTING_DURATION;
        _vestingStart = DEV_VESTING_START;
    }

    function setPool(address _newPool) external returns (bool) {
        require(pool == address(0), "Fantasm::setPool: NOT_ALLOWED");
        pool = _newPool;
        return true;
    }

    // add back onlyMinters for PRODUCTION
    function mint(address _to, uint256 _value) external returns (bool) {
        require(MAX_TOTAL_SUPPLY >= totalSupply() + _value, "Fantasm::mint: > MAX_TOTAL_SUPPLY");
        _mint(_to, _value);
        return true;
    }
}
