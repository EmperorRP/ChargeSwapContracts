// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;
import "./Stations.sol";

interface IPUSHCommInterface {
    function sendNotification(address _channel, address _recipient, bytes calldata _identity) external;
}

/**
 * @title EV Battery Station
 */
contract batteryswap is Stations, ERC20 {
    
    address public EPNS_COMM_ADDRESS = 0xb3971BCef2D791bc4027BbfedFb47319A4AAaaAa;
    address public CONTRACT_ADDRESS = 0x53b5aEca5C21cbd3F54016C720C3805fbACd2bD6;

    constructor() ERC20("Push Token", "PUSH") {
        _mint(msg.sender, 1000 * 10 ** uint(decimals()));
    }


    using Counters for Counters.Counter;

    enum Status {
        Idle,
        InUse, 
        Reserved,
        Broken
    }

    struct Battery {
        uint id;
        uint256 batteryPercentage;
        uint256 lastBlocktimeQueried;
        Status status;
        uint256 currentStation;
        address currentUser;
        string metaAbi; 
        uint256 lastSwapTime;
    }

    Counters.Counter private _batteryIds;  
    mapping(uint256 => Battery) batteries;
    mapping(string => uint) public rfidToBattery;

    mapping(address => uint256) public userToLastScanned;
    
    uint blocksPerReduceCharge = 50;
    uint public ethPerCharge = 1 ether/ 100;
    uint blocksTillConfirmed = 340;

    function addBatteriesStation(uint256 _currentStation, string memory _metaAbi, string memory _rfid) public {
        uint256 newBatteryId = _batteryIds.current();
        Battery memory newBattery = Battery({
            id: newBatteryId,
            batteryPercentage: 100,
            lastBlocktimeQueried: block.timestamp,
            status: Status.Idle,
            currentStation: _currentStation,
            currentUser: address(0),
            metaAbi: _metaAbi,
            lastSwapTime: block.timestamp
        });
        batteries[newBatteryId] = newBattery;
        rfidToBattery[_rfid] = newBatteryId;
        _batteryIds.increment();
    }

    // function addNewBatteriesUser(address _user, string memory _metaAbi, string memory _rfid) public payable {
    //     require(msg.value >= (100 * ethPerCharge), "Not enough ETH sent to charge battery");
    //     uint256 newBatteryId = _batteryIds.current();
    //     Battery memory newBattery = Battery({
    //         id: newBatteryId,
    //         batteryPercentage: 100,
    //         lastBlocktimeQueried: block.timestamp,
    //         status: Status.InUse,
    //         currentStation: 0,
    //         currentUser: _user,
    //         metaAbi: _metaAbi
    //     });   
    //     // batteries[newBatteryId] = newBattery; // 
    //     rfidToBattery[_rfid] = newBatteryId;
    //     _batteryIds.increment();
    // }

    function getBatteriesByUser(address _user) public view returns (uint[] memory) {
        uint[] memory userBatteries = new uint[](_batteryIds.current()); // array size
        uint counter = 0;
        for (uint i = 0; i < _batteryIds.current(); i++) {
            if (batteries[i].currentUser == _user) {
                userBatteries[counter] = batteries[i].id;
                counter++;
            }
        }
        
        uint[] memory correctSizeArray = new uint[](counter);
        for (uint i = 0; i < counter; i++) {
            correctSizeArray[i] = userBatteries[i];
        }
        return correctSizeArray;
    }

    function getBatteriesByStation(uint _stationId) public view returns (uint[] memory) {
        uint[] memory stationBatteries = new uint[](_batteryIds.current());
        uint counter = 0;
        for (uint i = 0; i < _batteryIds.current(); i++) {
            if (batteries[i].currentStation == _stationId) {
                stationBatteries[counter] = batteries[i].id;
                counter++;
            }
        }

        uint[] memory correctSizeArray = new uint[](counter);
        for (uint i = 0; i < counter; i++) {
            correctSizeArray[i] = stationBatteries[i];
        }
        return correctSizeArray;
    }

    function getBatteryDrain(uint _batteryId) public view returns (uint256) {
        // Get the current state of the vehicle's battery
        Battery storage battery = batteries[_batteryId];
        // Get the time elapsed since the last swap
        uint256 elapsedTime = block.timestamp - battery.lastSwapTime;
        // Get the energy drain as a percentage
        uint256 drainPercent = elapsedTime / 10 minutes * 3; // losing 3% for every 10 minutes or could show in a smaller unit
        // Calculate the energy drained since last swap
        return drainPercent * battery.batteryPercentage / 100;
    }

    function getBatteryPercentage(uint _batteryId) public view returns (uint256) {        
        uint blocksSinceLastQuery = block.timestamp - batteries[_batteryId].lastBlocktimeQueried;
        if (batteries[_batteryId].batteryPercentage - (blocksSinceLastQuery / blocksPerReduceCharge) > 0) {
            return batteries[_batteryId].batteryPercentage - (blocksSinceLastQuery / blocksPerReduceCharge);
        }
        return 0;
    }

    function swapAllBatteries(uint _stationId) public payable {
        uint[] memory userBatteries = getBatteriesByUser(msg.sender);
        require(userBatteries.length > 0, "User has no batteries");

        uint[] memory batteriesForSwapping = getBatteriesByStation(_stationId);
        require(batteriesForSwapping.length >= userBatteries.length, "Not enough batteries available");

        uint totalcost = 0;
        for (uint i = 0; i < userBatteries.length; i++) {
            totalcost += (100 - getBatteryPercentage(userBatteries[i])) * ethPerCharge;
        }
        require(msg.value >= totalcost, "Not enough funds to swap batteries");

        for (uint i = 0; i < userBatteries.length; i++) {
            batteries[userBatteries[i]].status = Status.Idle;
            batteries[userBatteries[i]].currentStation = _stationId;
            batteries[userBatteries[i]].currentUser = address(0);
            batteries[userBatteries[i]].batteryPercentage = 100; // Assumption: battery at 100% at the station
        }

        for (uint i = 0; i < userBatteries.length; i++) {
            batteries[batteriesForSwapping[i]].status = Status.InUse;
            // batteries[batteriesForSwapping[i]].currentStation = 0;
            batteries[batteriesForSwapping[i]].currentUser = msg.sender;
        }

        // msg.sender.transfer(msg.value - totalcost);
        IPUSHCommInterface(EPNS_COMM_ADDRESS).sendNotification(
            CONTRACT_ADDRESS, // from channel
            msg.sender, // to recipient, put address(this) in case you want Broadcast or Subset. For Targetted put the address to which you want to send
            bytes(
                string(
                    // We are passing identity here: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/identity/payload-identity-implementations
                    abi.encodePacked(
                        "0", // this is notification identity: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/identity/payload-identity-implementations
                        "+", // segregator
                        "3", // this is payload type: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/payload (1, 3 or 4) = (Broadcast, targetted or subset)
                        "+", // segregator
                        "Success!!", // this is notificaiton title
                        "+", // segregator
                        "You can now safely eject the batteries"
                    )
                )
            )
        );
    }




}
