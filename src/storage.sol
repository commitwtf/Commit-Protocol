// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

enum CommitmentStatus {
    Active,
    Resolved,
    Cancelled,
    EmergencyCancelled
}

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
    CommitmentStatus status; // Current status of the commitment
}

struct Claims {
    uint256 winnerClaim; // Amount each winner can claim
    uint256 creatorClaim; // Total amount creator can claim
    uint256 creatorClaimed; // Amount creator has already claimed
    bytes32 root; // Merkle root of the winners
}

contract Storage {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Protocol fees
    uint256 public constant PROTOCOL_JOIN_FEE = 0.0002 ether; // Fixed ETH fee for joining
    uint256 public constant PROTOCOL_SHARE = 100; // 1% of stakes and creator fees

    // Other constants
    uint256 public constant BASIS_POINTS = 10000; // For percentage calculations
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1000; // Characters
    uint256 public constant MAX_DEADLINE_DURATION = 365 days; // Max time window

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    address public protocolFeeAddress;
    mapping(address => uint256) public protocolFees;

    address public disperseContract;
    mapping(uint256 => bool) participatingNFTs; // Tracking if a participant has claimed
    uint256 internal latestTokenId;
    CommitmentInfo public commitmentInfo;
    Claims public claims;
    uint256[49] internal __gap;
}
