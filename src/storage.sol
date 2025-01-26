// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

enum CommitmentStatus {
    Active,
    Resolved,
    Cancelled,
    EmergencyCancelled
}

contract Storage {
    struct CommitmentInfo {
        uint256 id; // Unique identifier
        address creator; // Address that created the commitment
        address tokenAddress; // Token used for staking
        uint256 stakeAmount; // Amount each participant must stake
        uint256 creatorFee; // Optional fee in ERC20 token
        bytes description; // Description of the commitment
        uint256 joinDeadline; // Deadline to join
        uint256 fulfillmentDeadline; // Deadline to fulfill commitment
        string metadataURI;
        uint256 funding;
        CommitmentStatus status; // Current status of the commitment
    }

    struct Claims {
        uint256 winnerClaim; // Amount each winner can claim
        uint256 creatorClaim; // Total amount creator can claim
        uint256 creatorClaimed; // Amount creator has already claimed
        uint256 winnerCount; // Number of winners
        bytes32 root; // Merkle root of the winners
    }

    struct CommitmentParticipants {
        mapping(uint256 => bool) nftsClaimed; // Tracking if a participant has claimed
        mapping(address => mapping(address => uint256)) publicFunding;
        mapping(address => uint256) tokenFunding;
    }

    /// @notice Represents a single commitment with its rules and state
    /// @dev Uses EnumerableSet for participant management and mapping for success tracking
    struct Commitment {
        CommitmentInfo info; // Basic commitment details
        Claims claims; // Creator and winner claim details
        CommitmentParticipants participants; // Participants and winners details
    }

    struct Client {
        address clientAddress;
        address clientWithdrawAddress;
        uint256 clientFeeShare;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Protocol fees
    uint256 public constant PROTOCOL_JOIN_FEE = 0.0002 ether; // Fixed ETH fee for joining
    uint256 public constant PROTOCOL_CREATE_FEE = 0.001 ether; // Fixed ETH fee for creating
    uint256 public constant PROTOCOL_SHARE = 100; // 1% of stakes and creator fees

    // Other constants
    uint256 public constant BASIS_POINTS = 10000; // For percentage calculations
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1000; // Characters
    uint256 public constant MAX_DEADLINE_DURATION = 365 days; // Max time window

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public commitmentIDCount;
    address public protocolFeeAddress;

    mapping(uint256 => Commitment) internal commitments;
    mapping(address => uint256) public protocolFees;
    mapping(uint256 => uint256) public commitmentTokenCount;
    mapping(address => Client) public clients;
    EnumerableSet.AddressSet internal allowedTokens;
    address public disperseContract;

    uint256[49] internal __gap;
}
