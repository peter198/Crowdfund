
// Dependency file: @openzeppelin/contracts/GSN/Context.sol

// SPDX-License-Identifier: MIT
//import "hardhat/console.sol";
import "./Crowdfund.sol";
import "./MintToken.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IBMintToken.sol";

//@dev Crowdfund Factory contract
pragma solidity ^0.6.12;

contract CrowdfundFactory is Ownable {
    address[] public allCrowdfunds;
    address public schedulePool;
    address public pledgeDividendPool;

    mapping(address => address) public getCrowdfundInfo;
    mapping(address => address[]) public getCrowdfundsOfUser;

    mapping(address => bool) public isManagers;
    //mapping(address =>mapping(address => bool)) isContractManager;
    modifier onlyManagers() {
        require (isManagers[_msgSender()],'CrowdfundFactory:only managers can call');

        _;
    }

    event CrowdfundCreated(address indexed Crowdfund, address indexed token, uint index);

    constructor(address _schedulePool,address _pledgeDividendPool)  public {
        pledgeDividendPool = _pledgeDividendPool;
        schedulePool = _schedulePool;
        isManagers[_msgSender()] = true;
    }

  function createNewCrowdfund(
      string memory _name,
      IERC20 _token,
      uint256 _firstRoundMaxLimit,
      uint256 _minAmount,
      uint256 _maxAmount,
      IERC20 _equityToken
  ) public onlyManagers returns(bool) {

      // 1 create new Crowdfund
      Crowdfund newCrowdfund = new Crowdfund(
          _name,
          _token,
          schedulePool,
          pledgeDividendPool,
          _msgSender(),
          _firstRoundMaxLimit,
          _minAmount,
          _maxAmount,
          _equityToken

        );
      allCrowdfunds.push(address(newCrowdfund));
      emit CrowdfundCreated(address(newCrowdfund),address(_token),allCrowdfunds.length - 1);

      getCrowdfundInfo[address(newCrowdfund)] = address(_token);
      getCrowdfundsOfUser[_msgSender()].push(address(newCrowdfund));

      // 2 create new schedule Pool which accept newCrowdfund to mint
      ISchedulePool(schedulePool).add(address(newCrowdfund),IBMintToken(address(_equityToken)), true);
      uint256 _schedulePoolLen = ISchedulePool(schedulePool).poolLength();//index = len - 1
      //already setCrowdFund dones in add function
      //ISchedulePool(schedulePool).setCrowdFund(address(newCrowdfund),true);

      // 3 create new PledgeDividend Pool
      IPledgeDividendPool(pledgeDividendPool).add(address(newCrowdfund),_token,_equityToken);
      uint256 _pledgeDividendPoolLen = IPledgeDividendPool(pledgeDividendPool).poolLength();

      //4 set schedulePoolId and pledgeDividendPoolId
      require(_schedulePoolLen > 0 && _pledgeDividendPoolLen > 0,'need create pools first');
      bool _bo = newCrowdfund.setPoolIds(_schedulePoolLen - 1,_pledgeDividendPoolLen -1);

      return _bo;
  }

    function setPoolsAddresses(address _schedulePool,address _pledgeDividendPool) public onlyOwner{
        pledgeDividendPool = _pledgeDividendPool;
        schedulePool = _schedulePool;
    }


   // set manager address accepted by CrowdfundFactory
    function setManager(address _manager,bool _bo) public onlyOwner {
        isManagers[_manager] = _bo;
    }

    function getDeployedContracts() public view returns (address[] memory) {
        return allCrowdfunds;
    }

    function allCrowdfundsLength() public view returns (uint256) {
        return allCrowdfunds.length;
    }

    ///get the length of deployed crowdfunds contracts of user
    function allCFsLengthOfUser(address _userAddr) external view returns (uint256) {
        return getCrowdfundsOfUser[_userAddr].length;
    }


}


