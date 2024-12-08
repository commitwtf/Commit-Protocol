// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
event CommitmentResolved(uint indexed id, uint winners);
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
event EmergencyStakesReturned(uint indexed id, address initiator);

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
