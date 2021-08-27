//SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "hardhat/console.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ICrowdfund.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";
import "./Ownable.sol";

//PledgeDividendPools receive pledge token, and award bonus token according different pool
contract PledgeDividendPools is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many pledged tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of bonusTokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSushiPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSushiPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 bonusToken;           // Address of bonus token contract.
        IERC20 pledgeToken;           // Address of pledge token contract.
        uint256 lastRewardBlock;  // Last block number that bonusTokens distribution occurs.
        uint256 accSushiPerShare; // Accumulated bonusTokens per share, times 1e12. See below.
        uint256 pledgeTotalAmount;      // the amount of pledge Token access into Schedule Pool.every pool has owner pledge total amount.(pledge token is same)
        address crowdfund;        // Address of crowdfund contract,transfer bonusToken to this contract.
        uint256 nonDividendAmount; // Dividends enter into non dividend pool when no one pledged
    }


    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    //uint256 public totalAllocPoint = 0;

    uint256 public startBlock;

    mapping(address => bool) public isCrowdfund;
    modifier onlyCrowdFunds() {
        require (isCrowdfund[_msgSender()],'PledgeDividendPools:only crowdFunds contract can call');

        _;
    }

    mapping(address => bool) public isManagers;
    modifier onlyManagers() {
        require (isManagers[_msgSender()],'PledgeDividendPools:only managers can call');

        _;
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(

        uint256 _startBlock
    ) public {

        startBlock = _startBlock;
        isManagers[_msgSender()] = true;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        address _crowdfundAddr,
        IERC20 _bonusToken,
        IERC20 _pledgeToken
    ) public onlyManagers {
        require(!isCrowdfund[_crowdfundAddr],'_crowdfundAddr already has  a pool');
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        poolInfo.push(PoolInfo({
            bonusToken:_bonusToken,
            pledgeToken:_pledgeToken,
            lastRewardBlock: lastRewardBlock,
            accSushiPerShare: 0,
            pledgeTotalAmount:0,
            crowdfund:_crowdfundAddr,
            nonDividendAmount:0
        }));

        isCrowdfund[_crowdfundAddr] = true;
    }

    // set crowdFund address accepted by pledgeDividendPools
    function setCrowdFund(address _crowdFundAddr,bool _bo) public onlyOwner {
        isCrowdfund[_crowdFundAddr] = _bo;
    }
    // set manager address accepted by pledgeDividendPools
    function setManager(address _manager,bool _bo) public onlyOwner {
        isManagers[_manager] = _bo;
    }
    function withdrawNonDividendPool(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 _nonDividendAmount = pool.nonDividendAmount;
        if(_nonDividendAmount > 0) {
            pool.nonDividendAmount = 0;//add v2
            safeBonusTokenTransfer(pool.bonusToken, _msgSender(), _nonDividendAmount);
        }

    }

    // View function to see pending bonusTokens on frontend.
    //pendingSushi = user.amount*accSushiPerShare_now - user.rewardDebt
    function pendingBonusToken(uint256 _pid, address _user) external view returns (uint256) {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSushiPerShare = pool.accSushiPerShare;

        return user.amount.mul(accSushiPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables of the given pool to be up-to-date.
    // only call by crowdfund contract
    //Crowdfund transfer _bonusAmountDaily CrowdfundToken to PledgeMint contract which accumulate pool.accSushiPerShare and bonusTotalAmount
    function updatePool(uint256 _pid,uint256 _bonusAmountDaily) external onlyCrowdFunds{
        //_bonusAmountDaily from Crowdfund transfer CrowdfundToken to PledgeMint contract accumulate pool.accSushiPerShare and bonusTotalAmount
        uint256 sushiReward = _bonusAmountDaily;
        if(sushiReward == 0) {
            return;
        }
        PoolInfo storage pool = poolInfo[_pid];
        //check only own crowdfund can call
        require(_msgSender() == pool.crowdfund,'only own crowdfund can call');

        if (block.number <= pool.lastRewardBlock) {
            pool.nonDividendAmount = pool.nonDividendAmount.add(_bonusAmountDaily);
            return;
        }
        //uint256 lpSupply = pledgeToken.balanceOf(address(this));
        uint256 pledgeTotalAmount = pool.pledgeTotalAmount;
        if (pledgeTotalAmount == 0) {
            pool.lastRewardBlock = block.number;
            pool.nonDividendAmount = pool.nonDividendAmount.add(_bonusAmountDaily);
            return;
        }

        //this step move into crowdfund contract which dividend to PledgeMint contrcat actively.
        //Need compare balance before and after transfer on crowdfund contract
        //pool.bonusToken.transferFrom(pool.crowdfund,address(this), sushiReward);
        if(pledgeTotalAmount > 0) {
            pool.accSushiPerShare = pool.accSushiPerShare.add(sushiReward.mul(1e12).div(pledgeTotalAmount));
        }
        pool.lastRewardBlock = block.number;

    }

    // Deposit LP tokens to MasterChef for bonusTokens allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        //updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
        if ( pending > 0 ) {
            safeBonusTokenTransfer(pool.bonusToken, _msgSender(), pending);
        }

        pool.pledgeTotalAmount = pool.pledgeTotalAmount.add(_amount);
        pool.pledgeToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        emit Deposit(_msgSender(), _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount >= _amount, "withdraw: not good");
        address _crowdfund = pool.crowdfund;
        ICrowdfund(_crowdfund).transferBonus();
        //updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
        if( pending > 0 ) {
            safeBonusTokenTransfer(pool.bonusToken, _msgSender(), pending);
        }

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);

        pool.pledgeTotalAmount = pool.pledgeTotalAmount.sub(_amount);
        pool.pledgeToken.safeTransfer(address(_msgSender()), _amount);

        emit Withdraw(_msgSender(), _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        pool.pledgeTotalAmount = pool.pledgeTotalAmount.sub(user.amount);
        pool.pledgeToken.safeTransfer(address(_msgSender()), user.amount);

        emit EmergencyWithdraw(_msgSender(), _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe bonus token transfer function, just in case if rounding error causes pool to not have enough bonus tokens.
    function safeBonusTokenTransfer(IERC20 bonusToken, address _to, uint256 _amount) internal {
        uint256 bonusTokenBal = bonusToken.balanceOf(address(this));
        if (_amount > bonusTokenBal) {
            bonusToken.safeTransfer(_to, bonusTokenBal);
        } else {
            bonusToken.safeTransfer(_to, _amount);
        }
    }

}
