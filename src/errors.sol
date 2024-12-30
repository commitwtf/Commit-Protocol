// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommitmentStatus} from "./storage.sol";

error AlreadyClaimed();
error AlreadyJoined();
error CannotCancelAfterOthersHaveJoined();
error ClientNotExists(address client);
error CommitmentAlreadyResolved();
error CommitmentDoesNotExist();
error CommitmentNotActive();
error CommitmentNotCancelled();
error CommitmentNotExists(uint256 id);
error CommitmentNotResolved();
error DescriptionTooLong();
error DirectDepositsNotAllowed();
error DisperseCallFailed();
error DuplicateWinner(address winner);
error FulfillmentPeriodNotEnded(uint256 currentTime, uint256 deadline);
error InvalidAddress();
error InvalidCreationFee(uint256 sent, uint256 required);
error InvalidCreationFeeNative();
error InvalidFullfillmentDeadline();
error InvalidFundingAmount();
error InvalidImplementationAddress();
error InvalidJoinDeadline();
error InvalidJoinFee(uint256 sent, uint256 required);
error InvalidJoinFeeNative();
error InvalidNumberOfWinners();
error InvalidProtocolFeeAddress();
error InvalidRewardAmount();
error InvalidStakeAmount();
error InvalidStakeAmountNative();
error InvalidState(CommitmentStatus status);
error InvalidTokenId();
error InvalidWinner(address winner);
error InvalidWinnerAddress();
error InvalidWithdrawalAmount();
error JoinDealineTooEarly();
error JoiningPeriodEnded(uint256 currentTime, uint256 deadline);
error NativeTokenTransferFailed();
error NoCreatorFeesToClaim();
error NoFeesToClaim();
error NoRewardsToClaim();
error NotAParticipant();
error OnlyClientCanRemove();
error OnlyCreatorCanClaim();
error OnlyCreatorCanResolve();
error OnlyCreatorOrOwnerCanCancel();
error OnlyCreatorOrOwnerCanUpdateURI();
error TokenNotAllowed(address token);
