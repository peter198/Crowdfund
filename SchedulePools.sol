//SPDX-License-Identifier: MIT

import "hardhat/console.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IBMintToken.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";
import "./MintToken.sol";

pragma solidity ^0.6.0;

//user can enter schedule pools to mint different equity token
contract SchedulePools is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IBMintToken;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SUSHIs
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
        uint256 lastRewardBlock;  // Last block number that mintToken distribution occurs.
        uint256 accSushiPerShare; // Accumulated mintToken per share, times 1e12. See below.
        uint256 virtualTokenSupply;      // the supply of token access into Schedule Pool.
        address crowdfund;        // Address of Crowdfund contract.
        IBMintToken mintToken;
    }

    // The BMintToken TOKEN!
    //BMintToken public bMintToken;

    //  mintable tokens created per block.
    uint256 public sushiPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    //startBlock as first day's start block
    // The block number when SUSHI mining starts.
    uint256 public startBlock;

    //add code
    uint256 public constant ONE_DAY_BLOCKS = 28800;//3s/block;ONE_DAY_BLOCKS = 60/3*60*24 //for prod

    // end reward days
    uint256 public endDays = 3650;//10 years

    //deflationRate
    mapping(uint256 => uint256) public deflationRate_;//per 1e12

    uint256 public allEndBlock;//startBlock + 3650*28800

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    //event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event WithdrawReward(address indexed user, uint256 indexed pid,uint256 rewardAmount);

    mapping(address => bool) public isCrowdfund;
    modifier onlyCrowdFunds() {
        require (isCrowdfund[_msgSender()],'SchedulePools:only crowdFunds contract can call');

        _;
    }

    mapping(address => bool) public isManagers;
    modifier onlyManagers() {
        require (isManagers[_msgSender()],'SchedulePools:only managers can call');

        _;
    }

    constructor(
        uint256 _sushiPerBlock,
        uint256 _startBlock
    ) public {
        
        //347222222222222222;//10000*1e18 per day
        sushiPerBlock = _sushiPerBlock;
        startBlock = _startBlock;

        allEndBlock = startBlock.add(endDays.mul(ONE_DAY_BLOCKS));
        deflationRate_[1] = 1e12;
        // deflationRate_ decline 0.1% daily
        for(uint256 i=2; i<= 720; i++) {
            deflationRate_[i] = deflationRate_[i-1].mul(999).div(1000);
        }

        isManagers[_msgSender()] = true;
    }

    //Set other epoch Reward deflationRate,Can only be called by the owner.
    function setDeflationRate_(uint256 _startIndex, uint256 _len) public onlyOwner {
        require(_startIndex >= 2, "must increase by 2nd epoch reward");
        require(_len <=1000,'_len must be LT 1000');
        // deflationRate_ decline 0.1% daily
        for(uint256 i=_startIndex; i< _startIndex.add(_len); i++) {
            deflationRate_[i] = deflationRate_[i-1].mul(999).div(1000);
        }
    }

    // set crowdFund address accepted by schedule pool
    function setCrowdFund(address _crowdfundAddr,bool _bo) public onlyOwner {
        isCrowdfund[_crowdfundAddr] = _bo;
    }
    // set manager address accepted by schedule pool
    function setManager(address _manager,bool _bo) public onlyOwner {
        isManagers[_manager] = _bo;
    }

    // update startBlock
    function setStartBlock(uint256 _startBlock) public onlyOwner {
        startBlock = _startBlock;
    }

    //store the cumulative sum of every epoch
    mapping(uint256 => uint256) public allDeflationRate_;
    //Set other epoch all deflationRate,Can only be called by the owner.
    function setAllDeflaRate(uint256 _startIndex,uint256 _len) public onlyOwner returns(bool) {
        require(_startIndex >= 2, "_startIndex must GT 2");
        require(_len <=1000,'_len must be LT 1000');
        allDeflationRate_[1] = deflationRate_[1];
        for(uint256 i=_startIndex; i< _startIndex.add(_len); i++) {
            allDeflationRate_[i] = allDeflationRate_[i-1].add(deflationRate_[i]);
        }
        return true;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same crowdfund address more than once. Rewards will be messed up if you do.
    function add(
        address _crowdfundAddr,
        IBMintToken _mintToken,
        bool _withUpdate
    ) public onlyManagers {
        require(!isCrowdfund[_crowdfundAddr],'_crowdfundAddr already has  a pool');
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        poolInfo.push(PoolInfo({

            lastRewardBlock: lastRewardBlock,
            accSushiPerShare: 0,
            virtualTokenSupply:0,
            crowdfund:_crowdfundAddr,
            mintToken:_mintToken
        }));

        isCrowdfund[_crowdfundAddr] = true;
    }

    // Update the given pool's BTOKEN allocation point. Can only be called by the owner.
    function set(uint256 _pid, address _crowdfundAddr, IBMintToken _mintToken,bool _withUpdate) public onlyOwner {
         if (_withUpdate) {
             massUpdatePools();
         }
         poolInfo[_pid].crowdfund = _crowdfundAddr;
         poolInfo[_pid].mintToken = _mintToken;

     }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if(_from <= startBlock) {
            _from =startBlock;
        }
        //return 0 when two case happen
        if (_from >= allEndBlock || _from >=_to) {
            return 0;
        }

        if (_to >= allEndBlock) {
            _to = allEndBlock.sub(1);
        }

        uint256 from_day = _from.sub(startBlock).div(ONE_DAY_BLOCKS).add(1);
        uint256 to_day = _to.sub(startBlock).div(ONE_DAY_BLOCKS).add(1);
        uint256 blocks;
        if (from_day == to_day){
            return _to.sub(_from).mul(deflationRate_[from_day]);
        } else {
            uint256 from_day_block = startBlock.add(ONE_DAY_BLOCKS.mul(from_day)).sub(_from).mul(deflationRate_[from_day]);
            uint256 to_day_block = _to.sub(startBlock.add(ONE_DAY_BLOCKS.mul(to_day-1))).mul(deflationRate_[to_day]);
            blocks = from_day_block + to_day_block;
            blocks = allDeflationRate_[to_day - 1].sub(allDeflationRate_[from_day]).mul(ONE_DAY_BLOCKS).add(blocks);
        }
        return blocks;
    }

    // View function to see pending BTOKENs on frontend.
    function pendingMintToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSushiPerShare = pool.accSushiPerShare;
        // lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 tokenSupply = pool.virtualTokenSupply;
        if (block.number > pool.lastRewardBlock && tokenSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 bTokenReward = multiplier.mul(sushiPerBlock).div(1e12);
            accSushiPerShare = accSushiPerShare.add(bTokenReward.mul(1e12).div(tokenSupply));
        }
        return user.amount.mul(accSushiPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 tokenSupply = pool.virtualTokenSupply;
        if (tokenSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 mintReward = multiplier.mul(sushiPerBlock).div(1e12);

        pool.mintToken.mint(address(this), mintReward);

        pool.accSushiPerShare = pool.accSushiPerShare.add(mintReward.mul(1e12).div(tokenSupply));
        pool.lastRewardBlock = block.number;
    }

    // Enter Schedule pool for BToken allocation.
    function enter(uint256 _pid, address _userAddr,uint256 _amount) public onlyCrowdFunds {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_userAddr];

        //check only own crowdfund can call
        require(_msgSender() == pool.crowdfund,'only own crowdfund can call');
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
            safeBTokenTransfer(_userAddr, pending, pool.mintToken);
        }

        //pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);
        pool.virtualTokenSupply = pool.virtualTokenSupply.add(_amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        emit Deposit(_userAddr, _pid, _amount);

    }

    // Withdraw Schedule pool.
    function withdraw(uint256 _pid, address _userAddr,uint256 _amount) public onlyCrowdFunds{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_userAddr];
        require(user.amount >= _amount, "withdraw: not good");

        //check only own crowdfund can call
        require(_msgSender() == pool.crowdfund,'only own crowdfund can call');

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
        safeBTokenTransfer(_userAddr, pending, pool.mintToken);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);

        //pool.lpToken.safeTransfer(address(_msgSender()), _amount);
        pool.virtualTokenSupply = pool.virtualTokenSupply.sub(_amount);

        emit Withdraw(_userAddr, _pid, _amount);

    }

    // Withdraw reward from Schedule pool.
    function withdrawReward(uint256 _pid) public returns(bool) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        updatePool(_pid);
        if(user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
            safeBTokenTransfer(_msgSender(), pending, pool.mintToken);
            user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);

            emit WithdrawReward(_msgSender(), _pid, pending);
            return true;
        }

        return false;
    }


    // Safe bToken transfer function, just in case if rounding error causes pool to not have enough BTokens.
    function safeBTokenTransfer(address _to, uint256 _amount, IBMintToken _mintToken) internal {
        uint256 bTokenBal = _mintToken.balanceOf(address(this));
        if (_amount > bTokenBal) {
            _mintToken.safeTransfer(_to, bTokenBal);
        } else {
            _mintToken.safeTransfer(_to, _amount);
        }
    }

    //tranfer the ownership of _mintToken to new owner
    function transferBMintTokenOwnership (address _newSushiOwner,address _mintToken) public onlyOwner returns(bool) {
        require(_newSushiOwner != address(0), "Ownable: new owner is the zero address");
        IBMintToken(_mintToken).transferOwnership(_newSushiOwner);
        return true;
    }

    // return the days of xxx block number from startBlock
    function getGivenBlockDay(uint256 _blockNumber) public view returns (uint256) {
        return _blockNumber.sub(startBlock).div(ONE_DAY_BLOCKS).add(1);
    }
    // return the epoch of current block number
    function getCurrentEpoch() public view returns (uint256) {
        return block.number.sub(startBlock).div(ONE_DAY_BLOCKS).add(1);
    }
    //return the day total reward of current epoch
    function getEpochRewards(uint256 _epoch) public view returns (uint256) {
        return sushiPerBlock.mul(deflationRate_[_epoch]).mul(ONE_DAY_BLOCKS).div(1e12);
    }
    function getVirtualTokenSupply(uint256 _pid) public view returns(uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        return pool.virtualTokenSupply;
    }

}
