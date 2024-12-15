// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Storage} from "./storage.sol";
import "./errors.sol";
import "./logger.sol";
/// @title CommitProtocol — an onchain accountability protocol
/// @notice Enables users to create and participate in commitment-based challenges
/// @dev Implements stake management, fee distribution, and emergency controls
/// @author Rachit Anand Srivastava (@privacy_prophet)

contract CommitProtocol is
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ERC721Upgradeable,
    Storage
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @param _disperseContract The address of the disperse contract used for distributing rewards
    function initialize(
        CommitmentInfo memory _commitmentInfo,
        address _disperseContract
    ) public payable initializer {
        __Ownable_init(_commitmentInfo.creator);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ERC721_init("Commitment", "COMMITMENT");

        disperseContract = disperseContract;

        if (_commitmentInfo.description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }

        if (_commitmentInfo.joinDeadline <= block.timestamp) {
            revert InvalidJoinDeadline();
        }

        if (
            _commitmentInfo.fulfillmentDeadline <=
            _commitmentInfo.joinDeadline ||
            _commitmentInfo.fulfillmentDeadline >
            block.timestamp + MAX_DEADLINE_DURATION
        ) {
            revert InvalidFullfillmentDeadline();
        }

        if (_commitmentInfo.stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        commitmentInfo = _commitmentInfo;

        _safeMint(commitmentInfo.creator, ++latestTokenId);

        emit CommitmentCreated(
            _commitmentInfo.id,
            _commitmentInfo.creator,
            _commitmentInfo.tokenAddress,
            _commitmentInfo.stakeAmount,
            _commitmentInfo.creatorFee,
            _commitmentInfo.description
        );

        emit CommitmentJoined(_commitmentInfo.id, _commitmentInfo.creator);
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows joining an active commitment
    /// @param _id The ID of the commitment to join
    /// @dev Participant must pay join fee + stake amount + creator fee (if set)
    function joinCommitment(
        uint256 _id
    ) external payable nonReentrant whenNotPaused {
        if (_id != commitmentInfo.id) {
            revert CommitmentNotExists(_id);
        }
        if (msg.value < PROTOCOL_JOIN_FEE) {
            revert InvalidJoinFee(msg.value, PROTOCOL_JOIN_FEE);
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert InvalidState(commitmentInfo.status);
        }

        if (block.timestamp >= commitmentInfo.joinDeadline) {
            revert JoiningPeriodEnded(
                block.timestamp,
                commitmentInfo.joinDeadline
            );
        }

        protocolFees[address(0)] += PROTOCOL_JOIN_FEE;

        uint256 totalAmount = commitmentInfo.stakeAmount;

        // Handle creator fee if set
        uint256 creatorFee = commitmentInfo.creatorFee;
        if (creatorFee > 0) {
            totalAmount += creatorFee;

            uint256 protocolEarnings = (creatorFee * PROTOCOL_SHARE) /
                BASIS_POINTS;

            // Update accumulated token fees
            protocolFees[commitmentInfo.tokenAddress] += protocolEarnings;
            claims.creatorClaim += creatorFee - protocolEarnings;
        }

        // Transfer total amount in one transaction

        if (commitmentInfo.tokenAddress == address(0)) {
            require(
                msg.value - PROTOCOL_JOIN_FEE == commitmentInfo.stakeAmount,
                "Invalid stake amount provided"
            );
        } else {
            // Transfer total amount in one transaction
            IERC20(commitmentInfo.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
        }

        uint256 tokenId = commitmentInfo.id + ++latestTokenId;
        _safeMint(msg.sender, tokenId);

        emit CommitmentJoined(_id, msg.sender);
    }

    /// @notice Resolves commitment using merkle path for winner verification
    /// @param _id The ID of the commitment to resolve
    /// @param _root The merkle root of the participants who succeeded
    /// @param _leavesCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitmentMerklePath(
        uint256 _id,
        bytes32 _root,
        uint256 _leavesCount
    ) public nonReentrant whenNotPaused {
        claims.root = _root;
        _resolveCommitment(_id, _leavesCount);
    }

    /// @notice Resolves commitment using disperse contract for reward distribution
    /// @param _id The ID of the commitment to resolve
    /// @param winnerCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitmentDisperse(
        uint256 _id,
        uint256 winnerCount
    ) external nonReentrant whenNotPaused {
        _resolveCommitment(_id, winnerCount);
        if (commitmentInfo.tokenAddress != address(0)) {
            IERC20(commitmentInfo.tokenAddress).approve(
                disperseContract,
                type(uint256).max
            );
        } else {
            (bool success, ) = disperseContract.call{
                value: commitmentInfo.stakeAmount * latestTokenId
            }("");
            if (!success) {
                revert DisperseCallFailed();
            }
        }
    }

    /// @notice Allows creator or owner to cancel a commitment before anyone else joins
    /// @param _id The ID of the commitment to cancel
    /// @dev This calls resolveCommitment internally to handle refunds properly
    /// @dev Requires exactly 1 participant (the creator) since creator auto-joins on creation
    function cancelCommitment(uint256 _id) external whenNotPaused {
        if (_id >= commitmentInfo.id) {
            revert CommitmentDoesNotExist();
        }

        if (msg.sender != commitmentInfo.creator && msg.sender != owner()) {
            revert OnlyCreatorOrOwnerCanCancel();
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        commitmentInfo.joinDeadline = 0;
        commitmentInfo.fulfillmentDeadline = 0;

        commitmentInfo.status = CommitmentStatus.Cancelled;

        emit CommitmentCancelled(_id, msg.sender);
    }

    /// @notice Claims participant stake after emergency cancellation
    /// @dev No protocol fees are assessed however join fees are non-refundable
    /// @param tokenId The nft ID to claim stake from
    function claimCancelled(
        uint256 tokenId
    ) external nonReentrant whenNotPaused {
        if (commitmentInfo.status != CommitmentStatus.Cancelled) {
            revert CommitmentNotCancelled();
        }

        if (participantClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }

        if (tokenId - (commitmentInfo.id << 128) != latestTokenId) {
            revert InvalidTokenId();
        }

        if (ownerOf(tokenId) != msg.sender) {
            revert NotAParticipant();
        }

        if (commitmentInfo.stakeAmount <= 0) {
            revert NoRewardsToClaim();
        }
        uint256 amount = commitmentInfo.stakeAmount;

        // Mark as claimed before transfer to prerror reentrancy
        participantClaimed[msg.sender] = true;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, amount);
        }

        emit EmergencyStakesReturned(
            commitmentInfo.id,
            msg.sender // Who initiated the return
        );
    }

    /// @notice Claims participant's rewards and stakes after commitment resolution
    /// @dev Winners can claim their original stake plus their share of rewards from failed stakes
    /// @dev Losers cannot claim anything as their stakes are distributed to winners
    /// @param _id The commitment ID to claim rewards from
    /// @param _proof The merkle proof to verify winner status
    function claimRewards(
        uint256 _id,
        bytes32[] calldata _proof
    ) external nonReentrant whenNotPaused {
        if (commitmentInfo.status != CommitmentStatus.Resolved) {
            revert CommitmentNotResolved();
        }

        if (participantClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender)))
        );
        bool isValidWinner = MerkleProof.verify(_proof, claims.root, leaf);

        if (!isValidWinner) {
            revert InvalidWinner(msg.sender);
        }

        uint256 amount = claims.winnerClaim;
        if (amount <= 0) {
            revert NoRewardsToClaim();
        }

        // Mark as claimed before transfer to prevent reentrancy
        participantClaimed[msg.sender] = true;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, amount);
        }

        emit RewardsClaimed(
            _id,
            msg.sender,
            commitmentInfo.tokenAddress,
            amount
        );
    }

    /// @notice Claims creator's rewards
    /// @dev Creator can claim while the commitment is in progress
    /// @param _id The commitment ID to claim creator fees from
    function claimCreator(uint256 _id) external nonReentrant whenNotPaused {
        if (commitmentInfo.creator != msg.sender) {
            revert OnlyCreatorCanClaim();
        }

        uint256 amount = claims.creatorClaim - claims.creatorClaimed;

        if (amount <= 0) {
            revert NoCreatorFeesToClaim();
        }

        // Update how much they have claimed to prevent reclaiming the same funds
        claims.creatorClaimed += amount;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, amount);
        }

        emit CreatorClaimed(
            _id,
            msg.sender,
            commitmentInfo.tokenAddress,
            amount
        );
    }

    /// @notice Internal function to resolve a commitment and calculate winner rewards
    /// @param _id The commitment ID to resolve
    /// @param winnerCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function _resolveCommitment(uint256 _id, uint256 winnerCount) internal {
        if (msg.sender != commitmentInfo.creator) {
            revert OnlyCreatorCanResolve();
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        // TODO: fix, insecure
        if (block.timestamp <= commitmentInfo.fulfillmentDeadline) {
            revert FulfillmentPeriodNotEnded(
                block.timestamp,
                commitmentInfo.fulfillmentDeadline
            );
        }
        // Process participants
        // Use local var to save gas so we dont have to read `commitment.failedCount` every time
        uint256 failedCount = latestTokenId - winnerCount;

        uint256 protocolStakeFee = (commitmentInfo.stakeAmount *
            PROTOCOL_SHARE) / BASIS_POINTS;

        // Protocol earns % of all commit stakes, won or lost
        protocolFees[commitmentInfo.tokenAddress] +=
            protocolStakeFee *
            latestTokenId;

        // Distribute stakes among winners, less protocol fees
        uint256 winnerStakeRefund = commitmentInfo.stakeAmount -
            protocolStakeFee;
        uint256 winnerStakeEarnings = ((commitmentInfo.stakeAmount -
            protocolStakeFee) * failedCount) / winnerCount;

        claims.winnerClaim = winnerStakeRefund + winnerStakeEarnings;

        // Mark commitment as resolved
        commitmentInfo.status = CommitmentStatus.Resolved;

        emit CommitmentResolved(_id, winnerCount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the protocol fee address
    /// @param _newAddress The new address for protocol fees
    function setProtocolFeeAddress(
        address payable _newAddress
    ) external onlyOwner {
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
        uint256 amount = protocolFees[token];

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

    /// @notice Gets the accumulated protocol fees for a specific token
    /// @param token The address of the token to check fees for
    /// @return The amount of accumulated fees for the token
    function getProtocolFees(address token) external view returns (uint256) {
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
        uint256 amount
    ) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(amount > 0 && amount <= balance, "Invalid withdrawal amount");
        token.transfer(owner(), amount);

        emit EmergencyWithdrawal(address(token), amount);
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

    /// @notice Checks if a participant has claimed their rewards/refund
    /// @param commitmentId The ID of the commitment
    /// @param participant The address of the participant
    /// @return True if participant has claimed, false otherwise
    function isParticipantClaimed(
        uint256 commitmentId,
        address participant
    ) public view returns (bool) {
        return participantClaimed[participant];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates an address is not zero
    /// @param addr The address to validate
    function _validateAddress(address addr) internal pure {
        require(addr != address(0), "Invalid address");
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation The address of the new implementation
    /// @dev Only owner can upgrade the contract
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        require(
            newImplementation != address(0),
            "Invalid implementation address"
        );
    }

    function tokenURI(
        uint256 _id
    ) public view override returns (string memory) {
        return commitmentInfo.metadataURI;
    }

    function updateMetadataURI(string memory _uri) public {
        if (msg.sender != commitmentInfo.creator && msg.sender != owner()) {
            revert OnlyCreatorOrOwnerCanUpdateURI();
        }
        commitmentInfo.metadataURI = _uri;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevents accidental ETH transfers to contract
    receive() external payable {
        require(false, "Direct deposits not allowed");
    }
}
