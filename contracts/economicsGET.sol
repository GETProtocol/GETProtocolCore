pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "./utils/Initializable.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IGETAccessControl.sol";
import "./interfaces/IEconomicsGET.sol";

import "./utils/SafeMathUpgradeable.sol";

/** GET Protocol CORE contract
- contract that defines for different ticketeers how much is paid in GET 'gas' per statechange type
- contract/proxy will act as a prepaid bank contract.
- contract will be called using a proxy (upgradable)
- relayers are ticketeers/integrators
- contract is still WIP
 */
contract economicsGET is Initializable {
    IGETAccessControl public GET_BOUNCER;
    IERC20 public FUELTOKEN;
    IEconomicsGET public ECONOMICS;

    using SafeMathUpgradeable for uint256;
    
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant GET_TEAM_MULTISIG = keccak256("GET_TEAM_MULTISIG");
    bytes32 public constant GET_GOVERNANCE = keccak256("GET_GOVERNANCE");

    address public treasuryAddress;
    address public burnAddress;
    address public emergencyAddress;

    /**
    struct defines how much GET is sent from relayer to economcs per type of contract interaction
    - treasuryFee amount of wei GET that is sent to primary
    [0 setAsideMint, 1 primarySaleMint, 2 secondarySale, 3 Scan, 4 Claim, 6 CreateEvent, 7 ModifyEvent]
    - burnFee amount of wei GET that is sent to burn adres
    [0 setAsideMint, 1 primarySaleMint, 2 secondarySale, 3 Scan, 4 Claim, 6 CreateEvent, 7 ModifyEvent]
    */
    struct EconomicsConfig {
        address relayerAddress; // address of the ticketeer/integrator
        uint256 timestampStarted; // blockheight of when the config was set
        uint256 timestampEnded; // is 0 if economics confis is still active
        uint256[] treasuryL;
        uint256[] burnL;
        bool isConfigured;
    }

    // mapping from relayer address to configs (that are active)
    mapping(address => EconomicsConfig) public allConfigs;

    // storage of fee old configs
    EconomicsConfig[] public oldConfigs;

    // mapping from relayer address to GET/Fuel balance (internal fuel balance)
    mapping(address => uint256) public relayerBalance;

    // TODO check if it defaults to false for unknwon addresses.
    mapping(address => bool) public relayerRegistry;
    
    event ticketeerCharged(
        address indexed ticketeerRelayer, 
        uint256 indexed chargedFee
    );

    event configChanged(
        address adminAddress,
        address relayerAddress,
        uint256 timestamp
    );

    event feeToTreasury(
        uint256 feeToTreasury,
        uint256 remainingBalance
    );

    event feeToBurn(
        uint256 feeToTreasury,
        uint256 remainingBalance
    );

    event relayerToppedUp(
        address relayerAddress,
        uint256 amountToppedUp,
        uint256 timeStamp
    );

    event allFuelPulled(
        address requestAddress,
        address receivedByAddress,
        uint256 amountPulled
    );

    /**
     * @dev Throws if called by any account other than the GET Protocol admin account.
     */
    modifier onlyAdmin() {
        require(
            GET_BOUNCER.hasRole(RELAYER_ROLE, msg.sender), "CALLER_NOT_ADMIN");
        _;
    }

    /**
     * @dev Throws if called by any account other than a GET Protocol governance address.
     */
    modifier onlyGovernance() {
        require(
            GET_BOUNCER.hasRole(GET_GOVERNANCE, msg.sender), "CALLER_NOT_GOVERNANCE");
        _;
    }

    /**
     * @dev Throws if called by a relayer/ticketeer that has not been registered.
     */
    modifier onlyKnownRelayer() {
        require(
            relayerRegistry[msg.sender] == true, "RELAYER_NOT_REGISTERED");
        _;
    }

    function initialize_economics(
        address address_bouncer,
        address fueltoken_address
        ) public initializer {
            GET_BOUNCER = IGETAccessControl(address_bouncer);
            treasuryAddress = 0x0000000000000000000000000000000000000000;
            burnAddress = 0x0000000000000000000000000000000000000000;
            FUELTOKEN = IERC20(fueltoken_address);

        }
    

    function editCoreAddresses(
        address newAddressBurn,
        address newAddressTreasury,
        address newFuelToken
    ) external onlyAdmin {
        burnAddress = newAddressBurn;
        treasuryAddress = newAddressTreasury;
        FUELTOKEN = IERC20(newFuelToken);
    }


    function setEconomicsConfig(
        address relayerAddress,
        EconomicsConfig memory EconomicsConfigNew
    ) public onlyAdmin {

        // check if relayer had a previously set economic config
        // if so, the config that is replaced needs to be stored
        // otherwise it will be lost and this will make tracking usage harder for those analysing
        if (allConfigs[relayerAddress].isConfigured == true) {  // if storage occupied
            // add the old econmic config to storage
            oldConfigs.push(allConfigs[relayerAddress]);
        }

        // store config in mapping
        allConfigs[relayerAddress] = EconomicsConfigNew;

        // set the blockheight of starting block
        allConfigs[relayerAddress].timestampStarted = block.timestamp;
        allConfigs[relayerAddress].isConfigured = true;

        emit configChanged(
            msg.sender,
            relayerAddress,
            block.timestamp
        );

    }

    function balanceOfRelayer(
        address relayerAddress
    ) public view returns (uint256 balanceRelayer) 
    {
        balanceRelayer = relayerBalance[relayerAddress];
    }

    function balancerOfCaller() public view
    returns (uint256 balanceCaller) 
        {
            balanceCaller = relayerBalance[msg.sender];
        }
    
    // TOD) check if this works / can work
    function checkIfRelayer(
        address relayerAddress
    ) public returns (bool isRelayer) 
    {
        isRelayer = relayerRegistry[relayerAddress];
    }
    

    /**
    @param amountTreasury TODO
    @param amountBurn TODO
    @param relayerA TODO
     */
    function transferFuelTo(
        uint256 amountTreasury,
        uint256 amountBurn,
        address relayerA
    ) public returns (bool) {

        uint256 _balance = relayerBalance[relayerA];
        
       
        require( // check if balance sufficient
            (amountTreasury + amountBurn) <= _balance,
        "chargePrimaryMint balance low"
        );

        if (amountTreasury > 0) {
            
            // deduct from balance
            relayerBalance[relayerA] =- amountTreasury;

            require( // transfer to treasury
            FUELTOKEN.transferFrom(
                address(this),
                treasuryAddress,
                amountTreasury), // TODO or return false?
                "chargePrimaryMint _feeT FAIL"
            );

            emit feeToTreasury(
                amountTreasury,
                relayerBalance[relayerA]
            );
        }

        if (amountBurn > 0) {

            // deduct from balance 
            relayerBalance[relayerA] =- amountBurn;

            require( // transfer to treasury
            FUELTOKEN.transferFrom(
                address(this),
                burnAddress,
                amountBurn),
                "chargePrimaryMint _feeB FAIL"
            );

            emit feeToBurn(
                amountBurn,
                relayerBalance[relayerA]
            );

        }

        // TODO ADD require statement / logic
        return true;
    }

    /**
    @param relayerAddress TODO
     */
    function chargePrimaryMint(
        address relayerAddress
        ) external returns (bool) 
        { // TODO check probably external
        
            // check if call is coming from protocol contract
            require(GET_BOUNCER.hasRole(RELAYER_ROLE, msg.sender), "chargePrimaryMint: !FACTORY");

            // how much GET needs to be sent to the treasury
            uint256 _feeT = allConfigs[relayerAddress].treasuryL[1];
            // how much GET needs to be sent to the burn
            uint256 _feeB = allConfigs[relayerAddress].burnL[1];

            bool _result = transferFuelTo(
                _feeT,
                _feeB,
                msg.sender
            );

            return _result;
    }

    function chargeSecondaryMint(
        address relayerAddress
        ) external returns (bool) 
        { // TODO check probably external
        
            // check if call is coming from protocol contract
            require(GET_BOUNCER.hasRole(RELAYER_ROLE, msg.sender), "chargeSecondaryMint: !FACTORY");

            // how much GET needs to be sent to the treasury
            uint256 _feeT = allConfigs[relayerAddress].treasuryL[1];
            // how much GET needs to be sent to the burn
            uint256 _feeB = allConfigs[relayerAddress].burnL[1];

            bool _result = transferFuelTo(
                _feeT,
                _feeB,
                msg.sender
            );

            return _result;
    }

    // ticketeer adds GET 
    /** function that tops up the relayer account
    @dev note that relayerAddress does not have to be msg.sender
    @dev so it is possible that an address tops up an account that is not itself
    @param relayerAddress TODO ADD SOME TEXT
    @param amountTopped TODO ADD SOME TEXT
    
     */
    function topUpGet(
        address relayerAddress,
        uint256 amountTopped
    ) public {

        // TODO maybe add check if msg.sender is real/known/registered

        // check if msg.sender has allowed contract to spend/send tokens
        require(
            FUELTOKEN.allowance(
                msg.sender, 
                address(this)) >= amountTopped,
            "topUpGet - ALLOWANCE FAILED - ALLOW CONTRACT FIRST!"
        );

        // tranfer tokens from msg.sender to contract
        require(
            FUELTOKEN.transferFrom(
                msg.sender, 
                address(this),
                amountTopped),
            "topUpGet - TRANSFERFROM STABLES FAILED"
        );

        // add the sent tokens to the balance
        relayerBalance[relayerAddress] += amountTopped;

        emit relayerToppedUp(
            relayerAddress,
            amountTopped,
            block.timestamp
        );
    }

    // emergency function pulling all GET to admin address
    function emergencyPullGET() 
        external onlyGovernance {

        // fetch GET balance of this contract
        uint256 _balanceAll = FUELTOKEN.balanceOf(address(this));

        require(
            address(emergencyAddress) != address(0),
            "emergencyAddress not set"
        );

        emit allFuelPulled(
            msg.sender,
            emergencyAddress,
            _balanceAll
        );

    }

    /** Returns the amount of GET on the balance of the 
    @param relayerAddress TODO 
     */
    function fuelBalanceOfRelayer(
        address relayerAddress
    ) public view returns (uint256 _balance) 
    {
        // TODO add check if relayer exists

        _balance = relayerBalance[relayerAddress];
    }

    // function feeForTypeOLD(
    //     address _relayerFromA,
    //     uint256 _statechangeType,
    //     uint256 _type        
    // ) public view returns (uint256 _feeU) 
    // {   
    //     require (
    //         _type == 0 || _type == 1,
    //         "feeForType - invalid _type value"
    //     );

    //     // TODO check if you can pick by this
    //     _feeU =  allConfigs[_relayerFromA].feeConfig[_type];
    // }

    // function feeForStatechangeListOLD(
    //     address _relayerFromA,
    //     uint256 _statechangeType
    // ) public view returns (uint256[2] memory)
    // {
    //     FeeStruct memory _feeS = allConfigs[_relayerFromA].feeConfig;
    //     return ([_feeS.treasuryFee, _feeS.burnFee]);
    // } 

        // uint256[] treasuryL;
        // uint256[] burnL;

    // /** Function returns the amount of GET fee that are charged
    // @param _relayerFromA TODO
    // @param _statechangeType TODO
    //  */
    // function feeForStatechangeList(
    //     address _relayerFromA,
    //     uint256 _statechangeType
    // ) public view returns (uint256[2] memory)
    // {
    //     FeeStruct memory _feeS = allConfigs[_relayerFromA].feeConfig;
    //     return ([_feeS.treasuryFee, _feeS.burnFee]);
    // } 

}


