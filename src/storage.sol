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
        uint id; // Unique identifier
        address creator; // Address that created the commitment
        address tokenAddress; // Token used for staking
        uint stakeAmount; // Amount each participant must stake
        uint creatorFee; // Optional fee in ERC20 token
        bytes description; // Description of the commitment
        uint joinDeadline; // Deadline to join
        uint fulfillmentDeadline; // Deadline to fulfill commitment
        string metadataURI;
        CommitmentStatus status; // Current status of the commitment
    }

    struct Claims {
        uint winnerClaim; // Amount each winner can claim
        uint creatorClaim; // Total amount creator can claim
        uint creatorClaimed; // Amount creator has already claimed
        bytes32 root; // Merkle root of the winners
    }

    struct CommitmentParticipants {
        mapping(address => bool) participantClaimed; // Tracking if a participant has claimed
    }

    /// @notice Represents a single commitment with its rules and state
    /// @dev Uses EnumerableSet for participant management and mapping for success tracking
    struct Commitment {
        CommitmentInfo info; // Basic commitment details
        Claims claims; // Creator and winner claim details
        CommitmentParticipants participants; // Participants and winners details
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

    uint public commitmentIDCount;
    address public protocolFeeAddress;
    mapping(uint => Commitment) internal commitments;
    mapping(address => uint) public protocolFees;
    mapping(uint => uint) public commitmentTokenCount;
    EnumerableSet.AddressSet internal allowedTokens;
    address public disperseContract;

    uint256[49] internal __gap;
}
