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
import {Storage, CommitmentInfo} from "./storage.sol";
import "./errors.sol";
import "./logger.sol";

/// @title CommitProtocol - An onchain accountability protocol
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

    /// @notice Initializes the contract with commitment info and disperse contract
    /// @param _commitment_info Initial commitment configuration
    /// @param _disperse_contract The address of the disperse contract used for distributing rewards
    function initialize(
        CommitmentInfo memory _commitment_info,
        address _disperse_contract,
        address _protocol_fee_address
    ) public payable initializer {
        __Ownable_init(_commitment_info.creator);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ERC721_init("Commitment", "COMMITMENT");

        disperseContract = _disperse_contract;

        if (_commitment_info.description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }

        if (_commitment_info.joinDeadline <= block.timestamp) {
            revert InvalidJoinDeadline();
        }

        if (
            _commitment_info.fulfillmentDeadline <= _commitment_info.joinDeadline
                || _commitment_info.fulfillmentDeadline > block.timestamp + MAX_DEADLINE_DURATION
        ) {
            revert InvalidFullfillmentDeadline();
        }

        if (_commitment_info.stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        protocolFeeAddress = _protocol_fee_address;
        commitmentInfo = _commitment_info;

        _safeMint(_commitment_info.creator, ++latestTokenId);

        emit CommitmentCreated(
            _commitment_info.id,
            _commitment_info.creator,
            _commitment_info.tokenAddress,
            _commitment_info.stakeAmount,
            _commitment_info.creatorFee,
            _commitment_info.description
        );

        emit CommitmentJoined(_commitment_info.creator);
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows participants to join a commitment by paying required fees
    /// @dev Participant must pay join fee + stake amount + creator fee (if set)
    function join() external payable nonReentrant whenNotPaused {
        if (msg.value < PROTOCOL_JOIN_FEE) {
            revert InvalidJoinFee(msg.value, PROTOCOL_JOIN_FEE);
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert InvalidState(commitmentInfo.status);
        }

        if (block.timestamp >= commitmentInfo.joinDeadline) {
            revert JoiningPeriodEnded(block.timestamp, commitmentInfo.joinDeadline);
        }

        protocolFees[address(0)] += PROTOCOL_JOIN_FEE;

        uint256 _total_amount = commitmentInfo.stakeAmount;

        // Handle creator fee if set
        uint256 _creator_fee = commitmentInfo.creatorFee;
        if (_creator_fee > 0) {
            _total_amount += _creator_fee;

            uint256 _protocol_earnings = (_creator_fee * PROTOCOL_SHARE) / BASIS_POINTS;

            // Update accumulated token fees
            protocolFees[commitmentInfo.tokenAddress] += _protocol_earnings;
            claims.creatorClaim += _creator_fee - _protocol_earnings;
        }

        // Transfer total amount in one transaction
        if (commitmentInfo.tokenAddress == address(0)) {
            require(msg.value - PROTOCOL_JOIN_FEE == commitmentInfo.stakeAmount, "Invalid stake amount provided");
        } else {
            IERC20(commitmentInfo.tokenAddress).transferFrom(msg.sender, address(this), _total_amount);
        }

        uint256 _token_id = commitmentInfo.id + ++latestTokenId;
        _safeMint(msg.sender, _token_id);

        emit CommitmentJoined(msg.sender);
    }

    /// @notice Resolves commitment using merkle path for winner verification
    /// @param _root The merkle root of the participants who succeeded
    /// @param _leaves_count The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitmentMerklePath(bytes32 _root, uint256 _leaves_count) public nonReentrant whenNotPaused {
        claims.root = _root;
        _resolveCommitment(_leaves_count);
    }

    /// @notice Resolves commitment using disperse contract for reward distribution
    /// @param _winner_count The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitmentDisperse(uint256 _winner_count) external nonReentrant whenNotPaused {
        _resolveCommitment(_winner_count);
        if (commitmentInfo.tokenAddress != address(0)) {
            IERC20(commitmentInfo.tokenAddress).approve(disperseContract, type(uint256).max);
        } else {
            (bool success,) = disperseContract.call{value: commitmentInfo.stakeAmount * latestTokenId}("");
            if (!success) {
                revert DisperseCallFailed();
            }
        }
    }

    /// @notice Allows creator or owner to cancel a commitment before anyone else joins
    /// @dev This calls resolveCommitment internally to handle refunds properly
    /// @dev Requires exactly 1 participant (the creator) since creator auto-joins on creation
    function cancel() external whenNotPaused {
        if (msg.sender != commitmentInfo.creator && msg.sender != owner()) {
            revert OnlyCreatorOrOwnerCanCancel();
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        commitmentInfo.joinDeadline = 0;
        commitmentInfo.fulfillmentDeadline = 0;

        commitmentInfo.status = CommitmentStatus.Cancelled;

        emit CommitmentCancelled(msg.sender);
    }

    /// @notice Claims participant stake after emergency cancellation
    /// @dev No protocol fees are assessed however join fees are non-refundable
    /// @param _token_id The NFT ID to claim stake from
    function claimCancelled(uint256 _token_id) external nonReentrant whenNotPaused {
        if (commitmentInfo.status != CommitmentStatus.Cancelled) {
            revert CommitmentNotCancelled();
        }

        if (participatingNFTs[_token_id]) {
            revert AlreadyClaimed();
        }

        if (_token_id - (commitmentInfo.id << 128) != latestTokenId) {
            revert InvalidTokenId();
        }

        if (ownerOf(_token_id) != msg.sender) {
            revert NotAParticipant();
        }

        if (commitmentInfo.stakeAmount <= 0) {
            revert NoRewardsToClaim();
        }
        uint256 _amount = commitmentInfo.stakeAmount;

        // Mark as claimed before transfer to prevent reentrancy
        participatingNFTs[_token_id] = true;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success,) = msg.sender.call{value: _amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, _amount);
        }

        emit EmergencyStakesReturned(
            commitmentInfo.id,
            msg.sender // Who initiated the return
        );
    }

    /// @notice Claims participant's rewards and stakes after commitment resolution
    /// @dev Winners can claim their original stake plus their share of rewards from failed stakes
    /// @dev Losers cannot claim anything as their stakes are distributed to winners
    /// @param _token_id The NFT ID to claim rewards from
    /// @param _proof The merkle proof to verify winner status
    function claimRewards(uint256 _token_id, bytes32[] calldata _proof) external nonReentrant whenNotPaused {
        if (commitmentInfo.status != CommitmentStatus.Resolved) {
            revert CommitmentNotResolved();
        }

        if (participatingNFTs[_token_id]) {
            revert AlreadyClaimed();
        }
        bytes32 _leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        bool _is_valid_winner = MerkleProof.verify(_proof, claims.root, _leaf);

        if (!_is_valid_winner) {
            revert InvalidWinner(msg.sender);
        }

        uint256 _amount = claims.winnerClaim;
        if (_amount <= 0) {
            revert NoRewardsToClaim();
        }

        // Mark as claimed before transfer to prevent reentrancy
        participatingNFTs[_token_id] = true;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success,) = msg.sender.call{value: _amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, _amount);
        }

        emit RewardsClaimed(_token_id, msg.sender, commitmentInfo.tokenAddress, _amount);
    }

    /// @notice Claims creator's rewards
    /// @dev Creator can claim while the commitment is in progress
    function claimCreator(uint256 _id) external nonReentrant whenNotPaused {
        if (commitmentInfo.creator != msg.sender) {
            revert OnlyCreatorCanClaim();
        }

        uint256 _amount = claims.creatorClaim - claims.creatorClaimed;

        if (_amount <= 0) {
            revert NoCreatorFeesToClaim();
        }

        // Update how much they have claimed to prevent reclaiming the same funds
        claims.creatorClaimed += _amount;

        if (commitmentInfo.tokenAddress == address(0)) {
            (bool success,) = msg.sender.call{value: _amount}("");
            require(success, "Native token transfer failed");
        } else {
            IERC20(commitmentInfo.tokenAddress).transfer(msg.sender, _amount);
        }

        emit CreatorClaimed(_id, msg.sender, commitmentInfo.tokenAddress, _amount);
    }

    /// @notice Internal function to resolve a commitment and calculate winner rewards
    /// @param _winner_count The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function _resolveCommitment(uint256 _winner_count) internal {
        if (msg.sender != commitmentInfo.creator) {
            revert OnlyCreatorCanResolve();
        }

        if (commitmentInfo.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        // TODO: fix, insecure
        if (block.timestamp <= commitmentInfo.fulfillmentDeadline) {
            revert FulfillmentPeriodNotEnded(block.timestamp, commitmentInfo.fulfillmentDeadline);
        }

        // Calculate failed participants
        uint256 _failed_count = latestTokenId - _winner_count;

        uint256 _protocol_stake_fee = (commitmentInfo.stakeAmount * PROTOCOL_SHARE) / BASIS_POINTS;

        // Protocol earns % of all commit stakes, won or lost
        protocolFees[commitmentInfo.tokenAddress] += _protocol_stake_fee * latestTokenId;

        // Distribute stakes among winners, less protocol fees
        uint256 _winner_stake_refund = commitmentInfo.stakeAmount - _protocol_stake_fee;
        uint256 _winner_stake_earnings =
            ((commitmentInfo.stakeAmount - _protocol_stake_fee) * _failed_count) / _winner_count;

        claims.winnerClaim = _winner_stake_refund + _winner_stake_earnings;

        // Mark commitment as resolved
        commitmentInfo.status = CommitmentStatus.Resolved;

        emit CommitmentResolved(_winner_count);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the protocol fee address
    /// @param _new_address The new address for protocol fees
    function setProtocolFeeAddress(address payable _new_address) external onlyOwner {
        require(_new_address != address(0), "Invalid protocol fee address");

        address _old_address = protocolFeeAddress;
        protocolFeeAddress = _new_address;

        emit ProtocolFeeAddressUpdated(_old_address, _new_address);
    }

    /// @notice Claims accumulated fees for a specific token
    /// @param _token The address of the token to claim fees for
    /// @dev Protocol owner claims via protocolFeeAddress
    /// @dev Protocol fees come from join fees (PROTOCOL_SHARE%) and stakes (PROTOCOL_SHARE%)
    /// @dev Creator fees come from creatorFee (optional commitment join fee)
    function claimProtocolFees(address _token) external onlyOwner nonReentrant {
        uint256 _amount = protocolFees[_token];

        require(_amount > 0, "No fees to claim");

        // Clear balance before transfer to prevent reentrancy
        protocolFees[_token] = 0;

        if (_token == address(0)) {
            // Transfer creation fee in ETH
            (bool sent,) = protocolFeeAddress.call{value: _amount}("");
            require(sent, "ETH transfer failed");
        } else {
            // Transfer accumulated fees
            IERC20(_token).transfer(msg.sender, _amount);
        }

        emit FeesClaimed(msg.sender, _token, _amount);
    }

    /// @notice Gets the accumulated protocol fees for a specific token
    /// @param _token The address of the token to check fees for
    /// @return The amount of accumulated fees for the token
    function getProtocolFees(address _token) external view returns (uint256) {
        return protocolFees[_token];
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdrawal of stuck tokens
    /// @param _token The address of the token to withdraw
    /// @param _amount The amount of tokens to withdraw
    function emergencyWithdrawToken(IERC20 _token, uint256 _amount) external onlyOwner {
        uint256 _balance = _token.balanceOf(address(this));
        require(_amount > 0 && _amount <= _balance, "Invalid withdrawal amount");
        _token.transfer(owner(), _amount);

        emit EmergencyWithdrawal(address(_token), _amount);
    }

    /// @notice Emergency function to pause any function that uses whenNotPaused
    function emergencyPauseAll() external onlyOwner {
        _pause();

        emit ContractPaused();
    }

    /// @notice Emergency function to unpause all functions blocked on whenNotPaused
    function emergencyUnpauseAll() external onlyOwner {
        _unpause();

        emit ContractUnpaused();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if a participant has claimed their rewards/refund
    /// @param _token_id The NFT ID to check claim status for
    /// @return True if participant has claimed, false otherwise
    function isParticipantClaimed(uint256 _token_id) public view returns (bool) {
        return participatingNFTs[_token_id];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates an address is not zero
    /// @param _addr The address to validate
    function _validateAddress(address _addr) internal pure {
        require(_addr != address(0), "Invalid address");
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param _new_implementation The address of the new implementation
    /// @dev Only owner can upgrade the contract
    function _authorizeUpgrade(address _new_implementation) internal view override onlyOwner {
        require(_new_implementation != address(0), "Invalid implementation address");
    }

    /// @notice Returns the base URI for token metadata
    /// @dev Overrides ERC721's _baseURI() to return the commitment's metadata URI
    /// @return The base URI string stored in commitmentInfo
    function _baseURI() internal view override returns (string memory) {
        return commitmentInfo.metadataURI;
    }

    /// @notice Updates the metadata URI for the commitment
    /// @param _uri The new metadata URI
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
