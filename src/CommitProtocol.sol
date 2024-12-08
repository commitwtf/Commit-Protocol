// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title CommitProtocol — an onchain accountability protocol
/// @notice Enables users to create and participate in commitment-based challenges
/// @dev Implements stake management, fee distribution, and emergency controls
contract CommitProtocol is
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct CommitmentInfo {
        uint id; // Unique identifier
        address creator; // Address that created the commitment
        address tokenAddress; // Token used for staking
        uint stakeAmount; // Amount each participant must stake
        uint creatorFee; // Optional fee in ERC20 token
        bytes description; // Description of the commitment
        uint joinDeadline; // Deadline to join
        uint fulfillmentDeadline; // Deadline to fulfill commitment
        CommitmentStatus status; // Current status of the commitment
    }

    struct Claims {
        uint winnerClaim; // Amount each winner can claim
        uint creatorClaim; // Total amount creator can claim
        uint creatorClaimed; // Amount creator has already claimed
    }

    struct CommitmentParticipants {
        EnumerableSet.AddressSet participants; // List of participants
        EnumerableSet.AddressSet winners; // List of winners
        mapping(address => bool) participantClaimed; // Tracking if a participant has claimed
    }

    /// @notice Represents a single commitment with its rules and state
    /// @dev Uses EnumerableSet for participant management and mapping for success tracking
    struct Commitment {
        CommitmentInfo info; // Basic commitment details
        Claims claims; // Creator and winner claim details
        CommitmentParticipants participants; // Participants and winners details
    }

    enum CommitmentStatus {
        Active,
        Resolved,
        Cancelled,
        EmergencyCancelled
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Protocol fees
    uint public constant PROTOCOL_JOIN_FEE = 0.0002 ether; // Fixed ETH fee for joining
    uint public constant PROTOCOL_CREATE_FEE = 0.001 ether; // Fixed ETH fee for creating
    uint public constant PROTOCOL_SHARE = 100; // 1% of stakes and creator fees

    // Other constants
    uint public constant BASIS_POINTS = 10000; // For percentage calculations
    uint public constant MAX_DESCRIPTION_LENGTH = 1000; // Characters
    uint public constant MAX_DEADLINE_DURATION = 365 days; // Max time window

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
        bytes description
    );
    event CommitmentJoined(uint indexed id, address indexed participant);
    event CommitmentResolved(uint indexed id, address[] winners);
    event CommitmentCancelled(uint indexed id, address indexed cancelledBy);
    event CommitmentEmergencyCancelled(uint indexed id);

    // Claim events
    event RewardsClaimed(
        uint indexed id,
        address indexed participant,
        address indexed token,
        uint amount
    );
    event CreatorClaimed(
        uint indexed id,
        address indexed creator,
        address indexed token,
        uint amount
    );
    event WinnerClaimed(
        uint indexed id,
        address indexed winner,
        address indexed token,
        uint amount
    );
    event EmergencyStakesReturned(
        uint indexed id,
        uint participantCount,
        address initiator
    );

    // Fee events
    event ProtocolFeePaid(
        uint indexed id,
        address indexed participant,
        address indexed token,
        uint amount
    );
    event CreatorFeePaid(
        uint indexed id,
        address indexed participant,
        address indexed token,
        uint amount
    );
    event FeesClaimed(
        address indexed recipient,
        address indexed token,
        uint amount
    );

    // Admin events
    event TokenListUpdated(address indexed token, bool allowed);
    event ProtocolFeeAddressUpdated(address oldAddress, address newAddress);
    event EmergencyWithdrawal(address indexed token, uint amount);
    event ContractPaused();
    event ContractUnpaused();

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidState(CommitmentStatus status);
    error FulfillmentPeriodNotEnded(uint currentTime, uint deadline);
    error AlreadyJoined();
    error NoRewardsToClaim();
    error CommitmentNotExists(uint id);
    error InvalidCreationFee(uint sent, uint required);
    error TokenNotAllowed(address token);
    error DescriptionTooLong();
    error JoinDealineTooEarly();
    error InvalidFullfillmentDeadline();
    error InvalidStakeAmount();
    error InvalidWinner(address winner);
    error JoiningPeriodEnded(uint currentTime, uint deadline);
    error DuplicateWinner(address winner);
    error InvalidJoinFee(uint sent, uint required);
    error OnlyCreatorCanResolve();
    error InvalidNumberOfWinners();
    error InvalidWinnerAddress();
    error CommitmentDoesNotExist();
    error OnlyCreatorOrOwnerCanCancel();
    error CommitmentNotActive();
    error CannotCancelAfterOthersHaveJoined();
    error CommitmentNotEmergencyCancelled();
    error NotAParticipant();
    error AlreadyClaimed();
    error CommitmentNotResolved();
    error NotAWinner();
    error OnlyCreatorCanClaim();
    error NoCreatorFeesToClaim();
    error InvalidJoinFeeNative();
    error InvalidStakeAmountNative();
    error InvalidCreationFeeNative();
    error InvalidJoinDeadline();

    uint256[49] __gap;
    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the contract with the protocol fee address
    /// @param _protocolFeeAddress The address where protocol fees are sent
    function initialize(address _protocolFeeAddress) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        require(
            _protocolFeeAddress != address(0),
            "Invalid protocol fee address"
        );
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
        bytes calldata _description,
        uint _joinDeadline,
        uint _fulfillmentDeadline
    ) external payable nonReentrant whenNotPaused returns (uint) {
        if (msg.value != PROTOCOL_CREATE_FEE) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }
        if (!allowedTokens.contains(_tokenAddress)) {
            revert TokenNotAllowed(_tokenAddress);
        }

        if (_description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }
        if (_joinDeadline <= block.timestamp) {
            revert JoinDealineTooEarly();
        }
        if (
            !(_fulfillmentDeadline > _joinDeadline &&
                _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION)
        ) {
            revert InvalidFullfillmentDeadline();
        }

        if (_stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        // Transfer stake amount for creator
        IERC20(_tokenAddress).transferFrom(
            msg.sender,
            address(this),
            _stakeAmount
        );

        uint commitmentId = nextCommitmentId++;

        CommitmentInfo memory info;
        info.id = commitmentId;
        info.creator = msg.sender;
        info.tokenAddress = _tokenAddress;
        info.stakeAmount = _stakeAmount;
        info.creatorFee = _creatorFee;
        info.description = _description;
        info.joinDeadline = _joinDeadline;
        info.fulfillmentDeadline = _fulfillmentDeadline;
        info.status = CommitmentStatus.Active;

        commitments[commitmentId].info = info;
        commitments[commitmentId].participants.participants.add(msg.sender);

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

    /// @notice Creates a commitment with specified parameters and stake requirements
    /// @param _creatorFee The fee required to join the commitment (optionally set by creator)
    /// @param _description A brief description of the commitment
    /// @param _joinDeadline The deadline for participants to join
    /// @param _fulfillmentDeadline The deadline for fulfilling the commitment
    /// @dev Creator becomes first participant by staking tokens + paying creation fee in ETH
    function createCommitmentNativeToken(
        uint256 _creatorFee,
        bytes calldata _description,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline
    ) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.value < PROTOCOL_CREATE_FEE) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }

        if (_description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }

        if (_joinDeadline <= block.timestamp) {
            revert InvalidJoinDeadline();
        }

        if (
            !(_fulfillmentDeadline > _joinDeadline &&
                _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION)
        ) {
            revert InvalidFullfillmentDeadline();
        }

        uint256 stakeAmount = msg.value - PROTOCOL_CREATE_FEE;

        if (stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        uint256 commitmentId = nextCommitmentId++;

        CommitmentInfo memory info;
        info.id = commitmentId;
        info.creator = msg.sender;
        info.tokenAddress = address(0);
        info.stakeAmount = stakeAmount;
        info.creatorFee = _creatorFee;
        info.description = _description;
        info.joinDeadline = _joinDeadline;
        info.fulfillmentDeadline = _fulfillmentDeadline;
        info.status = CommitmentStatus.Active;

        commitments[commitmentId].info = info;
        commitments[commitmentId].participants.participants.add(msg.sender);

        emit CommitmentCreated(
            commitmentId,
            msg.sender,
            address(0),
            stakeAmount,
            _creatorFee,
            _description
        );

        emit CommitmentJoined(commitmentId, msg.sender);

        return commitmentId;
    }
    /// @notice Allows joining an active commitment
    /// @param _id The ID of the commitment to join
    function joinCommitment(
        uint _id
    ) external payable nonReentrant whenNotPaused {
        if (_id >= nextCommitmentId) {
            revert CommitmentNotExists(_id);
        }
        if (msg.value < PROTOCOL_JOIN_FEE) {
            revert InvalidJoinFee(msg.value, PROTOCOL_JOIN_FEE);
        }

        Commitment storage commitment = commitments[_id];

        if (commitment.info.status != CommitmentStatus.Active) {
            revert InvalidState(commitment.info.status);
        }

        if (block.timestamp >= commitment.info.joinDeadline) {
            revert JoiningPeriodEnded(
                block.timestamp,
                commitment.info.joinDeadline
            );
        }

        if (commitment.participants.participants.contains(msg.sender)) {
            revert AlreadyJoined();
        }

        protocolFees[address(0)] += PROTOCOL_JOIN_FEE;

        uint totalAmount = commitment.info.stakeAmount;

        // Handle creator fee if set
        uint creatorFee = commitment.info.creatorFee;
        if (creatorFee > 0) {
            totalAmount += creatorFee;

            uint protocolEarnings = (creatorFee * PROTOCOL_SHARE) /
                BASIS_POINTS;

            // Update accumulated token fees
            protocolFees[commitment.info.tokenAddress] += protocolEarnings;
            commitment.claims.creatorClaim += creatorFee - protocolEarnings;
        }

        // Transfer total amount in one transaction

        if (commitment.info.tokenAddress == address(0)) {
            require(
                msg.value - PROTOCOL_JOIN_FEE == commitment.info.stakeAmount,
                "Invalid stake amount provided"
            );
        } else {
            // Transfer total amount in one transaction
            IERC20(commitment.info.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
        }

        // Record participant's join status
        commitment.participants.participants.add(msg.sender);

        emit CommitmentJoined(_id, msg.sender);
    }

    /// @notice Resolves commitment and distributes rewards to winners
    /// @param _id The ID of the commitment to resolve
    /// @param _winners The addresses of the participants who succeeded
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitment(
        uint _id,
        address[] memory _winners
    ) public nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];
        if (msg.sender != commitment.info.creator) {
            revert OnlyCreatorCanResolve();
        }

        if (commitment.info.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        // TODO: fix, insecure
        if (block.timestamp <= commitment.info.fulfillmentDeadline) {
            revert FulfillmentPeriodNotEnded(
                block.timestamp,
                commitment.info.fulfillmentDeadline
            );
        }

        EnumerableSet.AddressSet storage participants = commitment
            .participants
            .participants;
        EnumerableSet.AddressSet storage winners = commitment
            .participants
            .winners;

        // Cache lengths for gas
        uint winnerCount = _winners.length;
        uint participantCount = participants.length();

        // Check if winnerCount is valid
        if (winnerCount <= 0 || winnerCount > participantCount) {
            revert InvalidNumberOfWinners();
        }

        // Check each winner's address
        for (uint i = 0; i < winnerCount; i++) {
            address winner = _winners[i];

            if (!participants.contains(winner)) {
                revert InvalidWinnerAddress();
            }

            if (!winners.add(winner)) {
                revert DuplicateWinner(winner);
            }
        }

        // Process participants
        // Use local var to save gas so we dont have to read `commitment.failedCount` every time
        uint failedCount = participantCount - winnerCount;

        uint protocolStakeFee = (commitment.info.stakeAmount * PROTOCOL_SHARE) /
            BASIS_POINTS;

        // Protocol earns % of all commit stakes, won or lost
        protocolFees[commitment.info.tokenAddress] +=
            protocolStakeFee *
            participantCount;

        // Distribute stakes among winners, less protocol fees
        uint winnerStakeRefund = commitment.info.stakeAmount - protocolStakeFee;
        uint winnerStakeEarnings = ((commitment.info.stakeAmount -
            protocolStakeFee) * failedCount) / winnerCount;
        commitment.claims.winnerClaim = winnerStakeRefund + winnerStakeEarnings;

        // Mark commitment as resolved
        commitment.info.status = CommitmentStatus.Resolved;

        emit CommitmentResolved(_id, _winners);
    }

    /// @notice Allows creator or owner to cancel a commitment before anyone else joins
    /// @param _id The ID of the commitment to cancel
    /// @dev This calls resolveCommitment internally to handle refunds properly
    /// @dev Requires exactly 1 participant (the creator) since creator auto-joins on creation
    function cancelCommitment(uint _id) external whenNotPaused {
        if (_id >= nextCommitmentId) {
            revert CommitmentDoesNotExist();
        }

        Commitment storage commitment = commitments[_id];

        if (msg.sender != commitment.info.creator && msg.sender != owner()) {
            revert OnlyCreatorOrOwnerCanCancel();
        }

        if (commitment.info.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        if (commitment.participants.participants.length() != 1) {
            revert CannotCancelAfterOthersHaveJoined();
        }

        commitment.info.joinDeadline = 0;
        commitment.info.fulfillmentDeadline = 0;

        resolveCommitment(_id, commitment.participants.participants.values());

        commitment.info.status = CommitmentStatus.Cancelled;

        emit CommitmentCancelled(_id, msg.sender);
    }

    /// @notice Claims participant stake after emergency cancellation
    /// @dev No protocol fees are assessed however join fees are non-refundable
    /// @param _id The commitment ID to claim stake from
    function claimCancelled(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        if (commitment.info.status != CommitmentStatus.EmergencyCancelled) {
            revert CommitmentNotEmergencyCancelled();
        }

        if (!commitment.participants.participants.contains(msg.sender)) {
            revert NotAParticipant();
        }

        if (commitment.participants.participantClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }

        if (commitment.info.stakeAmount <= 0) {
            revert NoRewardsToClaim();
        }
        uint amount = commitment.info.stakeAmount;

        // Mark as claimed before transfer to prerror reentrancy
        commitment.participants.participantClaimed[msg.sender] = true;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitment.info.tokenAddress).transfer(msg.sender, amount);
        }

        emit EmergencyStakesReturned(
            _id,
            commitment.participants.participants.length(), // Total participant count for tracking
            msg.sender // Who initiated the return
        );
    }

    /// @notice Claims participant's rewards and stakes after commitment resolution
    /// @dev Winners can claim their original stake plus their share of rewards from failed stakes
    /// @dev Losers cannot claim anything as their stakes are distributed to winners
    /// @param _id The commitment ID to claim rewards from
    function claimRewards(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        if (commitment.info.status != CommitmentStatus.Resolved) {
            revert CommitmentNotResolved();
        }

        if (!commitment.participants.winners.contains(msg.sender)) {
            revert NotAWinner();
        }

        if (commitment.participants.participantClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }

        uint amount = commitment.claims.winnerClaim;
        if (amount <= 0) {
            revert NoRewardsToClaim();
        }

        // Mark as claimed before transfer to prevent reentrancy
        commitment.participants.participantClaimed[msg.sender] = true;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitment.info.tokenAddress).transfer(msg.sender, amount);
        }

        emit RewardsClaimed(
            _id,
            msg.sender,
            commitment.info.tokenAddress,
            amount
        );
    }

    /// @notice Claims creator's rewards
    /// @dev Creator can claim while the commitment is in progress
    /// @param _id The commitment ID to claim creator fees from
    function claimCreator(uint _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        if (commitment.info.creator != msg.sender) {
            revert OnlyCreatorCanClaim();
        }

        uint amount = commitment.claims.creatorClaim -
            commitment.claims.creatorClaimed;

        if (amount <= 0) {
            revert NoCreatorFeesToClaim();
        }

        // Update how much they have claimed to prevent reclaiming the same funds
        commitment.claims.creatorClaimed += amount;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitment.info.tokenAddress).transfer(msg.sender, amount);
        }

        emit CreatorClaimed(
            _id,
            msg.sender,
            commitment.info.tokenAddress,
            amount
        );
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
            (bool sent, ) = protocolFeeAddress.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            // Transfer accumulated fees
            IERC20(token).transfer(msg.sender, amount);
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
    function emergencyWithdrawToken(
        IERC20 token,
        uint amount
    ) external onlyOwner {
        uint balance = token.balanceOf(address(this));
        require(amount > 0 && amount <= balance, "Invalid withdrawal amount");
        token.transfer(owner(), amount);

        emit EmergencyWithdrawal(address(token), amount);
    }

    /// @notice Emergency function to cancel a specific commitment
    /// @dev Owner can perform `emergencyWithdrawToken` for manual distribution
    /// @param _id The ID of the commitment to cancel
    function emergencyCancelCommitment(uint _id) external onlyOwner {
        Commitment storage commitment = commitments[_id];
        require(
            commitment.info.status == CommitmentStatus.Active,
            "Commitment not active"
        );

        commitment.info.status = CommitmentStatus.EmergencyCancelled;

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

    // Core info
    function getCommitmentDetails(
        uint _id
    ) external view returns (CommitmentInfo memory) {
        return commitments[_id].info;
    }

    function getClaims(uint _id) external view returns (Claims memory) {
        return commitments[_id].claims;
    }

    function isParticipantClaimed(
        uint commitmentId,
        address participant
    ) public view returns (bool) {
        return
            commitments[commitmentId].participants.participantClaimed[
                participant
            ];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateAddress(address addr) internal pure {
        require(addr != address(0), "Invalid address");
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        require(
            newImplementation != address(0),
            "Invalid implementation address"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        require(false, "Direct deposits not allowed");
    }
}
