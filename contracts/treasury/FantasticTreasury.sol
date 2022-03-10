// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFantasticStaking.sol";

/*  FantasticTreasury.sol ============================================
    The contract is to store the reserve of Fantastic Protocol
    Contract will have a whitelist of strategy contracts which can request funding from Reserve
    These strategy contracts can be used to Allocate fee, Convert reserve to Protocol Owned Liquidity, Recollateralize, etc
==================================================================== */
contract FantasticTreasury is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    mapping(address => bool) public strategies;
    IFantasticStaking public staking;

    constructor(IFantasticStaking _staking) {
        staking = _staking;
    }

    // ========== PUBLIC VIEW FUNCTIONS ============

    /// @notice Return ERC-20 balance of FantasticTreasury
    /// @param _token Address of the ERC-20 token
    /// @return Balance of the FantasticTreasury
    function balanceOf(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Request fund from Reserve - only can be called from whitelisted strategies
    /// @param _token Address of the ERC-20 token
    /// @param _amount The requested amount
    function requestFund(address _token, uint256 _amount) external {
        require(strategies[msg.sender], "FantasticTreasury::requestFund: Only strategies can request fund");
        require(_amount <= balanceOf(_token), "FantasticTreasury::requestFund: Request more fund than balance");
        IERC20(_token).safeIncreaseAllowance(msg.sender, _amount);
        emit FundRequested(msg.sender, _amount);
    }

    /// @notice Add new strategy
    /// @param _strategy Address of the strategy contract
    function addStrategy(address _strategy) external onlyOwner {
        require(_strategy != address(0), "FantasticTreasury::addStrategy: invalid address");
        require(!strategies[_strategy], "FantasticTreasury::addStrategy: strategy was previously added");
        strategies[_strategy] = true;
        emit StrategyAdded(_strategy);
    }

    /// @notice Remove current strategy
    /// @param _strategy Address of the strategy contract
    function removeStrategy(address _strategy) external onlyOwner {
        require(strategies[_strategy], "FantasticTreasury::removeStrategy: strategy not found");
        delete strategies[_strategy];
        emit StrategyRemoved(_strategy);
    }

    /// @notice Allocate protocol's fee to stakers
    /// @param _token Address of ERC-20 token
    /// @param _amount Amount of fee will be distributed
    function allocateFee(address _token, uint256 _amount) external onlyOwner {
        require(address(staking) != address(0), "FantasticTreasury::allocateFee:Fee distributor not set");
        require(_amount > 0, "FantasticTreasury::allocateFee: invalid amount");
        IERC20(_token).safeIncreaseAllowance(address(staking), _amount);
        staking.notifyRewardAmount(_token, _amount);
        emit TokenRewardAllocated(_token, _amount);
    }

    // EVENTS
    event StrategyAdded(address indexed _strategy);
    event StrategyRemoved(address indexed _strategy);
    event FundRequested(address indexed _requester, uint256 _amount);
    event TokenRewardAllocated(address indexed _token, uint256 _amount);
}
