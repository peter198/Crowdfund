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
        uint256 rewardDebt; // Reward debt
    }
    // Info of each pool.
    struct PoolInfo {
        IERC20 bonusToken;           // Address of bonus token contract.
        IERC20 pledgeToken;           // Address of pledge token contract.
        uint256 lastRewardBlock;  // Last block number that bonusTokens distribution occurs.
        uint256 accSushiPerShare; // Accumulated bonusTokens per share, times 1e12. See below.
        uint256 pledgeTotalAmount;      // the amount of pledge Token access into Schedule Pool.every pool has owner pledge total amount.(pledge token is same)
        uint256 nonDividendAmount; // Dividends enter into non dividend pool when no one pledged.
        address crowdfund;        // Address of crowdfund contract,transfer bonusToken to this contract.
    }
    // Info of main user.
    struct MainUserInfo {
        uint256 amount;     // How many pledged tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256[] sideRewardDebts; // Side Pools' reward debts. It is used to accurately calculate the user's dividend of the side pools
    }
    // Info of main pool.
    struct MainPoolInfo {
        IERC20 pledgeToken;           // Address of pledge token contract.
        IERC20 bonusToken;           // Address of bonus token contract.
        uint256 lastRewardBlock;  // Last block number that bonusTokens distribution occurs.
        uint256 ownAccSushiPerShare; // Accumulated bonusTokens per share, times 1e12. See below.
        uint256 pledgeTotalAmount;      // the amount of pledge Token access into Schedule Pool.every pool has owner pledge total amount.(pledge token is same)
        uint256 nonDividendAmount; // Dividends enter into non dividend pool when no one pledged.
        uint256 allocPoint;       // How many allocation points assigned to this main pool.
        address crowdfund;        // Address of crowdfund contract,transfer bonusToken to this contract.
        uint256[] sideAccSushiPerShares; // Accumulated bonusTokens per share, times 1e12. See below.
    }

    // Info of super user.
    struct SuperUserInfo {
        uint256 amount;     // How many pledged tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256[] mainRewardDebts; // Main Pools' reward debts. It is used to accurately calculate the user's dividend of the main pools
        uint256[] sideRewardDebts; // Side Pools' reward debts. It is used to accurately calculate the user's dividend of the side pools
    }
    // Info of super pool.
    struct SuperPoolInfo {
        IERC20 pledgeToken;           // Address of pledge token contract.
        IERC20 bonusToken;           // Address of bonus token contract.
        uint256 lastRewardBlock;  // Last block number that bonusTokens distribution occurs.
        uint256 ownAccSushiPerShare; // Accumulated bonusTokens per share, times 1e12. See below.
        uint256 pledgeTotalAmount;      // the amount of pledge Token access into Schedule Pool.every pool has owner pledge total amount.(pledge token is same)
        uint256 nonDividendAmount; // Dividends enter into non dividend pool when no one pledged.
        uint256 allocPoint;       // How many allocation points assigned to this main pool.
        address crowdfund;        // Address of crowdfund contract,transfer bonusToken to this contract.
        uint256[] mainAccSushiPerShares; // Accumulated main bonus tokens per share, times 1e12.
        uint256[] sideAccSushiPerShares; // Accumulated side bonus tokens per share, times 1e12.
    }

    //super pool info
    SuperPoolInfo public hipsPoolInfo;

    IERC20[] public bonusTokensOfMainPool;// Address of bonus token contract for main pool.
    IERC20[] public bonusTokensOfSidePool;// Address of bonus token contract for side pool.

    // Info of each side pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    // Info of each side pool.
    MainPoolInfo[] public mainPoolInfos;
    // Info of main user that stakes LP tokens.
    mapping (uint256 => mapping (address => MainUserInfo)) public mainUserInfo;

    // Info of super user that stakes LP tokens.
    mapping (address => SuperUserInfo) public hipsUserInfo;

    uint256 public startBlock;
    // Total allocation points. Must be the sum of all allocation points in all main pools.
    uint256 public totalAllocPoint = 0;
    //allocation rate of side pool bonus
    uint256 public allocRate_main = 20;//per 1000

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
    //poolType: 0 represent super pool,1 represent main pool. 2 represent side pool
    event Deposit(address indexed user, uint8 indexed poolType,uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint8 indexed poolType,uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint8 indexed poolType, uint256 indexed pid, uint256 amount);

    constructor(uint256 _startBlock) public {
        startBlock = _startBlock;
        isManagers[_msgSender()] = true;
    }

    ///deprecated function, reserved because it's called in the factory contract when create crowdfund contract
    function add(address _crowdfundAddr,IERC20 _bonusToken,IERC20 _pledgeToken) external onlyManagers {}

    // Init hips super pool
    function initSuperPool(
        address _crowdfundAddr,
        IERC20 _bonusToken,
        IERC20 _pledgeToken,
        uint256 _allocPoint
    ) public onlyManagers returns(bool) {
        require(!isCrowdfund[_crowdfundAddr],'_crowdfundAddr already has  a pool');
        require(address(hipsPoolInfo.bonusToken) == address(0) && hipsPoolInfo.lastRewardBlock == 0,'already init');
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        //init super pool and add it into mainPoolInfos
        uint256 _sidePoolLen = poolInfo.length;
        uint256[] memory _sideAccSushiPerShares = new uint256[](_sidePoolLen);
        for(uint256 i = 0;i<_sidePoolLen;i++) {
            _sideAccSushiPerShares[i]=0;
        }

        uint256 _mainPoolLen = mainPoolInfos.length;
        uint256[] memory _mainAccSushiPerShares = new uint256[](_mainPoolLen);
        for(uint256 i = 0;i < _mainPoolLen; i++) {
            _mainAccSushiPerShares[i]=0;
        }
        //init status of hippo pool
        hipsPoolInfo.bonusToken = _bonusToken;
        hipsPoolInfo.pledgeToken = _pledgeToken;
        hipsPoolInfo.lastRewardBlock = lastRewardBlock;
        hipsPoolInfo.ownAccSushiPerShare = 0;
        hipsPoolInfo.pledgeTotalAmount = 0;
        hipsPoolInfo.nonDividendAmount = 0;
        hipsPoolInfo.allocPoint = _allocPoint;
        hipsPoolInfo.crowdfund = _crowdfundAddr;
        hipsPoolInfo.mainAccSushiPerShares = _mainAccSushiPerShares;
        hipsPoolInfo.sideAccSushiPerShares = _sideAccSushiPerShares;

        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        isCrowdfund[_crowdfundAddr] = true;

        return true;
    }

    function addSidePool(
        address _crowdfundAddr,
        IERC20 _bonusToken,
        IERC20 _pledgeToken
    ) public onlyManagers {
        require(!isCrowdfund[_crowdfundAddr],'this crowdfund already has a pool');
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

        bonusTokensOfSidePool.push(_bonusToken);
        uint256 _mainPoolLen = mainPoolInfos.length;
        for(uint256 i = 0;i<_mainPoolLen;i++) {
            MainPoolInfo storage mainPoolInfo = mainPoolInfos[i];
            mainPoolInfo.sideAccSushiPerShares.push(0);
        }
        hipsPoolInfo.sideAccSushiPerShares.push(0);

        isCrowdfund[_crowdfundAddr] = true;
    }

    // Add a new lp to the main pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addMainPool(
        address _crowdfundAddr,
        IERC20 _bonusToken,
        IERC20 _pledgeToken,
        uint256 _allocPoint
    ) public onlyManagers {
        require(!isCrowdfund[_crowdfundAddr],'_crowdfundAddr already has  a pool');
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        //init new main pool and add it into mainPoolInfos
        uint256 _sidePoolLen = poolInfo.length;
        uint256[] memory _sideAccSushiPerShares = new uint256[](_sidePoolLen);
        for(uint256 i = 0;i<_sidePoolLen;i++) {
            _sideAccSushiPerShares[i]=0;
        }

        mainPoolInfos.push(MainPoolInfo({
        bonusToken : _bonusToken,
        pledgeToken : _pledgeToken,
        lastRewardBlock : lastRewardBlock,
        ownAccSushiPerShare : 0,
        pledgeTotalAmount : 0,
        nonDividendAmount : 0,
        allocPoint : _allocPoint,
        crowdfund : _crowdfundAddr,
        sideAccSushiPerShares : _sideAccSushiPerShares
        }));

        bonusTokensOfMainPool.push(_bonusToken);
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        hipsPoolInfo.mainAccSushiPerShares.push(0);

        isCrowdfund[_crowdfundAddr] = true;
    }

    // Update the given pool's SUSHI allocation point. Can only be called by the owner.
    function setPoolInfo(uint256 _pid, uint256 _allocPoint,bool isHipsPool) public onlyOwner {
        if(isHipsPool) {
            totalAllocPoint = totalAllocPoint.sub(hipsPoolInfo.allocPoint).add(_allocPoint);
            hipsPoolInfo.allocPoint = _allocPoint;
        }else {
            totalAllocPoint = totalAllocPoint.sub(mainPoolInfos[_pid].allocPoint).add(_allocPoint);
            mainPoolInfos[_pid].allocPoint = _allocPoint;
        }

    }

    function setAllPoolInfo(uint256[] memory _allocPoints,uint256 _hipsAllocPoint) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(hipsPoolInfo.allocPoint).add(_hipsAllocPoint);
        hipsPoolInfo.allocPoint = _hipsAllocPoint;

        uint256 mainLen = mainPoolInfos.length;
        for(uint256 i = 0;i < mainLen;i++){
            totalAllocPoint = totalAllocPoint.sub(mainPoolInfos[i].allocPoint).add(_allocPoints[i]);
            mainPoolInfos[i].allocPoint = _allocPoints[i];
        }

    }

    // set crowdFund address accepted by pledgeDividendPools
    function setCrowdFund(address _crowdFundAddr,bool _bo) public onlyOwner {
        isCrowdfund[_crowdFundAddr] = _bo;
    }
    // set manager address accepted by pledgeDividendPools
    function setManager(address _manager,bool _bo) public onlyOwner {
        isManagers[_manager] = _bo;
    }
    // set allocation rate of side pool bonus to main and super or main pool to super pool
    function setAllocRate(uint256 _allocRate_main) public onlyOwner returns(bool) {
        require(_allocRate_main <=1000,'too large');
        allocRate_main = _allocRate_main;
        return true;
    }

    //withdraw non-dividend of hippo/main/side pool,only call by owner
    function withdrawNonDividendPool(uint256 _pid,bool isHipsPool) public onlyOwner {
        uint256 _nonDividendAmount = 0;
        if(isHipsPool) {
            _nonDividendAmount = hipsPoolInfo.nonDividendAmount;
            if(_nonDividendAmount > 0) {
                hipsPoolInfo.nonDividendAmount = 0;
                safeBonusTokenTransfer(hipsPoolInfo.bonusToken, _msgSender(), _nonDividendAmount);
            }

            return;
        }

        if(_pid >=10000) {
            _pid = _pid.sub(10000);
            PoolInfo storage pool = poolInfo[_pid];
            _nonDividendAmount = pool.nonDividendAmount;
            if(_nonDividendAmount > 0) {
                pool.nonDividendAmount = 0;
                safeBonusTokenTransfer(pool.bonusToken, _msgSender(), _nonDividendAmount);
            }
        }else {
            MainPoolInfo storage mainPool = mainPoolInfos[_pid];
            _nonDividendAmount = mainPool.nonDividendAmount;
            if(_nonDividendAmount > 0) {
                mainPool.nonDividendAmount = 0;
                safeBonusTokenTransfer(mainPool.bonusToken, _msgSender(), _nonDividendAmount);
            }

        }

    }

    // View function to see pending bonusTokens on frontend.
    //pendingSushi = user.amount*accSushiPerShare_now - user.rewardDebt
    function pendingBonusToken(uint256 _pid, address _user) external view returns (uint256) {
        if(_pid >=80000) {
            SuperUserInfo storage superUser = hipsUserInfo[_user];
            uint256 ownAccSushiPerShare = hipsPoolInfo.ownAccSushiPerShare;
            return superUser.amount.mul(ownAccSushiPerShare).div(1e12).sub(superUser.rewardDebt);
        }

        if(_pid >= 10000) {//side pool Bonus
            _pid = _pid.sub(10000);
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accSushiPerShare = pool.accSushiPerShare;
            return user.amount.mul(accSushiPerShare).div(1e12).sub(user.rewardDebt);
        }else {//main pool Bonus
            MainPoolInfo storage mainPool = mainPoolInfos[_pid];
            MainUserInfo storage mainUser = mainUserInfo[_pid][_user];
            uint256 ownAccSushiPerShare = mainPool.ownAccSushiPerShare;
            //withdraw main bonus token
            return mainUser.amount.mul(ownAccSushiPerShare).div(1e12).sub(mainUser.rewardDebt);
        }

    }
    //pending main BonusTokens of super pool's user
    function pendingMainBonusTokensOfSuperPool(address _user) external view returns (uint256[] memory pendingTokens) {
        SuperUserInfo storage superUser = hipsUserInfo[_user];
        uint256 len = hipsPoolInfo.mainAccSushiPerShares.length;
        uint256 userDebtsLen = superUser.mainRewardDebts.length;
        uint256 _pendingToken;
        len = len < userDebtsLen ? len : userDebtsLen;
        if(len > 0) {
            pendingTokens = new uint256[](len);
            for (uint256 i = 0;i<len;i++) {
                _pendingToken = superUser.amount.mul(hipsPoolInfo.mainAccSushiPerShares[i]).div(1e12)
                .sub(superUser.mainRewardDebts[i]);
                pendingTokens[i] = _pendingToken;
            }
        }

        return pendingTokens;
    }
    //pending side BonusTokens of super pool's user
    function pendingSideBonusTokensOfSuperPool(address _user) external view returns (uint256[] memory pendingTokens) {
        SuperUserInfo storage superUser = hipsUserInfo[_user];
        uint256 len = hipsPoolInfo.sideAccSushiPerShares.length;
        uint256 userDebtsLen = superUser.sideRewardDebts.length;
        uint256 _pendingToken;
        len = len < userDebtsLen ? len : userDebtsLen;
        if(len > 0) {
            pendingTokens = new uint256[](len);
            for (uint256 i = 0;i<len;i++) {
                _pendingToken = superUser.amount.mul(hipsPoolInfo.sideAccSushiPerShares[i]).div(1e12)
                .sub(superUser.sideRewardDebts[i]);
                pendingTokens[i] = _pendingToken;
            }
        }

        return pendingTokens;
    }
    //pending side BonusTokens of main pool's user
    function pendingSideBonusTokens(uint256 _pid, address _user) external view returns (uint256[] memory pendingTokens) {
        MainPoolInfo storage mainPool = mainPoolInfos[_pid];
        MainUserInfo storage mainUser = mainUserInfo[_pid][_user];
        uint256 len = mainPool.sideAccSushiPerShares.length;
        uint256 userDebtsLen = mainUser.sideRewardDebts.length;
        uint256 _pendingToken;
        len = len < userDebtsLen ? len : userDebtsLen;
        if(len > 0) {
            pendingTokens = new uint256[](len);
            for (uint256 i = 0;i<len;i++) {
                _pendingToken = mainUser.amount.mul(mainPool.sideAccSushiPerShares[i]).div(1e12)
                .sub(mainUser.sideRewardDebts[i]);
                pendingTokens[i] = _pendingToken;
            }
        }

        return pendingTokens;
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
        //update hippo pool
        if(_pid >= 80000) {
            //check only own crowdfund can call
            require(_msgSender() == hipsPoolInfo.crowdfund,'only own crowdfund can call');
            if (block.number <= hipsPoolInfo.lastRewardBlock) {
                hipsPoolInfo.nonDividendAmount = hipsPoolInfo.nonDividendAmount.add(sushiReward);
                return;
            }
            uint256 pledgeTotalAmount = hipsPoolInfo.pledgeTotalAmount;
            if (pledgeTotalAmount == 0) {
                hipsPoolInfo.nonDividendAmount = hipsPoolInfo.nonDividendAmount.add(sushiReward);
                hipsPoolInfo.lastRewardBlock = block.number;
                return;
            }

            if(pledgeTotalAmount > 0) {
                hipsPoolInfo.ownAccSushiPerShare= hipsPoolInfo.ownAccSushiPerShare.add(sushiReward.mul(1e12).div(pledgeTotalAmount));
            }

            hipsPoolInfo.lastRewardBlock = block.number;

            return;
        }

        uint256 sushiReward_other = sushiReward.mul(allocRate_main).div(1000);
        uint256 sushiReward_own = sushiReward.sub(sushiReward_other);
        //update side pool
        if(_pid >= 10000){//side pool distribute bonus
            _pid = _pid.sub(10000);
            PoolInfo storage pool = poolInfo[_pid];
            //check only own crowdfund can call
            require(_msgSender() == pool.crowdfund,'only own crowdfund can call');
            uint256 pledgeTotalAmount_side = pool.pledgeTotalAmount;
            //check lastRewardBlock of side pool
            if (block.number <= pool.lastRewardBlock) {
                pool.nonDividendAmount = pool.nonDividendAmount.add(sushiReward_own);
            }else {//block.number > pool.lastRewardBlock
                if (pledgeTotalAmount_side == 0) {
                    pool.nonDividendAmount = pool.nonDividendAmount.add(sushiReward_own);
                    pool.lastRewardBlock = block.number;
                }
                //update the accSushiPerShare of side pool
                if(pledgeTotalAmount_side > 0) {
                    pool.accSushiPerShare = pool.accSushiPerShare.add(sushiReward_own.mul(1e12).div(pledgeTotalAmount_side));
                    pool.lastRewardBlock = block.number;
                }
            }

            //update status of main pool
            uint256 _mainLen = mainPoolInfos.length;
            uint256 usedReward = 0;
            for (uint256 i = 0;i<_mainLen;i++) {
                MainPoolInfo storage mainPoolInfo = mainPoolInfos[i];
                uint256 _sushiReward = sushiReward_other.mul(mainPoolInfo.allocPoint).div(totalAllocPoint);
                //check lastRewardBlock of main pool
                if(block.number <= mainPoolInfo.lastRewardBlock) {
                    pool.nonDividendAmount = pool.nonDividendAmount.add(_sushiReward);
                }else {//block.number > mainPoolInfo.lastRewardBlock
                    if (mainPoolInfo.pledgeTotalAmount == 0) {
                        pool.nonDividendAmount = pool.nonDividendAmount.add(_sushiReward);
                    }
                    ////update the sideAccSushiPerShare of main pool
                    if(mainPoolInfo.pledgeTotalAmount > 0){
                        mainPoolInfo.sideAccSushiPerShares[_pid] = mainPoolInfo.sideAccSushiPerShares[_pid]
                        .add(_sushiReward.mul(1e12).div(mainPoolInfo.pledgeTotalAmount));
                    }
                }

                usedReward = usedReward.add(_sushiReward);

            }

            //distribute side bonus to hips pool
            uint256 pledgeTotalAmount_hips = hipsPoolInfo.pledgeTotalAmount;
            // uint256 sushiReward_hips = sushiReward_other.mul(hipsPoolInfo.allocPoint).div(totalAllocPoint);
            uint256 sushiReward_hips = sushiReward_other.sub(usedReward);
            if (block.number <= hipsPoolInfo.lastRewardBlock) {
                pool.nonDividendAmount = pool.nonDividendAmount.add(sushiReward_hips);
            }else {
                if (pledgeTotalAmount_hips == 0) {
                    pool.nonDividendAmount = pool.nonDividendAmount.add(sushiReward_hips);
                }
                if(pledgeTotalAmount_hips > 0) {
                    hipsPoolInfo.sideAccSushiPerShares[_pid]= hipsPoolInfo.sideAccSushiPerShares[_pid].add(sushiReward_hips.mul(1e12).div(pledgeTotalAmount_hips));
                }
            }

        }else {////update main pool, main pool distribute bonus
            MainPoolInfo storage mainPoolInfo = mainPoolInfos[_pid];
            //check only own crowdfund can call
            require(_msgSender() == mainPoolInfo.crowdfund,'only own crowdfund can call');
            uint256 pledgeTotalAmount_own = mainPoolInfo.pledgeTotalAmount;
            //check lastRewardBlock of side pool
            if (block.number <= mainPoolInfo.lastRewardBlock) {
                mainPoolInfo.nonDividendAmount = mainPoolInfo.nonDividendAmount.add(sushiReward_own);
            }else {//block.number > mainPoolInfo.lastRewardBlock
                if (pledgeTotalAmount_own == 0) {
                    mainPoolInfo.nonDividendAmount = mainPoolInfo.nonDividendAmount.add(sushiReward_own);
                }
                //update the accSushiPerShare of side pool
                if(pledgeTotalAmount_own > 0) {
                    mainPoolInfo.ownAccSushiPerShare = mainPoolInfo.ownAccSushiPerShare.add(sushiReward_own.mul(1e12).div(pledgeTotalAmount_own));
                }

                mainPoolInfo.lastRewardBlock = block.number;
            }

            //update hippo pool
            uint256 pledgeTotalAmount_hips = hipsPoolInfo.pledgeTotalAmount;
            if (block.number <= hipsPoolInfo.lastRewardBlock) {
                mainPoolInfo.nonDividendAmount = mainPoolInfo.nonDividendAmount.add(sushiReward_other);
            }else {
                if (pledgeTotalAmount_hips == 0) {
                    mainPoolInfo.nonDividendAmount = mainPoolInfo.nonDividendAmount.add(sushiReward_other);
                }
                if(pledgeTotalAmount_hips > 0) {
                    hipsPoolInfo.mainAccSushiPerShares[_pid]= hipsPoolInfo.mainAccSushiPerShares[_pid].add(sushiReward_other.mul(1e12).div(pledgeTotalAmount_hips));
                }
            }

        }

    }
    //settle bonus when deposit or withdraw
    function settleBonus(IERC20 _bonusToken,address _user,uint256 _pending) internal {
        if( _pending > 0 ) {
            safeBonusTokenTransfer(_bonusToken, _user, _pending);
        }
    }

    // Deposit LP tokens to Hips PledgeDividendPools for bonusTokens allocation.
    function depositToHipsPool(uint256 _amount) public {

        //updatePool(_pid);
        SuperUserInfo storage hipsUser = hipsUserInfo[_msgSender()];
        //withdraw bonus token of main pool
        uint256 pending = hipsUser.amount.mul(hipsPoolInfo.ownAccSushiPerShare).div(1e12).sub(hipsUser.rewardDebt);

        settleBonus(hipsPoolInfo.bonusToken, _msgSender(), pending);

        //fulfill user's main rewardDebts
        uint256 mainLen = bonusTokensOfMainPool.length;
        uint256 rewardDebtsMainLen = hipsUser.mainRewardDebts.length;
        if(rewardDebtsMainLen < mainLen) {
            for(uint256 j=rewardDebtsMainLen;j<mainLen;j++) {
                hipsUser.mainRewardDebts.push(0);
            }
        }

        //fulfill user's side rewardDebts
        uint256 len = bonusTokensOfSidePool.length;
        uint256 rewardDebtsLen = hipsUser.sideRewardDebts.length;
        if(rewardDebtsLen < len) {
            for(uint256 j=rewardDebtsLen;j<len;j++) {
                hipsUser.sideRewardDebts.push(0);
            }
        }
        //withdraw bonus token of main pools
        uint256 _pendingToken = 0;
        for (uint256 i = 0;i< mainLen;i++) {
            _pendingToken = hipsUser.amount.mul(hipsPoolInfo.mainAccSushiPerShares[i]).div(1e12)
            .sub(hipsUser.mainRewardDebts[i]);

            settleBonus(bonusTokensOfMainPool[i], _msgSender(), _pendingToken);
        }

        //withdraw bonus token of side pools
        _pendingToken = 0;
        for (uint256 i = 0;i<len;i++) {
            _pendingToken = hipsUser.amount.mul(hipsPoolInfo.sideAccSushiPerShares[i]).div(1e12)
            .sub(hipsUser.sideRewardDebts[i]);

            settleBonus(bonusTokensOfSidePool[i], _msgSender(), _pendingToken);
        }

        hipsPoolInfo.pledgeTotalAmount = hipsPoolInfo.pledgeTotalAmount.add(_amount);
        hipsPoolInfo.pledgeToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

        hipsUser.amount = hipsUser.amount.add(_amount);
        hipsUser.rewardDebt = hipsUser.amount.mul(hipsPoolInfo.ownAccSushiPerShare).div(1e12);

        for (uint256 j = 0;j<mainLen;j++) {
            hipsUser.mainRewardDebts[j] = hipsUser.amount.mul(hipsPoolInfo.mainAccSushiPerShares[j]).div(1e12);
        }

        for (uint256 j = 0;j<len;j++) {
            hipsUser.sideRewardDebts[j] = hipsUser.amount.mul(hipsPoolInfo.sideAccSushiPerShares[j]).div(1e12);
        }


        emit Deposit(_msgSender(), uint8(0), 0, _amount);
    }
    // Deposit LP tokens to main PledgeDividendPools for bonusTokens allocation.
    function depositToMainPool(uint256 _pid, uint256 _amount) public {

        //updatePool(_pid);
        // deposit to main pool
        MainPoolInfo storage mainPool = mainPoolInfos[_pid];
        MainUserInfo storage mainUser = mainUserInfo[_pid][_msgSender()];
        //withdraw bonus token of main pool
        uint256 pending = mainUser.amount.mul(mainPool.ownAccSushiPerShare).div(1e12).sub(mainUser.rewardDebt);

        settleBonus(mainPool.bonusToken, _msgSender(), pending);

        //fulfill user's side rewardDebts
        uint256 len = bonusTokensOfSidePool.length;
        uint256 rewardDebtsLen = mainUser.sideRewardDebts.length;
        if(rewardDebtsLen < len) {
            for(uint256 j=rewardDebtsLen;j<len;j++) {
                mainUser.sideRewardDebts.push(0);
            }
        }

        //withdraw bonus token of side pools
        uint256 _pendingToken = 0;
        for (uint256 i = 0;i<len;i++) {
            _pendingToken = mainUser.amount.mul(mainPool.sideAccSushiPerShares[i]).div(1e12)
            .sub(mainUser.sideRewardDebts[i]);

            settleBonus(bonusTokensOfSidePool[i], _msgSender(), _pendingToken);
        }

        mainPool.pledgeTotalAmount = mainPool.pledgeTotalAmount.add(_amount);
        mainPool.pledgeToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

        mainUser.amount = mainUser.amount.add(_amount);
        mainUser.rewardDebt = mainUser.amount.mul(mainPool.ownAccSushiPerShare).div(1e12);
        for (uint256 j = 0;j<len;j++) {
            mainUser.sideRewardDebts[j] = mainUser.amount.mul(mainPool.sideAccSushiPerShares[j]).div(1e12);
        }

        emit Deposit(_msgSender(), uint8(1), _pid, _amount);
    }
    // Deposit LP tokens to side PledgeDividendPools for bonusTokens allocation.
    function depositToSidePool(uint256 _pid, uint256 _amount) public {

        //updatePool(_pid);
        // deposit into side pool
        require(_pid >= 10000,'_pid need GT 10000');
        _pid = _pid.sub(10000);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);

        settleBonus(pool.bonusToken, _msgSender(), pending);

        pool.pledgeTotalAmount = pool.pledgeTotalAmount.add(_amount);
        pool.pledgeToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);

        emit Deposit(_msgSender(), uint8(2), _pid, _amount);
    }

    // Deposit LP tokens to Hips PledgeDividendPools for bonusTokens allocation.
    function withdrawFromHipsPool(uint256 _amount) public {

        //updatePool(_pid);
        SuperUserInfo storage hipsUser = hipsUserInfo[_msgSender()];
        require(hipsUser.amount >= _amount, "withdraw: not good");
        address _crowdfund = hipsPoolInfo.crowdfund;
        //A bonus reward will be given if the conditions are met
        ICrowdfund(_crowdfund).transferBonus();

        //withdraw bonus token of main pool
        uint256 pending = hipsUser.amount.mul(hipsPoolInfo.ownAccSushiPerShare).div(1e12).sub(hipsUser.rewardDebt);

        settleBonus(hipsPoolInfo.bonusToken, _msgSender(), pending);

        //fulfill user's main rewardDebts
        uint256 mainLen = bonusTokensOfMainPool.length;
        uint256 rewardDebtsMainLen = hipsUser.mainRewardDebts.length;
        if(rewardDebtsMainLen < mainLen) {
            for(uint256 j=rewardDebtsMainLen;j<mainLen;j++) {
                hipsUser.mainRewardDebts.push(0);
            }
        }

        //fulfill user's side rewardDebts
        uint256 len = bonusTokensOfSidePool.length;
        uint256 rewardDebtsLen = hipsUser.sideRewardDebts.length;
        if(rewardDebtsLen < len) {
            for(uint256 j=rewardDebtsLen;j<len;j++) {
                hipsUser.sideRewardDebts.push(0);
            }
        }
        //withdraw bonus token of main pools
        uint256 _pendingToken = 0;
        for (uint256 i = 0;i< mainLen;i++) {
            _pendingToken = hipsUser.amount.mul(hipsPoolInfo.mainAccSushiPerShares[i]).div(1e12)
            .sub(hipsUser.mainRewardDebts[i]);

            settleBonus(bonusTokensOfMainPool[i], _msgSender(), _pendingToken);
        }

        //withdraw bonus token of side pools
        _pendingToken = 0;
        for (uint256 i = 0;i<len;i++) {
            _pendingToken = hipsUser.amount.mul(hipsPoolInfo.sideAccSushiPerShares[i]).div(1e12)
            .sub(hipsUser.sideRewardDebts[i]);

            settleBonus(bonusTokensOfSidePool[i], _msgSender(), _pendingToken);
        }

        hipsUser.amount = hipsUser.amount.sub(_amount);
        hipsUser.rewardDebt = hipsUser.amount.mul(hipsPoolInfo.ownAccSushiPerShare).div(1e12);
        for (uint256 j = 0;j<mainLen;j++) {
            hipsUser.mainRewardDebts[j] = hipsUser.amount.mul(hipsPoolInfo.mainAccSushiPerShares[j]).div(1e12);
        }

        for (uint256 j = 0;j<len;j++) {
            hipsUser.sideRewardDebts[j] = hipsUser.amount.mul(hipsPoolInfo.sideAccSushiPerShares[j]).div(1e12);
        }

        hipsPoolInfo.pledgeTotalAmount = hipsPoolInfo.pledgeTotalAmount.sub(_amount);
        hipsPoolInfo.pledgeToken.safeTransfer(address(_msgSender()), _amount);

        emit Withdraw(_msgSender(), uint8(0), 0, _amount);
    }

    // Withdraw LP tokens from main PledgeDividendPools.
    function withdrawFromMainPool(uint256 _pid, uint256 _amount) public {

        // withdraw into main pool
        MainPoolInfo storage mainPool = mainPoolInfos[_pid];
        MainUserInfo storage mainUser = mainUserInfo[_pid][_msgSender()];

        require(mainUser.amount >= _amount, "withdraw: not good");
        address _crowdfund = mainPool.crowdfund;
        //A bonus reward will be given if the conditions are met
        ICrowdfund(_crowdfund).transferBonus();
        //withdraw main bonus token
        uint256 pending = mainUser.amount.mul(mainPool.ownAccSushiPerShare).div(1e12).sub(mainUser.rewardDebt);

        settleBonus(mainPool.bonusToken, _msgSender(), pending);

        //fulfill user's side rewardDebts
        uint256 len = bonusTokensOfSidePool.length;
        uint256 rewardDebtsLen = mainUser.sideRewardDebts.length;
        if(rewardDebtsLen < len) {
            for(uint256 j=rewardDebtsLen;j<len;j++) {
                mainUser.sideRewardDebts.push(0);
            }
        }

        //withdraw side bonus token
        uint256 _pendingToken;
        for (uint256 i = 0;i<len;i++) {
            _pendingToken = 0;
            _pendingToken = mainUser.amount.mul(mainPool.sideAccSushiPerShares[i]).div(1e12)
            .sub(mainUser.sideRewardDebts[i]);

            settleBonus(bonusTokensOfSidePool[i], _msgSender(), _pendingToken);
        }
        mainUser.amount = mainUser.amount.sub(_amount);
        mainUser.rewardDebt = mainUser.amount.mul(mainPool.ownAccSushiPerShare).div(1e12);
        for (uint256 j = 0;j<len;j++) {
            mainUser.sideRewardDebts[j] = mainUser.amount.mul(mainPool.sideAccSushiPerShares[j]).div(1e12);
        }

        mainPool.pledgeTotalAmount = mainPool.pledgeTotalAmount.sub(_amount);
        mainPool.pledgeToken.safeTransfer(address(_msgSender()), _amount);

        emit Withdraw(_msgSender(), uint8(1), _pid, _amount);
    }

    // Withdraw LP tokens from side PledgeDividendPools.
    function withdrawFromSidePool(uint256 _pid, uint256 _amount) public {

        // withdraw into side pool
        require(_pid >= 10000,'_pid need GT 10000');
        _pid = _pid.sub(10000);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount >= _amount, "withdraw: not good");
        address _crowdfund = pool.crowdfund;
        //A bonus reward will be given if the conditions are met
        ICrowdfund(_crowdfund).transferBonus();
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);

        settleBonus(pool.bonusToken, _msgSender(), pending);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);

        pool.pledgeTotalAmount = pool.pledgeTotalAmount.sub(_amount);
        pool.pledgeToken.safeTransfer(address(_msgSender()), _amount);

        emit Withdraw(_msgSender(), uint8(2), _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        if(_pid >= 80000) {//Withdraw super pool's token (Hips)
            SuperUserInfo storage hipsUser = hipsUserInfo[_msgSender()];
            uint256 _amount = hipsUser.amount;

            hipsPoolInfo.pledgeTotalAmount = hipsPoolInfo.pledgeTotalAmount.sub(_amount);
            hipsPoolInfo.pledgeToken.safeTransfer(address(_msgSender()), _amount);

            emit EmergencyWithdraw(_msgSender(), uint8(0), 0, _amount);
            hipsUser.amount = 0;
            hipsUser.rewardDebt = 0;
            delete hipsUser.sideRewardDebts;
            delete hipsUser.mainRewardDebts;

            return;
        }

        if(_pid >= 10000) {// withdraw of side pool
            _pid = _pid.sub(10000);
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_msgSender()];

            pool.pledgeTotalAmount = pool.pledgeTotalAmount.sub(user.amount);
            pool.pledgeToken.safeTransfer(address(_msgSender()), user.amount);

            emit EmergencyWithdraw(_msgSender(), uint8(2),_pid, user.amount);
            user.amount = 0;
            user.rewardDebt = 0;
        }else {// withdraw of main pool
            MainPoolInfo storage mainPool = mainPoolInfos[_pid];
            MainUserInfo storage mainUser = mainUserInfo[_pid][_msgSender()];
            uint256 _amount = mainUser.amount;

            mainPool.pledgeTotalAmount = mainPool.pledgeTotalAmount.sub(_amount);
            mainPool.pledgeToken.safeTransfer(address(_msgSender()), _amount);

            emit EmergencyWithdraw(_msgSender(), uint8(1), _pid, _amount);
            mainUser.amount = 0;
            mainUser.rewardDebt = 0;
            delete mainUser.sideRewardDebts;

        }

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

    function getMainUserSideRewardDebts(uint256 _pid,address _user) public view returns(uint256[] memory) {
        MainUserInfo memory mainUser = mainUserInfo[_pid][_user];
        return mainUser.sideRewardDebts;
    }
    function getHipsSideRewardDebts(address _user) public view returns(uint256[] memory) {
        SuperUserInfo memory hipsUser = hipsUserInfo[_user];
        return hipsUser.sideRewardDebts;
    }

    function getHipsMainRewardDebts(address _user) public view returns(uint256[] memory) {
        SuperUserInfo memory hipsUser = hipsUserInfo[_user];
        return hipsUser.mainRewardDebts;
    }

    function getMainPoolAccsInfo(uint256 _pid) public view returns(uint256[] memory) {
        MainPoolInfo memory mainPool = mainPoolInfos[_pid];
        return mainPool.sideAccSushiPerShares;
    }

    function getHipsSideAccsInfo() public view returns(uint256[] memory) {
        return hipsPoolInfo.sideAccSushiPerShares;
    }
    function getHipsMainAccsInfo() public view returns(uint256[] memory) {
        return hipsPoolInfo.mainAccSushiPerShares;
    }

    function getBonusTokensOfSidePool() public view returns(IERC20[] memory _bonusTokensOfSidePool) {
        return bonusTokensOfSidePool;
    }

    function getBonusTokensOfMainPool() public view returns(IERC20[] memory _bonusTokensOfMainPool) {
        return bonusTokensOfMainPool;
    }

    function getMainPoolPledgeTotalAmounts() public view returns(uint256[] memory _pledgeTotalAmounts) {
        uint256 mainPoolLen = mainPoolInfos.length;
        _pledgeTotalAmounts = new uint256[](mainPoolLen);
        for(uint256 i =0; i < mainPoolLen; i++) {
            MainPoolInfo memory mainPool = mainPoolInfos[i];
            _pledgeTotalAmounts[i] = mainPool.pledgeTotalAmount;
        }

        return _pledgeTotalAmounts;
    }

    function getMainUserPledgeAmounts(address _user) public view returns(uint256[] memory _pledgeAmounts) {
        uint256 mainPoolLen = mainPoolInfos.length;
        _pledgeAmounts = new uint256[](mainPoolLen);
        for(uint256 i =0; i < mainPoolLen; i++) {
            MainUserInfo memory mainUser = mainUserInfo[i][_user];
            _pledgeAmounts[i] = mainUser.amount;
        }

        return _pledgeAmounts;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length.add(mainPoolInfos.length).add(1);
    }

    function mainPoolLength() external view returns (uint256) {
        return mainPoolInfos.length;
    }

    function sidePoolLength() external view returns (uint256) {
        return poolInfo.length;
    }

}
