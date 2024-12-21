// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Commitment lifecycle events
event TokenAllowanceUpdated(address indexed token, bool allowed);

event CommitmentCreated(
    uint256 indexed id,
    address indexed creator,
    address tokenAddress,
    uint256 stakeAmount,
    uint256 creatorFee,
    bytes description
);

event CommitmentJoined(address indexed participant);

event CommitmentResolved(uint256 winners);

event CommitmentCancelled(address indexed cancelledBy);

event CommitmentEmergencyCancelled(uint256 indexed id);

// Claim events
event RewardsClaimed(uint256 indexed id, address indexed participant, address indexed token, uint256 amount);

event CreatorClaimed(uint256 indexed id, address indexed creator, address indexed token, uint256 amount);

event WinnerClaimed(uint256 indexed id, address indexed winner, address indexed token, uint256 amount);

event EmergencyStakesReturned(uint256 indexed id, address initiator);

// Fee events
event ProtocolFeePaid(uint256 indexed id, address indexed participant, address indexed token, uint256 amount);

event CreatorFeePaid(uint256 indexed id, address indexed participant, address indexed token, uint256 amount);

event FeesClaimed(address indexed recipient, address indexed token, uint256 amount);

// Admin events
event TokenListUpdated(address indexed token, bool allowed);

event ProtocolFeeAddressUpdated(address oldAddress, address newAddress);

event EmergencyWithdrawal(address indexed token, uint256 amount);

event ContractPaused();

event ContractUnpaused();
