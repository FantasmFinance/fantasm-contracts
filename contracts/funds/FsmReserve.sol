// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FsmReserve is Initializable {
    using SafeERC20 for IERC20;

    IERC20 public fsm;
    mapping(address => bool) public funds;

    address public rewarder;
    address public pool;
    address public treasuryFund;
    address public daoFund;

    uint256 public constant GENESIS_SUPPLY = 1000 ether; // to provide liquidity at the beginning

    /* =========== MODIFIER ========== */

    modifier onlyFunds() {
        require(funds[msg.sender], "FsmReserve::onlyFunds: Only allowed funds can withdraw");
        _;
    }

    /* ============ CONSTRUCTORS ========== */

    function initialize(IERC20 _fsm) external initializer {
        fsm = _fsm;
        doTransfer(msg.sender, GENESIS_SUPPLY);
    }

    /* ============ MUTATIVE ========== */

    function setRewarder(address _rewarder) external returns (bool) {
        require(rewarder == address(0), "FsmReserve::setRewarder: NOT_ALLOWED");
        rewarder = _rewarder;
        funds[_rewarder] = true;
        return true;
    }

    function setDaoFund(address _daoFund) external returns (bool) {
        require(daoFund == address(0), "FsmReserve::setDaoFund: NOT_ALLOWED");
        daoFund = _daoFund;
        funds[_daoFund] = true;
        return true;
    }

    function setTreasuryFund(address _treasuryFund) external {
        require(treasuryFund == address(0), "FsmReserve::setTreasuryFund: NOT_ALLOWED");
        treasuryFund = _treasuryFund;
        funds[_treasuryFund] = true;
    }

    function setPool(address _pool) external returns (bool) {
        require(pool == address(0), "FsmReserve::setPool: NOT_ALLOWED");
        pool = _pool;
        funds[_pool] = true;
        return true;
    }

    function transfer(address _to, uint256 _amount) external onlyFunds {
        doTransfer(_to, _amount);
    }

    function doTransfer(address _to, uint256 _amount) internal {
        require(_to != address(0), "FsmReserve::transfer: Invalid address");
        fsm.safeTransfer(_to, _amount);
    }
}
