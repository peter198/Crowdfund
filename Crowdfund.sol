// SPDX-License-Identifier: MIT
//import "hardhat/console.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IPledgeDividendPool.sol";
import "./interfaces/ISchedulePool.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";
import "./libraries/SafeMath32.sol";
import "./Ownable.sol";

pragma solidity ^0.6.12;

/**
 * @dev Crowdfund contract
 */
contract Crowdfund is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SafeMath32 for uint32;

    //project name
    string public name;
    uint256 public constant ONE_DAY = 1 days;//for prod
    uint256 public restartWaitTime = 1 days;
    //uint256 public constant ONE_DAY = 5 minutes;//for dev
    //uint256 public restartWaitTime = 5 minutes;

    //the min amount of investment
    uint256 public minAmount;
    //the max amount of investment
    uint256 public maxAmount;

    //Token for CrowdFund
    IERC20 public token;

    //the contract address of schedulePool
    address public schedulePool;
    //the contract address of pledgeDividendPool
    address public pledgeDividendPool;
    // own schedule pool id
    uint256 public schedulePoolId;
    // own pledge pool id
    uint256 public pledgeDividendPoolId;
    // Managing the operation of contracts
    address public manager;

    // equity token
    IERC20 public equityToken;

    bool public isContinued = true;
    bool public isNeedBatch = false;

    // Total withdraw
    uint256 public totalWithdraw;
    //the max crowdfund limit in next round
    uint256 public futureDurition = 0;
    //Rounds of global crowdfund
    uint256 public curRoundNum;
    //restart times of global crowdfund
    uint256 public curRestartTimes;
    uint256[] public lastFailRestartTimes;
    mapping(uint256 => uint256) public lastFailRestartTimesFailedAt;
    //loss rate of fail restart times// restartTimes => lossRate  //per 1e12
    mapping(uint256 => uint256) public lossRateOfFailRestartTimes;
    //max limit of total amount of every round
    mapping(uint256 => uint256) public maxLimitPerRounds;

    //record Round mapping
    struct RoundRecord {
        uint256 curRestartTimes_;
        uint256 curRoundNum_;
    }
    //total number of crowdfund
    uint32 public totalNumberOfCf;
    mapping(uint32 => RoundRecord) public roundRecords;
    //max loss rate
    uint256 public lossRateLimit = 6e11;//per 1e12 for prod
    //uint256 public lossRateLimit = 5e10;//per 10000 for dev

    // withdraw rate of return every 3 rounds, per 100
    uint256 public staticRate = 5;
    // dividend rate , per 100
    uint256 public dividendRate = 10;
    //Distribution rate from dividendPool, , per 100
    uint256 distributeRate = 1;
    //current amount of dividend Pool
    uint256 public dividendPool;
    //capital pool to expense user's income
    uint256 public capitalPool;

    //the total amount of distribution
    uint256 public bonusPool;
    //last time of distribution
    uint256 public lastBonusTime;
    //switch of allowing bonus
    bool public isAllowBonus = true;

    bool public isEmergencyStatus;
    //the rate of withdrawal on emergency rate
    uint256 public emergencyRate;

    // User Struct
    struct User {
        uint256 investAmount; // Invested quantity: 0 means init status
        uint256 joinTime; // Join time: This value needs to be updated when joining again
        uint256 income; // Total income
        uint32 joinRound;
        uint32 reinvest; // reinvest times
        uint8 investStatus;// 0 => init status ; 1=>invest status; 2 => schedule status
    }

    mapping(address => User) public users;
    mapping(address => uint256) public userIndex;
    address[] public userList;

    // Represents the status of the crowdfund
    enum Status {
        NotStarted,     // The crowdfund has not started yet
        Open,           // The crowdfund is open for token investment
        Completed,      // The crowdfund has been closed when reached target amount and time out
        Failed          // The crowdfund has failed this round
    }
    // All the needed info around a crowdfund
    struct CrowdfundInfo {
        Status status;       // Status for crowdfund
        uint256 startTime;      // Block timestamp for star of crowdfund
        uint256 closeTime;       // Block timestamp for end of entries
        uint256 startIndexOfStage;             // Start index of user list for crowdfund stage
        uint256 endIndexOfStage;             // End index of user list for crowdfund stage
        uint256 curTotalAmount;     // current total amount of crowdfunding this round/crowdfundID
        uint256 withdrawTotalAmount; //after completed ,when user withdarw the income,accumulate user's investAmount
    }

    // schedule pool info
    struct SchedulePoolInfo {
        uint256 startIndex;             // Start index of user list for schedule pool
        uint256 endIndex;             // End index of user list for schedule pool
        uint256 curTotalAmount;     // current total amount of crowdfunding this round/crowdfundID
    }

    SchedulePoolInfo public schedulePoolInfo;

    //mapping(curRestartTimes => mapping(curRoundNum => Crowdfund info)) this round
    mapping(uint256 => mapping(uint256 => CrowdfundInfo)) public allCrowdfunds_;
    //accumulate all curTotalAmount of crowdfunds
    mapping(uint256 => uint256) public allTotalAmount;

    event Invest(address indexed user,uint256 amount);
    event Refund(address indexed user,uint256 amount);
    event Withdraw(address indexed user,uint256 amount);

    modifier onlyJoined(){
        require(userIndex[_msgSender()] > 0,"user must joined");

        _;
    }

    modifier onlyManager(){
        require(_msgSender() == manager || _msgSender() == owner(),"Crowdfund:user must be manager");

        _;
    }

    constructor(
        string memory _name,
        IERC20 _crowdfundToken,
        address _schedulePool,
        address _pledgeDividendPool,
        address _manager,
        uint256 _firstRoundMaxLimit,
        uint256 _minAmount,
        uint256 _maxAmount,
        IERC20 _equityToken
    ) public {
        name = _name;
        token = _crowdfundToken;
        schedulePool = _schedulePool;
        pledgeDividendPool = _pledgeDividendPool;
        manager = _manager;
        minAmount = _minAmount;
        maxAmount = _maxAmount;
        equityToken = _equityToken;

        lastBonusTime = block.timestamp;

        maxLimitPerRounds[1] = _firstRoundMaxLimit;

        for (uint256 i = 2;i <= 100;i++) {
            maxLimitPerRounds[i] = maxLimitPerRounds[i - 1].mul(115).div(100);
        }

        //set userList[0] = 0x00,and real users start with index 1 of userList
        //mapping[userAddress] = index, index is not 0;
        userList.push(address(0));

    }

    ///initialize the first crowdfund
    function initialize() public onlyManager returns (bool) {
        require(isContinued && curRestartTimes == 0 && curRoundNum == 0,'cannot initialize');
        //start first-round crowdfund
        curRestartTimes = 1;
        curRoundNum = 1;

        initNewCrowdfund(0);

        return true;
    }

    /// init a new crowdfund
    function initNewCrowdfund(uint256 addAmount) internal {
        uint256 initIndex = 0;
        if(schedulePoolInfo.curTotalAmount > 0) {
            initIndex = schedulePoolInfo.startIndex;
        }else {
            if(userList.length > 1){
                initIndex = userList.length.add(addAmount).sub(1);
}
        }

        allCrowdfunds_[curRestartTimes][curRoundNum] = CrowdfundInfo (
        {
            status:Status.Open,
            startTime:block.timestamp,
            closeTime:block.timestamp.add(getDurition(curRoundNum).mul(ONE_DAY)),
            startIndexOfStage:initIndex,
            endIndexOfStage:initIndex,
            curTotalAmount:0,
            withdrawTotalAmount:0
        });
        totalNumberOfCf = totalNumberOfCf.add(1);
        roundRecords[totalNumberOfCf] = RoundRecord({
            curRestartTimes_ : curRestartTimes,
            curRoundNum_ : curRoundNum
        });

        uint256 _dividend_last4 = calculateExpenses();

        //allocate the dividend amount of to dividend Pool
        dividendPool = dividendPool.add(_dividend_last4);
        //update capitalPool
        capitalPool = capitalPool.sub(_dividend_last4);
        //calculate lossRate, force restart when lossRate greater than lossRateLimit
        calculateLossRate();

    }

    //calculate lossRate, force restart when lossRate greater than lossRateLimit
    function calculateLossRate() internal returns(uint256 lossRate,uint256 last3TotalAmount){
        if(curRoundNum >= 4) {
            last3TotalAmount = 0;
            for(uint256 i=0;i<=2;i++) {
                CrowdfundInfo memory crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum.sub(i)];
                last3TotalAmount = last3TotalAmount.add(crowdfund.curTotalAmount);

            }
            uint256 numerator = allTotalAmount[curRoundNum.sub(3)].mul(staticRate.add(dividendRate)).div(100);

            //per 1e12
            lossRate = numerator.mul(1e12).div(last3TotalAmount);

            if (lossRate >= lossRateLimit) {
                CrowdfundInfo storage crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum];
                crowdfund.status = Status.Failed;
                crowdfund.closeTime = block.timestamp;

                lossRateOfFailRestartTimes[curRestartTimes] = lossRate;//per 1e12

                failAndWaitRestart();
            }
            return (lossRate,last3TotalAmount);
        }

        return(0,0);

    }

    function calculateExpenses() public view returns(uint256 _dividend_last4) {
        if(curRoundNum >= 4) {
            CrowdfundInfo memory last4Crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum.sub(3)];
            uint256 _curTotalAmount_last4 = last4Crowdfund.curTotalAmount;
            _dividend_last4 = _curTotalAmount_last4.mul(dividendRate).div(100);
        }

        return _dividend_last4;
    }

    /**
     * @dev invest token into Crowdfund contract
     * @param _amount the amount of token investing
     * @return true when success
    */
    function invest(uint256 _amount) public returns(bool) {
        //if failed and passed restart time now,initialize new crowdfund
        _restartAndCreateNewCrowdfund();
        require(isContinued && curRestartTimes > 0, 'failed now, please wait restart!');
        require(userIndex[_msgSender()] == 0,'cannot invest when user already existed');//todo maybe wrong
        require(_amount >= minAmount && _amount <= maxAmount,'The amount of investment need GT minAmount and LT maxAmount');

        CrowdfundInfo storage crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum];

        if(block.timestamp <= crowdfund.closeTime) {//do not reach close time
            // Receive Token
            token.safeTransferFrom(_msgSender(), address(this), _amount);
            //totalRevenue = totalRevenue.add(_amount);
            capitalPool = capitalPool.add(_amount);
            // create new user
            User storage user = users[_msgSender()];
            uint256 lastIndex = _createNewUser(_msgSender(),_amount);

            //do not reach max corwdfund limit
            if(crowdfund.curTotalAmount.add(schedulePoolInfo.curTotalAmount) < maxLimitPerRounds[curRoundNum]) {

                user.investStatus = uint8(1);// 1 => invest status;
                user.joinRound = totalNumberOfCf;
                emit Invest(_msgSender(),_amount);
                correctSchedulePoolInfo();
                if(schedulePoolInfo.curTotalAmount > 0 && schedulePoolInfo.endIndex < userList.length) {
                    batchJoinCrowdfundFromSchedule();

                }

                //update crowdfund info this round
                if(crowdfund.startIndexOfStage == 0) {
                    crowdfund.startIndexOfStage = lastIndex;
                }
                crowdfund.endIndexOfStage = lastIndex;
                crowdfund.curTotalAmount = crowdfund.curTotalAmount.add(_amount);

                isCompleted();

            }else {//crowdfund.curTotalAmount.add(schedulePoolInfo.curTotalAmount) >= maxLimitPerRounds[curRoundNum]

                user.investStatus = uint8(2);// 2 => schedule status
                //update schedulePool info
                updateSchedulePoolInfo(lastIndex,_amount);

                //start schedule pool mint
                _joinScheduleMint(schedulePoolId, _msgSender(), _amount);

                if(crowdfund.curTotalAmount < maxLimitPerRounds[curRoundNum]) {
                    correctSchedulePoolInfo();
                    if(schedulePoolInfo.curTotalAmount > 0 && schedulePoolInfo.endIndex < userList.length) {
                        batchJoinCrowdfundFromSchedule();

                    }

                }

            }

            //if his crowdfund reached max corwdfund limit,emit CrowdfundCompleted event
            isCompleted();

        }else {//reached close time
            //do not reach max amount limit this round
            if(crowdfund.curTotalAmount < maxLimitPerRounds[curRoundNum]) {
                // this round crowdfund fail and withdraw all according rules
                //crowdfund failed ,wait 1 day to restart
                correctSchedulePoolInfo();
                if(schedulePoolInfo.curTotalAmount == 0) {
                    failAndWaitRestart();
                    crowdfund.status = Status.Failed;
                    (uint256 lossRate,) = calculateLossRate();
                    lossRateOfFailRestartTimes[curRestartTimes] = lossRate;
                    return false;
                }else {
                    if(schedulePoolInfo.endIndex < userList.length) {
                        isNeedBatch = true;
                        //the amount of batch join is LT 50
                        batchJoinCrowdfundFromSchedule();
                    }
                }

            } else {//reach max amount limit this round
                // Receive Token
                token.safeTransferFrom(_msgSender(), address(this), _amount);
                //totalRevenue = totalRevenue.add(_amount);
                capitalPool = capitalPool.add(_amount);
                // create new user
                User storage user = users[_msgSender()];
                uint256 lastIndex = _createNewUser(_msgSender(),_amount);
                isCompleted();

                curRoundNum++;
                 //start next round crowdfund
                initNewCrowdfund(0);

                CrowdfundInfo storage curCrowdfund = allCrowdfunds_[curRestartTimes][curRoundNum];
                correctSchedulePoolInfo();
                if(schedulePoolInfo.curTotalAmount > 0 && schedulePoolInfo.endIndex < userList.length) {
                    isNeedBatch = true;
                    //the amount of batch join is LT 50
                    batchJoinCrowdfundFromSchedule();

                }
                if(curCrowdfund.curTotalAmount.add(schedulePoolInfo.curTotalAmount) < maxLimitPerRounds[curRoundNum]){
                    //join crowdfund
                    //update new user status to crowdfund
                    user.investStatus = uint8(1);
                    user.joinRound = totalNumberOfCf;
                    emit Invest(_msgSender(),_amount);
                    //update crowdfund info this round
                    if(curCrowdfund.startIndexOfStage == 0) {

                        curCrowdfund.startIndexOfStage = lastIndex;
                    }
                    curCrowdfund.endIndexOfStage = lastIndex;
                    curCrowdfund.curTotalAmount = curCrowdfund.curTotalAmount.add(_amount);


                }else{//join schedule
                    //update new user status to schedule
                    user.investStatus = uint8(2);
                    //update schedulePool info
                    updateSchedulePoolInfo(lastIndex,_amount);
                    //start schedule pool mint
                    _joinScheduleMint(schedulePoolId, _msgSender(), _amount);

                }

                //if his crowdfund reached max corwdfund limit,emit CrowdfundCompleted event
                isCompleted();

            }
        }

        //transfer bonus every day
        transferBonus();
        return true;
    }

    //promote crowdfund forward
    function promoteCrowdfund() public returns(bool) {
        require(curRestartTimes > 0,'cannot promote');
        //if passed restartWaitTime, create new crowdfund
        _restartAndCreateNewCrowdfund();

        CrowdfundInfo storage crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum];
        correctSchedulePoolInfo();
        if(block.timestamp <= crowdfund.closeTime) {//do not reach close time
            //do not reach max corwdfund limit
            if(crowdfund.curTotalAmount< maxLimitPerRounds[curRoundNum]) {
                if(schedulePoolInfo.curTotalAmount > 0 && schedulePoolInfo.endIndex < userList.length) {
                    isNeedBatch = true;
                    batchJoinCrowdfundFromSchedule();
                }

            }
            //if his crowdfund reached max corwdfund limit,emit CrowdfundCompleted event
            isCompleted();

        }else {//reached close time
            //do not reach max amount limit this round
            if(crowdfund.curTotalAmount < maxLimitPerRounds[curRoundNum]) {
                if(schedulePoolInfo.curTotalAmount == 0) {
                    failAndWaitRestart();
                    crowdfund.status = Status.Failed;
                    (uint256 lossRate,) = calculateLossRate();
                    lossRateOfFailRestartTimes[curRestartTimes] = lossRate;
                    //if passed restartWaitTime, create new crowdfund
                    _restartAndCreateNewCrowdfund();

                }else {
                    if(schedulePoolInfo.endIndex < userList.length) {
                        isNeedBatch = true;
                        //the amount of batch join is LT 50
                        batchJoinCrowdfundFromSchedule();
                    }
                }

            } else {//reach max amount limit this round
                isCompleted();
                curRoundNum++;
                //start next round crowdfund
                initNewCrowdfund(0);
                if(schedulePoolInfo.curTotalAmount > 0 && schedulePoolInfo.endIndex < userList.length) {
                    isNeedBatch = true;
                    //the amount of batch join is LT 50
                    batchJoinCrowdfundFromSchedule();
                }
            }

        }

        return true;
    }

    //if passed restartWaitTime, create new crowdfund
    function _restartAndCreateNewCrowdfund() internal {
        if(!isContinued && allCrowdfunds_[curRestartTimes][curRoundNum].closeTime.add(restartWaitTime) <= now) {
            //restart crowdfund
            isContinued = true;
            curRestartTimes++;
            curRoundNum = 1;
            //get init crowdfund status
            initNewCrowdfund(1);
        }
    }

    ///update schedulePool info
    function updateSchedulePoolInfo(uint256 _lastIndex,uint256 _accAmount) internal {
        if(schedulePoolInfo.curTotalAmount == 0) {
            schedulePoolInfo.startIndex = _lastIndex;
        }
        schedulePoolInfo.endIndex = _lastIndex;
        schedulePoolInfo.curTotalAmount = schedulePoolInfo.curTotalAmount.add(_accAmount);

    }

    function failAndWaitRestart() internal {
        isContinued = false;
        lastFailRestartTimes.push(curRestartTimes);
        lastFailRestartTimesFailedAt[curRestartTimes] = curRoundNum;
    }

    // create new user
    function _createNewUser(address _userAddr,uint256 _newAmount) internal returns(uint256) {

        User storage user = users[_userAddr];
        userList.push(_userAddr);
        uint256 lastIndex = userList.length.sub(1);
        userIndex[_userAddr] = lastIndex;
        user.joinTime = block.timestamp;
        user.investAmount = user.investAmount.add(_newAmount);

        return lastIndex;
    }

    //join schedule pool and mint platform token
    function _joinScheduleMint(uint256 _schedulePoolId, address _userAddr, uint256 _amount) internal {
        ISchedulePool(schedulePool).enter(_schedulePoolId, _userAddr, _amount);
    }

    // batch join crowdfund from schedule pool
    function _batchJoinCfFromSchedule(uint256 _startIndex, uint256 _endIndex) internal {
        address _userAddr;
        uint256 _amount;
        for(uint256 i = _startIndex; i <= _endIndex; i++) {
            _userAddr = userList[i];
            User storage user = users[_userAddr];
            _amount = user.investAmount;
            if(user.investStatus == uint8(2)) {
                user.investStatus = uint8(1);
                user.joinRound = totalNumberOfCf;
                emit Invest(_userAddr,_amount);
                ISchedulePool(schedulePool).withdraw(schedulePoolId, _userAddr, _amount);
            }
        }

    }

    function batchJoinCrowdfundFromSchedule() internal returns(bool) {
        if(isNeedBatch) {
            CrowdfundInfo storage curCrowdfund = allCrowdfunds_[curRestartTimes][curRoundNum];
            uint256 _startIndex = schedulePoolInfo.startIndex;
            uint256 _endIndex = schedulePoolInfo.endIndex;

            if(_endIndex.sub(_startIndex) > 49) {
                _endIndex = _startIndex.add(49);
            }

            uint256 accSumAmount = 0;
            uint256 i;
            for(i= _startIndex; i<=_endIndex; i++) {
                User memory scheduleUser = users[userList[i]];
                //userIndex[deleteUser] == 0 ,userIndex[investUser] == index
                if (userIndex[userList[i]] == i && scheduleUser.investStatus == uint8(2)){
                    accSumAmount = accSumAmount.add(scheduleUser.investAmount);
                    // reach max amount limit this round
                    if(curCrowdfund.curTotalAmount.add(accSumAmount) >= maxLimitPerRounds[curRoundNum]) {
                        //close batch switch
                        isNeedBatch = false;

                        break;
                    }
                }
            }

            if(i > _endIndex){
                i = _endIndex;
            }

            //update crowdfund info
            if(curCrowdfund.endIndexOfStage < i) {
                curCrowdfund.endIndexOfStage = i;
            }
            curCrowdfund.curTotalAmount = curCrowdfund.curTotalAmount.add(accSumAmount);
            isCompleted();

            //update schedulePool info
            schedulePoolInfo.startIndex = i + 1;
            if(schedulePoolInfo.endIndex < schedulePoolInfo.startIndex) {
                schedulePoolInfo.endIndex = schedulePoolInfo.startIndex;
            }

            schedulePoolInfo.curTotalAmount = schedulePoolInfo.curTotalAmount.sub(accSumAmount);

            _batchJoinCfFromSchedule(_startIndex,i);

            return true;
        }
        return false;
    }

    function correctSchedulePoolInfo() public returns(bool){
        uint256  virtualTokenSupply = ISchedulePool(schedulePool).getVirtualTokenSupply(schedulePoolId);
        if(schedulePoolInfo.curTotalAmount != virtualTokenSupply) {
            schedulePoolInfo.curTotalAmount = virtualTokenSupply;
            return true;
        }
        return false;
    }

    //if his crowdfund reached max corwdfund limit,emit CrowdfundCompleted event
    function isCompleted() internal {
        CrowdfundInfo storage curCrowdfund = allCrowdfunds_[curRestartTimes][curRoundNum];
        if(curCrowdfund.curTotalAmount >= maxLimitPerRounds[curRoundNum]) {
            curCrowdfund.status = Status.Completed;
            if(curRoundNum == 1) {
                allTotalAmount[curRoundNum] = curCrowdfund.curTotalAmount;
            }else {
                allTotalAmount[curRoundNum] = allTotalAmount[curRoundNum.sub(1)].add(curCrowdfund.curTotalAmount);
            }
        }
    }

    /**
     * @dev refund tokens from Crowdfund contract
     * @return true when success
    */
    function refund() public onlyJoined returns(bool) {
        User storage crowdfundUser = users[_msgSender()];
        uint256 _investAmount = crowdfundUser.investAmount;
        require(crowdfundUser.investStatus == uint8(1),'Refund:user should be crowdfund status');
        require(_investAmount != 0,'Refund:the amount of user must be GT 0');

        (bool _can,uint256 _lastFailRoundNum,) = _canRefund(_msgSender());
        require(_can ,"can not refund");
        require(_lastFailRoundNum > 0,"Refund:user must be in one of lastFailRestartTimes");
        //refund invest amount
        uint256 _refundAmount = getRefundAmount(_msgSender());

        //clear user data
        clearUserData(_msgSender());

        totalWithdraw = totalWithdraw.add(_refundAmount);
        //refund
        safeTokenTransfer(_msgSender(),_refundAmount);
        emit Refund(_msgSender(),_refundAmount);

        //transfer bonus every day
        transferBonus();

        return true;
    }

    ///clear user data
    function clearUserData(address _userAddr) internal returns(bool) {
        User storage user = users[_userAddr];
        user.investAmount = 0;
        user.investStatus = uint8(0);
        user.joinRound = 0;
        userIndex[_msgSender()] = 0;

        return true;
    }

    /**
     * @dev priority to join schedule pool,user must on current restart time
     * and this restart time already failed at current round;
     * @return true when success
    */
    function priorityJoinSchedule() public onlyJoined returns(bool) {
        require(!isContinued,'cannot refund on normal status!');
        //User storage user = users[_msgSender()];
        User storage user = users[_msgSender()];
        //console.log("_msgSender():",_msgSender());
        //console.log("user.investStatus-0:",user.investStatus);

        uint256 _investAmount = user.investAmount;
        require(user.investStatus == uint8(1),'Refund:user should be crowdfund status');
        require(_investAmount != 0,'Refund:the amount of user must be GT 0');

        (bool _can,uint256 _lastFailRoundNum,uint256 _lastFailRestartTime) = _canRefund(_msgSender());
        require(_can ,"can not refund");
        require(_lastFailRoundNum > 0,"Refund:user must at one of lastFailRestartTimes");
        //additional check with refund action
        require(_lastFailRestartTime == curRestartTimes,"user must be in current restart times");
        //refund invest amount
        uint256 _refundAmount = getRefundAmount(_msgSender());

        // create new user
        uint256 lastIndex = _createNewUser(_msgSender(),uint256(0));
        user.investStatus = uint8(2);
        user.joinRound = 0;
        user.investAmount = _refundAmount;
        user.reinvest = user.reinvest.add(1);

        //start schedule pool mint
        _joinScheduleMint(schedulePoolId, _msgSender(), _refundAmount);

        //update schedulePool info
        updateSchedulePoolInfo(lastIndex,_refundAmount);

        //transfer bonus every day
        transferBonus();

        return true;
    }

    function canPriorityJoinSchedule(address _userAddr) public view returns(bool) {
        User memory user = users[_userAddr];
        (bool _can,uint256 _lastFailRoundNum,uint256 _lastFailRestartTime) = _canRefund(_userAddr);
        if(user.investStatus == uint8(1) &&
            user.investAmount != 0 &&
            _can &&
            _lastFailRoundNum > 0 &&
            _lastFailRestartTime == curRestartTimes
        ) {
            return true;
        }

        return false;
    }

    function _canRefund(address _userAddr) internal view
        returns(
        bool _can,
        uint256 _lastFailRoundNum,
        uint256 _lastFailRestartTime
    ) {
        User memory user = users[_userAddr];
        _lastFailRestartTime = roundRecords[user.joinRound].curRestartTimes_;
        //user in which round in _last Fail Restart Time
        uint256 _atRoundsNum = roundRecords[user.joinRound].curRoundNum_;
        //_lastFailRoundNum todo tobe sure
        _lastFailRoundNum = lastFailRestartTimesFailedAt[_lastFailRestartTime];

        if (_lastFailRoundNum > 0) {//has failed roundNum at that _lastFailRestartTime
            uint256 _gap = _lastFailRoundNum.sub(_atRoundsNum);
            _can = _gap <=2;
            return (_can,_lastFailRoundNum,_lastFailRestartTime);
        }
        //cannot refund when it still continue at that _lastFailRestartTime
        return (false,_lastFailRoundNum,_lastFailRestartTime);

    }

    //success status, msgSender can withdraw
    function withdraw() public onlyJoined returns(bool) {
        User storage crowdfundUser = users[_msgSender()];
        uint256 _investAmount = crowdfundUser.investAmount;
        require(crowdfundUser.investStatus == uint8(1),'user should be crowdfund status');
        require(_investAmount != 0,'the amount of user must be GT 0');

        bool _can = _canWithdraw(_msgSender());
        require(_can,"can not withdraw");

        uint256 _joinedRestartTime = roundRecords[crowdfundUser.joinRound].curRestartTimes_;
        //user in which round in _last Fail Restart Time
        uint256 _joinedRoundNum = roundRecords[crowdfundUser.joinRound].curRoundNum_;
        //uint256 _lastFailRoundNum = lastFailRestartTimesFailedAt[_joinedRestartTime];
        CrowdfundInfo storage joinedCrowdfund =  allCrowdfunds_[_joinedRestartTime][_joinedRoundNum];
        joinedCrowdfund.withdrawTotalAmount = joinedCrowdfund.withdrawTotalAmount.add(_investAmount);

        uint256 _income = _investAmount.mul(staticRate.add(100)).div(100);

        //clear user data
        clearUserData(_msgSender());
        crowdfundUser.income = crowdfundUser.income.add(_income);
        totalWithdraw = totalWithdraw.add(_income);

        // withdraw
        safeTokenTransfer(_msgSender(),_income);
        emit Withdraw(_msgSender(),_income);

        //transfer bonus every day
        transferBonus();

        return true;

    }

    //success status, msgSender can reinvestJoinSchedule
    function reinvest() public onlyJoined returns(bool) {
        User storage user = users[_msgSender()];
        uint256 _investAmount = user.investAmount;
        require(user.investStatus == uint8(1),'user should be crowdfund status');
        require(_investAmount != 0,'the amount of user must be GT 0');

        bool _can = _canWithdraw(_msgSender());
        require(_can,"reinvest: can not withdraw");

        uint256 _joinedRestartTime = roundRecords[user.joinRound].curRestartTimes_;
        //user in which round in _last Fail Restart Time
        uint256 _joinedRoundNum = roundRecords[user.joinRound].curRoundNum_;
        //uint256 _lastFailRoundNum = lastFailRestartTimesFailedAt[_joinedRestartTime];
        CrowdfundInfo storage joinedCrowdfund =  allCrowdfunds_[_joinedRestartTime][_joinedRoundNum];
        joinedCrowdfund.withdrawTotalAmount = joinedCrowdfund.withdrawTotalAmount.add(_investAmount);

        uint256 _income = _investAmount.mul(staticRate.add(100)).div(100);
        totalWithdraw = totalWithdraw.add(_investAmount);

        //transfer income
        safeTokenTransfer(_msgSender(), _income);

        //first clear user data
        clearUserData(_msgSender());

        //update user data
        user.income = user.income.add(_income);
        user.reinvest = user.reinvest.add(1);

        //then reinvest
        invest(_investAmount);

        return true;
    }

    function _canWithdraw(address _userAddr) internal view returns(bool _can) {
        User memory user = users[_userAddr];
        uint256 _lastFailRestartTime = roundRecords[user.joinRound].curRestartTimes_;
        //user in which round in _last Fail Restart Time
        uint256 _atRoundsNum = roundRecords[user.joinRound].curRoundNum_;

        uint256 _lastFailRoundNum = lastFailRestartTimesFailedAt[_lastFailRestartTime];

        uint256 _gap;
        //joinedCrowdfund.status == Status.Failed
        if (_lastFailRoundNum > 0) {//has failed roundNum at that _lastFailRestartTime
            _gap = _lastFailRoundNum.sub(_atRoundsNum);
            _can = _gap >=3;

            return _can;
        }else {//it still continue at that _lastFailRestartTime(_lastFailRestartTime == curRestartTimes)
            CrowdfundInfo memory crowdfund =  allCrowdfunds_[curRestartTimes][curRoundNum];
            if(crowdfund.status == Status.Open) {
                _gap = curRoundNum.sub(_atRoundsNum);
                _can = _gap >=3;

                return _can;
            }else if(crowdfund.status == Status.Completed){
                _gap = curRoundNum.sub(_atRoundsNum);
                _can = _gap >=2;

                return _can;
            }
        }
        //cannot refund when it still continue at that _lastFailRestartTime
        return false;

    }

    /**
     * @dev cancel from schedule pool,must joined user can call;
     * @return true when success
    */
    function cancelSchedule() public onlyJoined returns(bool) {
        require(isEmergencyStatus,'only cancel on emergency status');
        User storage scheduleUser = users[_msgSender()];
        uint256 _amount = scheduleUser.investAmount;
        uint256 _userIndex = userIndex[_msgSender()];
        require(_amount > 0,'the schedule amount of user must be GT 0!');
        require(scheduleUser.investStatus == uint8(2),'user should be in schedule status!');

        //clear schedulUser data
        clearUserData(_msgSender());
        //update new user status to schedule
        schedulePoolInfo.curTotalAmount = schedulePoolInfo.curTotalAmount.sub(_amount);
        //update schedulePool info
        //schedulePoolInfo.startIndex.add(1) <= schedulePoolInfo.endIndex
        if(schedulePoolInfo.startIndex == _userIndex) {
            schedulePoolInfo.startIndex = schedulePoolInfo.startIndex.add(1);
        }
        //schedulePoolInfo.endIndex.sub(1) >= schedulePoolInfo.startIndex
        if(schedulePoolInfo.endIndex == _userIndex) {
            schedulePoolInfo.endIndex = schedulePoolInfo.endIndex.sub(1);
        }

        //totalRevenue = totalRevenue.sub(_amount);
        capitalPool = capitalPool.sub(_amount);

        //quit schedule pool
        ISchedulePool(schedulePool).withdraw(schedulePoolId, _msgSender(), _amount);
        //withdraw invest amount of user
        safeTokenTransfer(_msgSender(),_amount);

        return true;
    }

    // Safe Token transfer function, just in case if rounding error causes pool to not have enough SUSHIs.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 bal = token.balanceOf(address(this));
        if (_amount > bal) {
            token.safeTransfer(_to, bal);
        } else {
            token.safeTransfer(_to, _amount);

        }
    }

    function transferBonus() public returns(bool) {
        if(isAllowBonus && dividendPool != 0 && lastBonusTime.add(ONE_DAY) < now) {
            uint256 _bonusAmount = dividendPool.mul(distributeRate).div(100);
            dividendPool = dividendPool.sub(_bonusAmount);
            bonusPool = bonusPool.add(_bonusAmount);
            lastBonusTime = now;
            //transfer bonus
            //Methods01 Crowdfund transfer directly
            safeTokenTransfer(pledgeDividendPool,_bonusAmount);
//            //Methods02 Crowdfund approve + transferFrom by IPledgeDividendPool
//            token.safeApprove(pledgeDividendPool,_bonusAmount);
            //update pledgeDividendPool status
            IPledgeDividendPool(pledgeDividendPool).updatePool(pledgeDividendPoolId,_bonusAmount);

            return true;
        }
        return false;
    }

    function setMainSwitch(bool _isAllowBonus,bool _isContinued,uint256 _restartWaitTime) public onlyManager returns(bool) {
        isAllowBonus = _isAllowBonus;
        isContinued = _isContinued;
        restartWaitTime = _restartWaitTime;
        return true;
    }

    //return the durition of future round
    function setFutureDurition(uint256 _duriDays) public onlyManager returns(bool) {
        require(_duriDays != 0);
        futureDurition = _duriDays;
        return true;
    }

    function setMaxLimitPerRound(uint256 _start,uint256 _end,uint256 _newFirstRoundMaxLimit) public onlyManager returns(bool) {
        require(_start > 0,'Need GT 0');
        if(_start == 1) {
            require(!isContinued,'Need on restart and wait time');
            maxLimitPerRounds[1] = _newFirstRoundMaxLimit;
            for (uint256 i = 2;i <= 100;i++) {
                maxLimitPerRounds[i] = maxLimitPerRounds[i - 1].mul(115).div(100);
            }
        } else {
            require(_start >= 2 && _end.sub(_start) <= 100,'please input right index');
            for (uint256 i = _start; i <= _end; i++) {
                maxLimitPerRounds[i] = maxLimitPerRounds[i - 1].mul(115).div(100);
            }
        }

        return true;
    }

    //set the status of isNeedBatch , only call by manager
    function setBatchFlag(bool _flag) public onlyManager returns(bool) {
        isNeedBatch = _flag;
        return true;
    }

    //set the status of schedulePoolId and pledgeDividendPoolId, only call by manager
    function setPoolIds(uint256 _schedulePoolId, uint256 _pledgePoolId) external onlyManager returns(bool) {
        schedulePoolId = _schedulePoolId;
        pledgeDividendPoolId = _pledgePoolId;
        return true;
    }

    function setPoolsAddresses(address _schedulePool,address _pledgeDividendPool) public onlyManager{
        pledgeDividendPool = _pledgeDividendPool;
        schedulePool = _schedulePool;
    }

    //set the status of minAmount and maxAmount, only call by manager
    function setLimitsOfInvest(uint256 _minAmount,uint256 _maxAmount) public onlyManager returns(bool) {
        minAmount = _minAmount;
        maxAmount = _maxAmount;
        return true;
    }
    //set the status of restartWaitTime , only call by manager

    function setLossRateLimit(uint256 _rate) public onlyManager returns(bool) {
        lossRateLimit = _rate;
        return true;
    }

    function getDurition(uint256 _roundNum) public view returns(uint256) {
        if (futureDurition == 0 || futureDurition >= 10000) {
            if(_roundNum <= 20){
                return 1;
            }else if(_roundNum <= 30) {
                return 2;
            }else if(_roundNum <= 40) {
                return 3;
            }else {
                return 4;
            }
        } else {
            return futureDurition;
        }

    }

    function getRefundAmount(address _userAddr) public view returns(uint256) {
        User memory crowdfundUser = users[_userAddr];
        uint256 _investAmount = crowdfundUser.investAmount;
        (bool _can,uint256 _lastFailRoundNum,) = _canRefund(_userAddr);

        if(_can && (_lastFailRoundNum > 0 && _lastFailRoundNum <= 3)) {
            return _investAmount;
        }

        if(_can && crowdfundUser.investStatus == uint8(1) && _investAmount != 0) {
            uint256 _joinedRestartTime = roundRecords[crowdfundUser.joinRound].curRestartTimes_;

            //refund invest amount // differ restartTime has differ refundRate
            uint256 denominator = 1e12;
            uint256 refundRate = denominator.sub(lossRateOfFailRestartTimes[_joinedRestartTime]);//per 1e12

            uint256 _refundAmount = _investAmount.mul(refundRate).div(1e12);
            return _refundAmount;
        }

        return 0;
    }

    function getWithdrawAmount(address _userAddr) public view returns(uint256) {
        User memory crowdfundUser = users[_userAddr];
        uint256 _investAmount = crowdfundUser.investAmount;
        bool _can = _canWithdraw(_userAddr);

        if(crowdfundUser.investStatus == uint8(1) &&
            userIndex[_userAddr] != 0 &&
            _investAmount != 0 &&
            _can
        ){

            uint256 _income = _investAmount.mul(staticRate.add(100)).div(100);

            return _income;
        }

        return 0;
    }

    //set emergency status
    function setEmergencyStatus(bool _flag,uint256 _emergencyRate) public onlyManager returns(bool) {
        isEmergencyStatus = _flag;
        emergencyRate = _emergencyRate;
        return true;
    }
    //Emergency withdrawal，only open by manager
    function EmergencyWithdraw() public onlyJoined returns(bool){
        require(isEmergencyStatus,'only open on emergency status');
        User storage crowdfundUser = users[_msgSender()];
        uint256 _investAmount = crowdfundUser.investAmount;

        //clear user data
        clearUserData(_msgSender());

        uint256 withdrawAmount = _investAmount.mul(emergencyRate).div(100);

        totalWithdraw = totalWithdraw.add(withdrawAmount);
        // withdraw
        safeTokenTransfer(_msgSender(),withdrawAmount);

        return true;

    }

}
