// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../interfaces/IYToken.sol";
import "../interfaces/IYTokenReserve.sol";
import "../libs/WethUtils.sol";

// Based on EPS's & Geist's MultiFeeDistribution
contract FantasticStaking is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IYToken;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    struct Balances {
        uint256 total;
        uint256 unlocked;
        uint256 locked;
        uint256 earned;
    }
    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
    }
    struct RewardData {
        address token;
        uint256 amount;
    }

    IYToken public stakingToken;
    IYTokenReserve public stakingTokenReserve;
    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;

    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7; // 1 week

    // Duration of lock/earned penalty period
    uint256 public constant lockDuration = rewardsDuration * 8; // 8 weeks

    // Addresses approved to call mint
    mapping(address => bool) public minters;
    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    uint256 public totalSupply;
    uint256 public lockedSupply;

    // Private mappings for balance data
    mapping(address => Balances) private balances;
    mapping(address => LockedBalance[]) private userLocks;
    mapping(address => LockedBalance[]) private userEarnings;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingToken,
        address _stakingTokenReserve,
        address[] memory _minters
    ) Ownable() {
        stakingToken = IYToken(_stakingToken);
        stakingTokenReserve = IYTokenReserve(_stakingTokenReserve);
        stakingTokenReserve.setRewarder(address(this));
        for (uint256 i; i < _minters.length; i++) {
            minters[_minters[i]] = true;
        }
        // First reward MUST be the staking token or things will break
        // related to the 50% penalty and distribution to locked balances
        rewardTokens.push(_stakingToken);
        rewardData[_stakingToken].lastUpdateTime = block.timestamp;
        rewardData[_stakingToken].periodFinish = block.timestamp;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    // Add a new reward token to be distributed to stakers
    function addReward(address _rewardsToken, address _distributor) public onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime == 0, "MultiFeeDistribution::addReward: Invalid");
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp;
        rewardDistributors[_rewardsToken][_distributor] = true;
        emit RewardTokenAdded(_rewardsToken);
        emit RewardDistributorApproved(_rewardsToken, _distributor, true);
    }

    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0, "MultiFeeDistribution::approveRewardDistributor: Invalid");
        rewardDistributors[_rewardsToken][_distributor] = _approved;
        emit RewardDistributorApproved(_rewardsToken, _distributor, _approved);
    }

    /* ========== VIEWS ========== */

    function _rewardPerToken(address _rewardsToken, uint256 _supply) internal view returns (uint256) {
        if (_supply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
            rewardData[_rewardsToken].rewardPerTokenStored.add(
                lastTimeRewardApplicable(_rewardsToken).sub(rewardData[_rewardsToken].lastUpdateTime).mul(rewardData[_rewardsToken].rewardRate).mul(1e18).div(_supply)
            );
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance,
        uint256 supply
    ) internal view returns (uint256) {
        return _balance.mul(_rewardPerToken(_rewardsToken, supply).sub(userRewardPerTokenPaid[_user][_rewardsToken])).div(1e18).add(rewards[_user][_rewardsToken]);
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        return Math.min(block.timestamp, rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) external view returns (uint256) {
        uint256 supply = _rewardsToken == address(stakingToken) ? lockedSupply : totalSupply;
        return _rewardPerToken(_rewardsToken, supply);
    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate.mul(rewardsDuration);
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address account) external view returns (RewardData[] memory _rewards) {
        _rewards = new RewardData[](rewardTokens.length);
        for (uint256 i = 0; i < _rewards.length; i++) {
            // If i == 0 this is the stakingReward, distribution is based on locked balances
            uint256 balance = i == 0 ? balances[account].locked : balances[account].total;
            uint256 supply = i == 0 ? lockedSupply : totalSupply;
            _rewards[i].token = rewardTokens[i];
            _rewards[i].amount = _earned(account, _rewards[i].token, balance, supply);
        }
        return _rewards;
    }

    // Total balance of an account, including unlocked, locked and earned tokens
    function totalBalance(address user) external view returns (uint256 amount) {
        return balances[user].total;
    }

    // Total withdrawable balance for an account to which no penalty is applied
    function unlockedBalance(address user) external view returns (uint256 amount) {
        amount = balances[user].unlocked;
        LockedBalance[] storage earnings = userEarnings[msg.sender];
        for (uint256 i = 0; i < earnings.length; i++) {
            if (earnings[i].unlockTime > block.timestamp) {
                break;
            }
            amount = amount.add(earnings[i].amount);
        }
        return amount;
    }

    // Information on the "earned" balances of a user
    // Earned balances may be withdrawn immediately for a 50% penalty
    function earnedBalances(address user) external view returns (uint256 total, LockedBalance[] memory earningsData) {
        LockedBalance[] storage earnings = userEarnings[user];
        uint256 idx;
        for (uint256 i = 0; i < earnings.length; i++) {
            if (earnings[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    earningsData = new LockedBalance[](earnings.length - i);
                }
                earningsData[idx] = earnings[i];
                idx++;
                total = total.add(earnings[i].amount);
            }
        }
        return (total, earningsData);
    }

    // Information on a user's locked balances
    function lockedBalances(address user)
        external
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        )
    {
        LockedBalance[] storage locks = userLocks[user];
        uint256 idx;
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked.add(locks[i].amount);
            } else {
                unlockable = unlockable.add(locks[i].amount);
            }
        }
        return (balances[user].locked, unlockable, locked, lockData);
    }

    // Final balance received and penalty balance paid by user upon calling exit
    function withdrawableBalance(address user) public view returns (uint256 amount, uint256 penaltyAmount) {
        Balances storage bal = balances[user];
        if (bal.earned > 0) {
            uint256 amountWithoutPenalty;
            uint256 length = userEarnings[user].length;
            for (uint256 i = 0; i < length; i++) {
                uint256 earnedAmount = userEarnings[user][i].amount;
                if (earnedAmount == 0) continue;
                if (userEarnings[user][i].unlockTime > block.timestamp) {
                    break;
                }
                amountWithoutPenalty = amountWithoutPenalty.add(earnedAmount);
            }

            penaltyAmount = bal.earned.sub(amountWithoutPenalty).div(2);
        }
        amount = bal.unlocked.add(bal.earned).sub(penaltyAmount);
        return (amount, penaltyAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // Stake tokens to receive rewards
    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    function stake(uint256 amount, bool lock) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "MultiFeeDistribution::stake: Cannot stake 0");
        totalSupply = totalSupply.add(amount);
        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.add(amount);
        if (lock) {
            lockedSupply = lockedSupply.add(amount);
            bal.locked = bal.locked.add(amount);
            uint256 unlockTime = block.timestamp.div(rewardsDuration).mul(rewardsDuration).add(lockDuration);
            uint256 idx = userLocks[msg.sender].length;
            if (idx == 0 || userLocks[msg.sender][idx - 1].unlockTime < unlockTime) {
                userLocks[msg.sender].push(LockedBalance({amount: amount, unlockTime: unlockTime}));
            } else {
                userLocks[msg.sender][idx - 1].amount = userLocks[msg.sender][idx - 1].amount.add(amount);
            }
        } else {
            bal.unlocked = bal.unlocked.add(amount);
        }
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    // Mint new tokens
    // Minted tokens receive rewards normally but incur a 50% penalty when
    // withdrawn before lockDuration has passed.
    function mint(address user, uint256 amount) external updateReward(user) {
        require(minters[msg.sender], "MultiFeeDistribution::mint: Only minters allowed");
        totalSupply = totalSupply.add(amount);
        Balances storage bal = balances[user];
        bal.total = bal.total.add(amount);
        bal.earned = bal.earned.add(amount);
        uint256 unlockTime = block.timestamp.div(rewardsDuration).mul(rewardsDuration).add(lockDuration);
        LockedBalance[] storage earnings = userEarnings[user];
        uint256 idx = earnings.length;

        if (idx == 0 || earnings[idx - 1].unlockTime < unlockTime) {
            earnings.push(LockedBalance({amount: amount, unlockTime: unlockTime}));
        } else {
            earnings[idx - 1].amount = earnings[idx - 1].amount.add(amount);
        }
        stakingTokenReserve.transfer(address(this), amount);
        emit Staked(user, amount);
    }

    // Withdraw staked tokens
    // First withdraws unlocked tokens, then earned tokens. Withdrawing earned tokens
    // incurs a 50% penalty which is distributed based on locked balances.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "MultiFeeDistribution::withdraw: Cannot withdraw 0");
        Balances storage bal = balances[msg.sender];
        uint256 penaltyAmount;

        if (amount <= bal.unlocked) {
            bal.unlocked = bal.unlocked.sub(amount);
        } else {
            uint256 remaining = amount.sub(bal.unlocked);
            require(bal.earned >= remaining, "MultiFeeDistribution::withdraw: Insufficient unlocked balance");
            bal.unlocked = 0;
            bal.earned = bal.earned.sub(remaining);
            for (uint256 i = 0; ; i++) {
                uint256 earnedAmount = userEarnings[msg.sender][i].amount;
                if (earnedAmount == 0) continue;
                if (penaltyAmount == 0 && userEarnings[msg.sender][i].unlockTime > block.timestamp) {
                    penaltyAmount = remaining;
                    require(bal.earned >= remaining, "MultiFeeDistribution::withdraw: Insufficient balance after penalty");
                    bal.earned = bal.earned.sub(remaining);
                    if (bal.earned == 0) {
                        delete userEarnings[msg.sender];
                        break;
                    }
                    remaining = remaining.mul(2);
                }
                if (remaining <= earnedAmount) {
                    userEarnings[msg.sender][i].amount = earnedAmount.sub(remaining);
                    break;
                } else {
                    delete userEarnings[msg.sender][i];
                    remaining = remaining.sub(earnedAmount);
                }
            }
        }

        uint256 adjustedAmount = amount.add(penaltyAmount);
        bal.total = bal.total.sub(adjustedAmount);
        totalSupply = totalSupply.sub(adjustedAmount);
        stakingToken.safeTransfer(msg.sender, amount);
        if (penaltyAmount > 0) {
            _notifyReward(address(stakingToken), penaltyAmount);
        }
        emit Withdrawn(msg.sender, amount);
    }

    // Claim all pending staking rewards
    function getReward() public nonReentrant updateReward(msg.sender) {
        for (uint256 i; i < rewardTokens.length; i++) {
            address _rewardToken = rewardTokens[i];
            uint256 reward = rewards[msg.sender][_rewardToken];
            if (reward > 0) {
                rewards[msg.sender][_rewardToken] = 0;
                if (WethUtils.isWeth(_rewardToken)) {
                    WethUtils.unwrap(reward);
                    payable(msg.sender).transfer(reward);
                } else {
                    IERC20(_rewardToken).safeTransfer(msg.sender, reward);
                }
                emit RewardPaid(msg.sender, _rewardToken, reward);
            }
        }
    }

    // Withdraw full unlocked balance and claim pending rewards
    function emergencyWithdraw() external updateReward(msg.sender) {
        (uint256 amount, uint256 penaltyAmount) = withdrawableBalance(msg.sender);
        delete userEarnings[msg.sender];
        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.sub(bal.unlocked).sub(bal.earned);
        bal.unlocked = 0;
        bal.earned = 0;

        totalSupply = totalSupply.sub(amount.add(penaltyAmount));
        stakingToken.safeTransfer(msg.sender, amount);
        if (penaltyAmount > 0) {
            _notifyReward(address(stakingToken), penaltyAmount);
        }
        getReward();
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function withdrawExpiredLocks() external {
        LockedBalance[] storage locks = userLocks[msg.sender];
        Balances storage bal = balances[msg.sender];
        uint256 amount;
        uint256 length = locks.length;
        if (locks[length - 1].unlockTime <= block.timestamp) {
            amount = bal.locked;
            delete userLocks[msg.sender];
        } else {
            for (uint256 i = 0; i < length; i++) {
                if (locks[i].unlockTime > block.timestamp) break;
                amount = amount.add(locks[i].amount);
                delete locks[i];
            }
        }
        bal.locked = bal.locked.sub(amount);
        bal.total = bal.total.sub(amount);
        totalSupply = totalSupply.sub(amount);
        lockedSupply = lockedSupply.sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
    }



    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(address _rewardsToken, uint256 reward) internal {
        if (block.timestamp >= rewardData[_rewardsToken].periodFinish) {
            rewardData[_rewardsToken].rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = rewardData[_rewardsToken].periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardData[_rewardsToken].rewardRate);
            rewardData[_rewardsToken].rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp.add(rewardsDuration);
    }

    function notifyRewardAmount(address _rewardsToken, uint256 reward) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender], "MultiFeeDistribution::notifyRewardAmount: Only reward distributors allowed");
        require(reward > 0, "MultiFeeDistribution::notifyRewardAmount: No reward");
        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyReward(_rewardsToken, reward);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "MultiFeeDistribution::recoverERC20: Cannot withdraw staking token");
        require(rewardData[tokenAddress].lastUpdateTime == 0, "MultiFeeDistribution::recoverERC20: Cannot withdraw reward token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        address token = address(stakingToken);
        uint256 balance;
        uint256 supply = lockedSupply;
        rewardData[token].rewardPerTokenStored = _rewardPerToken(token, supply);
        rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
        if (account != address(0)) {
            // Special case, use the locked balances and supply for stakingReward rewards
            rewards[account][token] = _earned(account, token, balances[account].locked, supply);
            userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            balance = balances[account].total;
        }

        supply = totalSupply;
        for (uint256 i = 1; i < rewardTokens.length; i++) {
            token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = _rewardPerToken(token, supply);
            rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = _earned(account, token, balance, supply);
                userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            }
        }
        _;
    }

    /// @notice fallback for payable -> required to unwrap WETH
    receive() external payable {}

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event RewardTokenAdded(address indexed rewardTokenAddress);
    event RewardDistributorApproved(address indexed rewardAddress, address indexed distributor, bool approved);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event Recovered(address token, uint256 amount);
}
