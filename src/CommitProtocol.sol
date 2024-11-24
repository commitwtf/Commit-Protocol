// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title CommitProtocol — an onchain accountability protocol
/// @notice Enables users to create and participate in commitment-based challenges
/// @dev Implements stake management, fee distribution, and emergency controls
contract CommitProtocol is UUPSUpgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Represents a single commitment with its rules and state
    /// @dev Uses EnumerableSet for participant management and mapping for success tracking
    struct Commitment {
        uint id;                    // Unique identifier
        address creator;            // Address that created the commitment
        address tokenAddress;       // Token used for staking
        uint stakeAmount;           // Amount each participant must stake
        uint creatorFee;            // Optional fee in ERC20 token
        string description;         // Description of the commitment
        uint joinDeadline;          // Deadline to join
        uint fulfillmentDeadline;   // Deadline to fulfill commitment
        uint winnerClaim;           // Amount each winner can claim
        uint creatorClaim;         // Total amount creator can claim
        uint creatorClaimed;       // Amount creator has already claimed
        mapping(address => bool) participantClaimed;
        EnumerableSet.AddressSet participants;
        EnumerableSet.AddressSet winners;
        CommitmentStatus status;
    }

    enum CommitmentStatus { Active, Resolved, Cancelled, EmergencyCancelled }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Protocol fees
    uint public constant PROTOCOL_JOIN_FEE = 0.0002 ether;     // Fixed ETH fee for joining
    uint public constant PROTOCOL_CREATE_FEE = 0.001 ether;    // Fixed ETH fee for creating
    uint public constant PROTOCOL_SHARE = 100;                 // 1% of stakes and creator fees
    
    // Other constants
    uint public constant BASIS_POINTS = 10000;                 // For percentage calculations
    uint public constant MAX_DESCRIPTION_LENGTH = 1000;        // Characters
    uint public constant MAX_DEADLINE_DURATION = 365 days;     // Max time window

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint public nextCommitmentId;
    address public protocolFeeAddress;
    mapping(uint => Commitment) private commitments;
    mapping(address => uint) public protocolFees;
    EnumerableSet.AddressSet private allowedTokens;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // Commitment lifecycle events
    event TokenAllowanceUpdated(address indexed token, bool allowed);
    event CommitmentCreated(
        uint indexed id,
        address indexed creator,
        address tokenAddress,
        uint stakeAmount,
        uint creatorFee,
        string description
    );
    event CommitmentJoined(uint indexed id, address indexed participant);
    event CommitmentResolved(uint indexed id, address[] winners);
    event CommitmentCancelled(uint indexed id, address indexed cancelledBy);
    event CommitmentEmergencyCancelled(uint indexed id);

    // Claim events
    event RewardsClaimed(uint indexed id, address indexed participant, address indexed token, uint amount);
    event CreatorClaimed(uint indexed id, address indexed creator, address indexed token, uint amount);
    event WinnerClaimed(uint indexed id, address indexed winner, address indexed token, uint amount);
    event EmergencyStakesReturned(uint indexed id, uint participantCount, address initiator);

    // Fee events
    event ProtocolFeePaid(uint indexed id, address indexed participant, address indexed token, uint amount);
    event CreatorFeePaid(uint indexed id, address indexed participant, address indexed token, uint amount);
    event FeesClaimed(address indexed recipient, address indexed token, uint amount);

    // Admin events
    event TokenListUpdated(address indexed token, bool allowed);
    event ProtocolFeeAddressUpdated(address oldAddress, address newAddress);
    event EmergencyWithdrawal(address indexed token, uint amount);
    event ContractPaused();
    event ContractUnpaused();

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // _disableInitializers();
    }

    /// @notice Initializes the contract with the protocol fee address
    /// @param _protocolFeeAddress The address where protocol fees are sent
    function initialize(address _protocolFeeAddress) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        require(_protocolFeeAddress != address(0), "Invalid protocol fee address");
        protocolFeeAddress = _protocolFeeAddress;
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a commitment with specified parameters and stake requirements
    /// @param _tokenAddress The address of the ERC20 token used for staking
    /// @param _stakeAmount The amount each participant must stake
    /// @param _creatorFee The fee required to join the commitment (optionally set by creator)
    /// @param _description A brief description of the commitment
    /// @param _joinDeadline The deadline for participants to join
    /// @param _fulfillmentDeadline The deadline for fulfilling the commitment
    /// @dev Creator becomes first participant by staking tokens + paying creation fee in ETH
    function createCommitment(
        address _tokenAddress,
        uint _stakeAmount,
        uint _creatorFee,
        string calldata _description,
        uint _joinDeadline,
        uint _fulfillmentDeadline
    ) external payable nonReentrant whenNotPaused returns (uint) {
        require(msg.value == PROTOCOL_CREATE_FEE, "Invalid creation fee amount");
        require(allowedTokens.contains(_tokenAddress), "Token not allowed for commitments");
        require(bytes(_description).length <= MAX_DESCRIPTION_LENGTH, "Description too long");
        require(_joinDeadline > block.timestamp, "Join Deadline Too Early");
        require(
            _fulfillmentDeadline > _joinDeadline &&
            _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION,
            "Fulfillment Deadline Too Early or Late"
        );
        require(_stakeAmount > 0, "Stake Must Be Non-Zero");

        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        // Transfer stake amount for creator
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _stakeAmount);

        uint commitmentId = nextCommitmentId++;

        Commitment storage commitment = commitments[commitmentId];

        // Initialize commitment details
        commitment.id = commitmentId;
        commitment.creator = msg.sender;
        commitment.tokenAddress = _tokenAddress;
        commitment.stakeAmount = _stakeAmount;
        commitment.creatorFee = _creatorFee;
        commitment.description = _description;
        commitment.joinDeadline = _joinDeadline;
        commitment.fulfillmentDeadline = _fulfillmentDeadline;
        commitment.status = CommitmentStatus.Active;

        // Make creator the first participant with their stake amount
        commitment.participants.add(msg.sender);

        emit CommitmentCreated(
            commitmentId,
            msg.sender,
            _tokenAddress,
            _stakeAmount,
            _creatorFee,
            _description
        );

        emit CommitmentJoined(commitmentId, msg.sender);

        return commitmentId;
    }

    /// @notice Allows joining an active commitment
    /// @param _id The ID of the commitment to join
    function joinCommitment(uint _id) external payable nonReentrant whenNotPaused {
        require(_id < nextCommitmentId, "Commitment does not exist");
        require(msg.value == PROTOCOL_JOIN_FEE, "Invalid join fee amount");

        Commitment storage commitment = commitments[_id];
        require(commitment.status == CommitmentStatus.Active, "Commitment not active");
        require(block.timestamp < commitment.joinDeadline, "Commitment join deadline has passed");
        require(!commitment.participants.contains(msg.sender), "Already joined commitment");

        protocolFees[address(0)] += PROTOCOL_JOIN_FEE;

        uint totalAmount = commitment.stakeAmount;
        
        // Handle creator fee if set
        uint creatorFee = commitment.creatorFee;
        if (creatorFee > 0) {
            totalAmount += creatorFee;

            uint protocolEarnings = creatorFee * PROTOCOL_SHARE / BASIS_POINTS;

            // Update accumulated token fees
            protocolFees[commitment.tokenAddress] += protocolEarnings;
            commitment.creatorClaim += creatorFee - protocolEarnings;
        }

        // Transfer total amount in one transaction
        IERC20(commitment.tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            totalAmount
        );

        // Record participant's join status
        commitment.participants.add(msg.sender);

        emit CommitmentJoined(_id, msg.sender);
    }

    /// @notice Resolves commitment and distributes rewards to winners
    /// @param _id The ID of the commitment to resolve
    /// @param _winners The addresses of the participants who succeeded
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitment(uint _id, address[] memory _winners) public nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];
        require(msg.sender == commitment.creator, "Only creator can resolve");
        require(commitment.status == CommitmentStatus.Active, "Commitment not active");
        require(block.timestamp > commitment.fulfillmentDeadline, "Fulfillment period not ended");

        EnumerableSet.AddressSet storage participants = commitment.participants;
        EnumerableSet.AddressSet storage winners = commitment.winners;

        // Cache lengths for gas
        uint winnerCount = _winners.length;
        uint participantCount = participants.length();

        require(
            winnerCount > 0 &&
            winnerCount <= participantCount,
            "Invalid Number of Winners"
        );

        for (uint i = 0; i < winnerCount; i++) {
            address winner = _winners[i];
            require(participants.contains(winner), "Invalid winner address");
            require(winners.add(winner), "Duplicate winner");
        }

        // Process participants
        // Use local var to save gas so we dont have to read `commitment.failedCount` every time
        uint failedCount = participantCount - winnerCount;

        uint protocolStakeFee = commitment.stakeAmount * PROTOCOL_SHARE / BASIS_POINTS;

        // Protocol earns % of all commit stakes, won or lost
        protocolFees[commitment.tokenAddress] += protocolStakeFee * participantCount;

        // Distribute stakes among winners, less protocol fees
        uint winnerStakeRefund = commitment.stakeAmount - protocolStakeFee;
        uint winnerStakeEarnings = (commitment.stakeAmount - protocolStakeFee) * failedCount / winnerCount;
        commitment.winnerClaim = winnerStakeRefund + winnerStakeEarnings;

        // Mark commitment as resolved
        commitment.status = CommitmentStatus.Resolved;

        emit CommitmentResolved(_id, _winners);
    }

    /// @notice Allows creator or owner to cancel a commitment before anyone else joins
    /// @param _id The ID of the commitment to cancel
    /// @dev This calls resolveCommitment internally to handle refunds properly
    /// @dev Requires exactly 1 participant (the creator) since creator auto-joins on creation
    function cancelCommitment(uint _id) external whenNotPaused {
        require(_id < nextCommitmentId, "Commitment does not exist");

        Commitment storage commitment = commitments[_id];

        require(
            msg.sender == commitment.creator ||
            msg.sender == owner(),
            "Only creator or owner can cancel"
        );
        require(
            commitment.status == CommitmentStatus.Active,
            "Commitment not active"
        );
        require(
            commitment.participants.length() == 1,  // Only creator is present
            "Cannot cancel after others have joined"
        );

        commitment.joinDeadline = 0;
        commitment.fulfillmentDeadline = 0;

        resolveCommitment(_id, commitment.participants.values());

        commitment.status = CommitmentStatus.Cancelled;

        emit CommitmentCancelled(_id, msg.sender);
    }

    /// @notice Claims participant stake after emergency cancellation
    /// @dev No protocol fees are assessed however join fees are non-refundable
    /// @param _id The commitment ID to claim stake from
    function claimCancelled(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        require(
            commitment.status == CommitmentStatus.EmergencyCancelled,
            "Commitment not emergency cancelled"
        );
        require(
            commitment.participants.contains(msg.sender),
            "Not a participant"
        );
        require(
            !commitment.participantClaimed[msg.sender],
            "Already claimed"
        );
        require(commitment.stakeAmount > 0, "No rewards to claim");

        uint amount = commitment.stakeAmount;

        // Mark as claimed before transfer to prevent reentrancy
        commitment.participantClaimed[msg.sender] = true;

        IERC20(commitment.tokenAddress).safeTransfer(msg.sender, amount);

        emit EmergencyStakesReturned(
            _id, 
            commitment.participants.length(),  // Total participant count for tracking
            msg.sender                        // Who initiated the return
        );
    }

    /// @notice Claims participant's rewards and stakes after commitment resolution
    /// @dev Winners can claim their original stake plus their share of rewards from failed stakes
    /// @dev Losers cannot claim anything as their stakes are distributed to winners
    /// @param _id The commitment ID to claim rewards from
    function claimRewards(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        require(
            commitment.status == CommitmentStatus.Resolved,
            "Commitment not resolved"
        );
        require(
            commitment.winners.contains(msg.sender),
            "Not a winner"
        );
        require(
            !commitment.participantClaimed[msg.sender],
            "Already claimed"
        );a

        uint amount = commitment.winnerClaim;
        require(amount > 0, "No rewards to claim");

        // Mark as claimed before transfer to prevent reentrancy
        commitment.participantClaimed[msg.sender] = true;

        IERC20(commitment.tokenAddress).safeTransfer(msg.sender, amount);

        emit RewardsClaimed(_id, msg.sender, commitment.tokenAddress, amount);
    }

    /// @notice Claims creator's rewards
    /// @dev Creator can claim while the commitment is in progress
    /// @param _id The commitment ID to claim creator fees from
    function claimCreator(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        require(commitment.creator == msg.sender, "Only creator can claim");
        uint amount = commitment.creatorClaim - commitment.creatorClaimed;
        require(amount > 0, "No creator fees to claim");

        // Update how much they have claimed to prevent reclaiming the same funds
        commitment.creatorClaimed += amount;

        IERC20(commitment.tokenAddress).safeTransfer(msg.sender, amount);

        emit CreatorClaimed(_id, msg.sender, commitment.tokenAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow a token for use in future commitments
    /// @param token The address of the token
    function addAllowedToken(address token) external onlyOwner {
        allowedTokens.add(token);

        emit TokenListUpdated(token, true);
    }

    /// @notice Prevent a token for use in future commitments
    /// @param token The address of the token
    function removeAllowedToken(address token) external onlyOwner {
        allowedTokens.remove(token);

        emit TokenListUpdated(token, false);
    }

    /// @notice Updates the protocol fee address
    /// @param _newAddress The new address for protocol fees
    function setProtocolFeeAddress(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Invalid protocol fee address");

        address oldAddress = protocolFeeAddress;
        protocolFeeAddress = _newAddress;

        emit ProtocolFeeAddressUpdated(oldAddress, _newAddress);
    }

    /// @notice Claims accumulated fees for a specific token. Used by protocol owner to withdraw their fees
    /// @param token The address of the token to claim fees for
    /// @dev Protocol owner claims via protocolFeeAddress
    /// @dev Protocol fees come from join fees (PROTOCOL_SHARE%) and stakes (PROTOCOL_SHARE%)
    /// @dev Creator fees come from creatorFee (optional commitment join fee) 
    function claimProtocolFees(address token) external onlyOwner nonReentrant {
        uint amount = protocolFees[token];

        require(amount > 0, "No fees to claim");

        // Clear balance before transfer to prevent reentrancy
        protocolFees[token] = 0;

        if (token == address(0)) {
            // Transfer creation fee in ETH
            (bool sent,) = protocolFeeAddress.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            // Transfer accumulated fees
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit FeesClaimed(msg.sender, token, amount);
    }

    function getProtocolFees(address token) external view returns (uint) {
        return protocolFees[token];
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdrawal of stuck tokens
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdrawToken(IERC20 token, uint amount) external onlyOwner {
        uint balance = token.balanceOf(address(this));
        require(
            amount > 0 &&
            amount <= balance,
            "Invalid withdrawal amount"
        );
        token.safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawal(address(token), amount);
    }

    /// @notice Emergency function to cancel a specific commitment
    /// @dev Owner can perform `emergencyWithdrawToken` for manual distribution
    /// @param _id The ID of the commitment to cancel
    function emergencyCancelCommitment(uint _id) external onlyOwner {
        Commitment storage commitment = commitments[_id];
        require(commitment.status == CommitmentStatus.Active, "Commitment not active");

        commitment.status = CommitmentStatus.EmergencyCancelled;

        emit CommitmentEmergencyCancelled(_id);
    }

    /// @notice Emergency function to pause any function that uses `whenNotPaused`
    function emergencyPauseAll() external onlyOwner {
        _pause();

        emit ContractPaused();
    }

    /// @notice Emergency function to unpause all functions blocked on `whenNotPaused`
    function emergencyUnpauseAll() external onlyOwner {
        _unpause();

        emit ContractUnpaused();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Retrieves detailed information about a commitment
    /// @param _id The commitment ID to query
    /// @return creator Address of commitment creator
    /// @return stakeAmount Required stake amount
    /// @return creatorFee Fee to join commitment
    /// @return participantCount Number of current participants
    /// @return description Description of the commitment
    /// @return status Current commitment status
    /// @return timeRemaining Time left to join (0 if ended)
    
    // Core info
    function getCommitmentDetails(uint _id) external view returns (
        address creator,
        uint stakeAmount,
        uint creatorFee,
        uint participantCount,
        string memory description,
        CommitmentStatus status,
        uint timeRemaining
    ) {
        Commitment storage c = commitments[_id];
        return (
            c.creator,
            c.stakeAmount,
            c.creatorFee,
            c.participants.length(),
            c.description,
            c.status,
            c.joinDeadline > block.timestamp ? c.joinDeadline - block.timestamp : 0
        );
    }

    function getCommitmentStatus(uint _id) external view returns (CommitmentStatus) {
        return commitments[_id].status;
    }

    // Parameters
    function getCommitmentCreator(uint _id) external view returns (address) {
        return commitments[_id].creator;
    }

    function getCommitmentTokenAddress(uint _id) external view returns (address) {
        return commitments[_id].tokenAddress;
    }

    function getCommitmentStakeAmount(uint _id) external view returns (uint) {
        return commitments[_id].stakeAmount;
    }

    function getCommitmentCreatorFee(uint _id) external view returns (uint) {
        return commitments[_id].creatorFee;
    }

    function getCommitmentDescription(uint _id) external view returns (string memory) {
        return commitments[_id].description;
    }

    function getCommitmentJoinDeadline(uint _id) external view returns (uint) {
        return commitments[_id].joinDeadline;
    }

    function getCommitmentFulfillmentDeadline(uint _id) external view returns (uint) {
        return commitments[_id].fulfillmentDeadline;
    }

    // Participant info
    function getCommitmentParticipants(uint _id) external view returns (address[] memory) {
        return commitments[_id].participants.values();
    }

    function getCommitmentParticipantAt(uint _id, uint _index) external view returns (address) {
        return commitments[_id].participants.at(_index);
    }

    function getNumCommitmentParticipants(uint _id) external view returns (uint) {
        return commitments[_id].participants.length();
    }

    // Winner info
    function getCommitmentWinners(uint _id) external view returns (address[] memory) {
        return commitments[_id].winners.values();
    }

    function getCommitmentWinnerAt(uint _id, uint _index) external view returns (address) {
        return commitments[_id].winners.at(_index);
    }

    function getNumCommitmentWinners(uint _id) external view returns (uint) {
        return commitments[_id].winners.length();
    }

    // Claim info
    function getCommitmentCreatorClaim(uint _id) external view returns (uint) {
        return commitments[_id].creatorClaim;
    }

    function getCommitmentWinnerClaim(uint _id) external view returns (uint) {
        return commitments[_id].winnerClaim;
    }

    function getCommitmentCreatorClaimed(uint _id) external view returns (uint) {
        return commitments[_id].creatorClaimed;
    }

    function hasCommitmentWinnerClaimed(uint _id, address _user) external view returns (bool) {
        return commitments[_id].participantClaimed[_user];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateAddress(address addr) internal pure {
        require(addr != address(0), "Invalid address");
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        require(newImplementation != address(0), "Invalid implementation address");
    }


    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        require(false, "Direct deposits not allowed");
    }
}
