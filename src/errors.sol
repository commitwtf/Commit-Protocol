// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommitmentStatus} from "./storage.sol";

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