// library economicConfigrationLib {

//     /**
//     struct defines how much GET is sent from relayer to economcs per type of contract interaction
//     - treasuryFee amount of wei GET that is sent to primary
//     [0 setAsideMint, 1 primarySaleMint, 2 secondarySale, 3 Scan, 4 Claim, 6 CreateEvent, 7 ModifyEvent]
//     - burnFee amount of wei GET that is sent to burn adres
//     [0 setAsideMint, 1 primarySaleMint, 2 secondarySale, 3 Scan, 4 Claim, 6 CreateEvent, 7 ModifyEvent]
//     */
//     // struct FeeStruct {
//     //     uint256 treasuryFee;
//     //     uint256 burnFee;
//     // }

//     // struct EconomicsConfig {
//     //     address relayerAddress; // address of the ticketeer/integrator
//     //     uint timestampStarted; // blockheight of when the config was set
//     //     uint timestampEnded; // is 0 if economics confis is still active
//     //     mapping (uint256 => FeeStruct) feeConfig;
//     //     bool isConfigured;
//     // }



//     function setEconomicsConfig(
//         address relayerAddress,
//         EconomicsConfig memory EconomicsConfigNew
//     ) public onlyAdmin {

//         // check if relayer had a previously set economic config
//         // if so, the config that is replaced needs to be stored
//         // otherwise it will be lost and this will make tracking usage harder for those analysing
//         if (allConfigs[relayerAddress].isConfigured == true) {  // if storage occupied
//             // add the old econmic config to storage
//             oldConfigs.push(allConfigs[relayerAddress]);
//         }

//         // store config in mapping
//         allConfigs[relayerAddress] = EconomicsConfigNew;

//         // set the blockheight of starting block
//         allConfigs[relayerAddress].timestampStarted = block.timestamp;
//         allConfigs[relayerAddress].isConfigured = true;

//         emit configChanged(
//             msg.sender,
//             relayerAddress,
//             block.timestamp
//         );

//     }

// }