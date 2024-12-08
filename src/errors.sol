// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommitmentStatus} from "./storage.sol";

error AlreadyClaimed();
error AlreadyJoined();
error CannotCancelAfterOthersHaveJoined();
error CommitmentDoesNotExist();
error CommitmentNotActive();
error CommitmentNotCancelled();
error CommitmentNotExists(uint id);
error CommitmentNotResolved();
error DescriptionTooLong();
error DisperseCallFailed();
error DuplicateWinner(address winner);
error FulfillmentPeriodNotEnded(uint currentTime, uint deadline);
error InvalidCreationFee(uint sent, uint required);
error InvalidCreationFeeNative();
error InvalidFullfillmentDeadline();
error InvalidJoinDeadline();
error InvalidJoinFee(uint sent, uint required);
error InvalidJoinFeeNative();
error InvalidNumberOfWinners();
error InvalidStakeAmount();
error InvalidStakeAmountNative();
error InvalidState(CommitmentStatus status);
error InvalidTokenId();
error InvalidWinner(address winner);
error InvalidWinnerAddress();
error JoinDealineTooEarly();
error JoiningPeriodEnded(uint currentTime, uint deadline);
error NoCreatorFeesToClaim();
error NoRewardsToClaim();
error NotAParticipant();
error OnlyCreatorCanClaim();
error OnlyCreatorCanResolve();
error OnlyCreatorOrOwnerCanCancel();
error TokenNotAllowed(address token);
