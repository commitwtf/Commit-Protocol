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

    /// @notice Initializes the contract with the protocol fee address
    /// @param _protocolFeeAddress The address where protocol fees are sent
    /// @param _disperseContract The address of the disperse contract used for distributing rewards
    function initialize(
        address _protocolFeeAddress,
        address _disperseContract
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ERC721_init("Commitment", "COMMITMENT");
        if (_protocolFeeAddress == address(0)) {
            revert InvalidProtocolFeeAddress();
        }
        protocolFeeAddress = _protocolFeeAddress;
        disperseContract = _disperseContract;
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a commitment with specified parameters and stake requirements
    /// @param _tokenAddress The address of the ERC20 token used for staking
    /// @param _stakeAmount The amount each participant must stake
    /// @param _creatorFee The fee required to join the commitment (optionally set by creator)
    /// @param _description A brief description of the commitment
    /// @param _joinDeadline The deadline for participants to join
    /// @param _fulfillmentDeadline The deadline for fulfilling the commitment
    /// @param _metadataURI The URI for the commitment's metadata
    /// @dev Creator becomes first participant by staking tokens + paying creation fee in ETH
    /// @return The ID of the newly created commitment
    function createCommitment(
        address _tokenAddress,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        bytes calldata _description,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline,
        string calldata _metadataURI,
        address _clientId
    ) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.value != PROTOCOL_CREATE_FEE) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }
        if (!allowedTokens.contains(_tokenAddress)) {
            revert TokenNotAllowed(_tokenAddress);
        }

        if (_description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }
        if (_joinDeadline <= block.timestamp) {
            revert JoinDealineTooEarly();
        }
        if (
            !(_fulfillmentDeadline > _joinDeadline &&
                _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION)
        ) {
            revert InvalidFullfillmentDeadline();
        }

        if (_stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        //  if()

        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        // Transfer stake amount for creator
        IERC20(_tokenAddress).transferFrom(
            msg.sender,
            address(this),
            _stakeAmount
        );

        uint256 commitmentId = ++commitmentIDCount;

        CommitmentInfo memory info;
        info.id = commitmentId;
        info.creator = msg.sender;
        info.tokenAddress = _tokenAddress;
        info.stakeAmount = _stakeAmount;
        info.creatorFee = _creatorFee;
        info.description = _description;
        info.joinDeadline = _joinDeadline;
        info.fulfillmentDeadline = _fulfillmentDeadline;
        info.metadataURI = _metadataURI;
        info.status = CommitmentStatus.Active;

        commitments[commitmentId].info = info;
        _safeMint(
            msg.sender,
            (commitmentId << 128) + ++commitmentTokenCount[commitmentId]
        );

        emit CommitmentCreated(
            commitmentId,
            msg.sender,
            _tokenAddress,
            _stakeAmount,
            _creatorFee,
            _description
        );

        emit CommitmentJoined(commitmentId, msg.sender);

        return commitmentId;
    }

    /// @notice Creates a commitment using native tokens (ETH) for staking
    /// @param _creatorFee The fee required to join the commitment (optionally set by creator)
    /// @param _description A brief description of the commitment
    /// @param _joinDeadline The deadline for participants to join
    /// @param _fulfillmentDeadline The deadline for fulfilling the commitment
    /// @param _metadataURI The URI for the commitment's metadata
    /// @dev Creator becomes first participant by staking ETH + paying creation fee in ETH
    /// @return The ID of the newly created commitment
    function createCommitmentNativeToken(
        uint256 _creatorFee,
        bytes calldata _description,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline,
        string calldata _metadataURI
    ) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.value < PROTOCOL_CREATE_FEE) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }

        if (_description.length > MAX_DESCRIPTION_LENGTH) {
            revert DescriptionTooLong();
        }

        if (_joinDeadline <= block.timestamp) {
            revert InvalidJoinDeadline();
        }

        if (
            !(_fulfillmentDeadline > _joinDeadline &&
                _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION)
        ) {
            revert InvalidFullfillmentDeadline();
        }

        uint256 stakeAmount = msg.value - PROTOCOL_CREATE_FEE;

        if (stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        uint256 commitmentId = ++commitmentIDCount;

        CommitmentInfo memory info;
        info.id = commitmentId;
        info.creator = msg.sender;
        info.tokenAddress = address(0);
        info.stakeAmount = stakeAmount;
        info.creatorFee = _creatorFee;
        info.description = _description;
        info.joinDeadline = _joinDeadline;
        info.fulfillmentDeadline = _fulfillmentDeadline;
        info.metadataURI = _metadataURI;
        info.status = CommitmentStatus.Active;

        commitments[commitmentId].info = info;

        _safeMint(
            msg.sender,
            (commitmentId << 128) + ++commitmentTokenCount[commitmentId]
        );

        emit CommitmentCreated(
            commitmentId,
            msg.sender,
            address(0),
            stakeAmount,
            _creatorFee,
            _description
        );

        emit CommitmentJoined(commitmentId, msg.sender);

        return commitmentId;
    }

    /// @notice Allows joining an active commitment
    /// @param _id The ID of the commitment to join
    /// @dev Participant must pay join fee + stake amount + creator fee (if set)
    function joinCommitment(
        uint256 _id,
        address _clientId
    ) external payable nonReentrant whenNotPaused {
        if (_id > commitmentIDCount) {
            revert CommitmentNotExists(_id);
        }
        if (msg.value < PROTOCOL_JOIN_FEE) {
            revert InvalidJoinFee(msg.value, PROTOCOL_JOIN_FEE);
        }
        if (clients[_clientId].id > clientCount) {
            revert ClientNotExists(_clientId);
        }

        Commitment storage commitment = commitments[_id];

        if (commitment.info.status != CommitmentStatus.Active) {
            revert InvalidState(commitment.info.status);
        }

        if (block.timestamp >= commitment.info.joinDeadline) {
            revert JoiningPeriodEnded(
                block.timestamp,
                commitment.info.joinDeadline
            );
        }

        protocolFees[address(0)] += PROTOCOL_JOIN_FEE;

        uint256 totalAmount = commitment.info.stakeAmount;

        // Handle creator fee if set
        uint256 creatorFee = commitment.info.creatorFee;
        if (creatorFee > 0) {
            totalAmount += creatorFee;

            uint256 protocolEarnings = (creatorFee * PROTOCOL_SHARE) /
                BASIS_POINTS;

            // Update accumulated token fees
            protocolFees[commitment.info.tokenAddress] += protocolEarnings;
            commitment.claims.creatorClaim += creatorFee - protocolEarnings;
        }

        uint256 clientShare = (commitment.info.stakeAmount *
            clients[_clientId].clientFeeShare) / BASIS_POINTS;
        // Transfer total amount in one transaction

        if (commitment.info.tokenAddress == address(0)) {
            if (
                msg.value - PROTOCOL_JOIN_FEE - clientShare !=
                commitment.info.stakeAmount
            ) {
                revert InvalidStakeAmount();
            }
            if (clientShare > 0) {
                (bool success, ) = clients[_clientId]
                    .clientWithdrawAddress
                    .call{value: clientShare}("");
                if (!success) {
                    revert NativeTokenTransferFailed();
                }
            }
        } else {
            // Transfer total amount in one transaction
            IERC20(commitment.info.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
            if (clientShare > 0) {
                IERC20(commitment.info.tokenAddress).transferFrom(
                    msg.sender,
                    clients[_clientId].clientWithdrawAddress,
                    clientShare
                );
            }
        }

        uint256 tokenId = (commitment.info.id << 128) +
            ++commitmentTokenCount[_id];

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
        if (commitments[_id].info.status == CommitmentStatus.Resolved) {
            revert CommitmentAlreadyResolved();
        }
        commitments[_id].claims.root = _root;
        _resolveCommitment(_id, _leavesCount);
    }

    /// @notice Resolves commitment using disperse contract for reward distribution
    /// @param _id The ID of the commitment to resolve
    /// @param _winnerCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function resolveCommitmentDisperse(
        uint256 _id,
        uint256 _winnerCount
    ) external nonReentrant whenNotPaused {
        if (commitments[_id].info.status == CommitmentStatus.Resolved) {
            revert CommitmentAlreadyResolved();
        }
        _resolveCommitment(_id, _winnerCount);
        if (commitments[_id].info.tokenAddress != address(0)) {
            IERC20(commitments[_id].info.tokenAddress).approve(
                disperseContract,
                type(uint256).max
            );
        } else {
            (bool success, ) = disperseContract.call{
                value: commitments[_id].info.stakeAmount *
                    commitmentTokenCount[_id]
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
        if (_id >= commitmentIDCount) {
            revert CommitmentDoesNotExist();
        }

        Commitment storage commitment = commitments[_id];

        if (msg.sender != commitment.info.creator && msg.sender != owner()) {
            revert OnlyCreatorOrOwnerCanCancel();
        }

        if (commitment.info.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        commitment.info.joinDeadline = 0;
        commitment.info.fulfillmentDeadline = 0;

        commitment.info.status = CommitmentStatus.Cancelled;

        emit CommitmentCancelled(_id, msg.sender);
    }

    /// @notice Claims participant stake after emergency cancellation
    /// @dev No protocol fees are assessed however join fees are non-refundable
    /// @param _tokenId The nft ID to claim stake from
    function claimCancelled(
        uint256 _tokenId
    ) external nonReentrant whenNotPaused {
        uint256 _id = _tokenId >> 128;

        CommitmentInfo memory commitment = commitments[_id].info;

        if (commitment.status != CommitmentStatus.Cancelled) {
            revert CommitmentNotCancelled();
        }

        if (commitments[_id].participants.nftsClaimed[_tokenId]) {
            revert AlreadyClaimed();
        }

        if (_tokenId - (_id << 128) != commitmentTokenCount[_id]) {
            revert InvalidTokenId();
        }

        if (ownerOf(_tokenId) != msg.sender) {
            revert NotAParticipant();
        }

        if (commitment.stakeAmount <= 0) {
            revert NoRewardsToClaim();
        }
        uint256 amount = commitment.stakeAmount;

        // Mark as claimed before transfer to prevent reentrancy
        commitments[_id].participants.nftsClaimed[_tokenId] = true;

        if (commitment.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) {
                revert NativeTokenTransferFailed();
            }
        } else {
            IERC20(commitment.tokenAddress).transfer(msg.sender, amount);
        }

        emit EmergencyStakesReturned(
            _id,
            msg.sender // Who initiated the return
        );
    }

    /// @notice Claims participant's rewards and stakes after commitment resolution
    /// @dev Winners can claim their original stake plus their share of rewards from failed stakes
    /// @dev Losers cannot claim anything as their stakes are distributed to winners
    /// @param _tokenId The commitment ID to claim rewards from
    /// @param _proof The merkle proof to verify winner status
    function claimRewards(
        uint256 _tokenId,
        bytes32[] calldata _proof
    ) external nonReentrant whenNotPaused {
        uint256 _id = _tokenId >> 128;

        Commitment storage commitment = commitments[_id];

        if (commitment.info.status != CommitmentStatus.Resolved) {
            revert CommitmentNotResolved();
        }

        if (ownerOf(_tokenId) != msg.sender) {
            revert NotAParticipant();
        }

        if (commitment.participants.nftsClaimed[_tokenId]) {
            revert AlreadyClaimed();
        }
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender)))
        );
        bool isValidWinner = MerkleProof.verify(
            _proof,
            commitment.claims.root,
            leaf
        );

        if (!isValidWinner) {
            revert InvalidWinner(msg.sender);
        }

        uint256 amount = commitment.claims.winnerClaim;
        if (amount <= 0) {
            revert NoRewardsToClaim();
        }

        // Mark as claimed before transfer to prevent reentrancy
        commitment.participants.nftsClaimed[_tokenId] = true;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) {
                revert NativeTokenTransferFailed();
            }
        } else {
            IERC20(commitment.info.tokenAddress).transfer(msg.sender, amount);
        }

        emit RewardsClaimed(
            _id,
            msg.sender,
            commitment.info.tokenAddress,
            amount
        );
    }

    /// @notice Claims creator's rewards
    /// @dev Creator can claim while the commitment is in progress
    /// @param _id The commitment ID to claim creator fees from
    function claimCreator(uint256 _id) external nonReentrant whenNotPaused {
        Commitment storage commitment = commitments[_id];

        if (commitment.info.creator != msg.sender) {
            revert OnlyCreatorCanClaim();
        }

        uint256 amount = commitment.claims.creatorClaim -
            commitment.claims.creatorClaimed;

        if (amount <= 0) {
            revert NoCreatorFeesToClaim();
        }

        // Update how much they have claimed to prevent reclaiming the same funds
        commitment.claims.creatorClaimed += amount;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) {
                revert NativeTokenTransferFailed();
            }
        } else {
            IERC20(commitment.info.tokenAddress).transfer(msg.sender, amount);
        }

        emit CreatorClaimed(
            _id,
            msg.sender,
            commitment.info.tokenAddress,
            amount
        );
    }

    /// @notice Allows public funding of a commitment
    /// @param _id The commitment ID to fund
    /// @param _amount The amount of tokens to fund
    function fund(uint256 _id, uint256 _amount) external payable {
        CommitmentInfo memory commitment = commitments[_id].info;
        if (commitment.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        if (commitment.tokenAddress == address(0)) {
            publicFunding[msg.sender][_id] += msg.value;
            commitment.funding += msg.value;
        } else {
            IERC20(commitment.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                _amount
            );
            publicFunding[msg.sender][_id] += _amount;
            commitment.funding += _amount;
        }
        commitments[_id].info = commitment;
    }

    /// @notice Allows removal of public funding from a commitment
    /// @param _id The commitment ID to remove funding from
    /// @param _amount The amount of tokens to remove
    function removeFunding(uint256 _id, uint256 _amount) external payable {
        CommitmentInfo memory commitment = commitments[_id].info;
        if (commitment.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }
        if (publicFunding[msg.sender][_id] < _amount) {
            revert InvalidFundingAmount();
        }
        commitment.funding -= _amount;
        if (commitment.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: _amount}("");
            if (!success) {
                revert NativeTokenTransferFailed();
            }
        } else {
            IERC20(commitment.tokenAddress).transfer(msg.sender, _amount);
        }
        commitments[_id].info = commitment;
        publicFunding[msg.sender][_id] -= _amount;
    }

    /// @notice Internal function to resolve a commitment and calculate winner rewards
    /// @param _id The commitment ID to resolve
    /// @param _winnerCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function _resolveCommitment(uint256 _id, uint256 _winnerCount) internal {
        Commitment storage commitment = commitments[_id];
        if (msg.sender != commitment.info.creator) {
            revert OnlyCreatorCanResolve();
        }

        if (commitment.info.status != CommitmentStatus.Active) {
            revert CommitmentNotActive();
        }

        // TODO: fix, insecure
        if (block.timestamp <= commitment.info.fulfillmentDeadline) {
            revert FulfillmentPeriodNotEnded(
                block.timestamp,
                commitment.info.fulfillmentDeadline
            );
        }
        // Process participants
        // Use local var to save gas so we dont have to read `commitment.failedCount` every time
        uint256 failedCount = commitmentTokenCount[_id] - _winnerCount;

        uint256 protocolStakeFee = (commitment.info.stakeAmount *
            PROTOCOL_SHARE) / BASIS_POINTS;

        // Protocol earns % of all commit stakes, won or lost
        protocolFees[commitment.info.tokenAddress] +=
            protocolStakeFee *
            commitmentTokenCount[_id];

        // Distribute stakes among winners, less protocol fees
        uint256 winnerStakeRefund = commitment.info.stakeAmount -
            protocolStakeFee;
        uint256 winnerStakeEarnings = ((commitment.info.stakeAmount -
            protocolStakeFee) *
            failedCount +
            commitment.info.funding) / _winnerCount;

        commitment.claims.winnerClaim = winnerStakeRefund + winnerStakeEarnings;

        // Mark commitment as resolved
        commitment.info.status = CommitmentStatus.Resolved;

        emit CommitmentResolved(_id, _winnerCount);
    }

    function addClient(
        address _client,
        address _clientWithdrawAddress,
        uint256 _clientFee
    ) external {
        clients[_client] = Client(
            ++clientCount,
            _client,
            _clientWithdrawAddress,
            _clientFee
        );
        emit ClientAdded(clientCount, _client);
    }

    function removeClient(address _client) external {
        if (clients[_client].clientAddress != msg.sender) {
            revert OnlyClientCanRemove();
        }
        delete clients[_client];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow a token for use in future commitments
    /// @param _token The address of the token
    function addAllowedToken(address _token) external onlyOwner {
        allowedTokens.add(_token);

        emit TokenListUpdated(_token, true);
    }

    /// @notice Prevent a token for use in future commitments
    /// @param _token The address of the token
    function removeAllowedToken(address _token) external onlyOwner {
        allowedTokens.remove(_token);

        emit TokenListUpdated(_token, false);
    }

    /// @notice Updates the protocol fee address
    /// @param _newAddress The new address for protocol fees
    function setProtocolFeeAddress(address _newAddress) external onlyOwner {
        if (_newAddress == address(0)) {
            revert InvalidProtocolFeeAddress();
        }

        address oldAddress = protocolFeeAddress;
        protocolFeeAddress = _newAddress;

        emit ProtocolFeeAddressUpdated(oldAddress, _newAddress);
    }

    /// @notice Claims accumulated fees for a specific token. Used by protocol owner to withdraw their fees
    /// @param _token The address of the token to claim fees for
    /// @dev Protocol owner claims via protocolFeeAddress
    /// @dev Protocol fees come from join fees (PROTOCOL_SHARE%) and stakes (PROTOCOL_SHARE%)
    /// @dev Creator fees come from creatorFee (optional commitment join fee)
    function claimProtocolFees(address _token) external onlyOwner nonReentrant {
        uint256 amount = protocolFees[_token];

        if (amount == 0) {
            revert NoFeesToClaim();
        }

        // Clear balance before transfer to prevent reentrancy
        protocolFees[_token] = 0;

        if (_token == address(0)) {
            // Transfer creation fee in ETH
            (bool sent, ) = protocolFeeAddress.call{value: amount}("");
            if (!sent) {
                revert NativeTokenTransferFailed();
            }
        } else {
            // Transfer accumulated fees
            IERC20(_token).transfer(msg.sender, amount);
        }

        emit FeesClaimed(msg.sender, _token, amount);
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
    function emergencyWithdrawToken(
        IERC20 _token,
        uint256 _amount
    ) external onlyOwner {
        uint256 balance = _token.balanceOf(address(this));
        if (_amount == 0 || _amount > balance) {
            revert InvalidWithdrawalAmount();
        }
        _token.transfer(owner(), _amount);

        emit EmergencyWithdrawal(address(_token), _amount);
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

    /// @notice Gets the details of a commitment
    /// @param _id The ID of the commitment
    /// @return The commitment info struct
    function getCommitmentDetails(
        uint256 _id
    ) external view returns (CommitmentInfo memory) {
        return commitments[_id].info;
    }

    /// @notice Gets the claims info for a commitment
    /// @param _id The ID of the commitment
    /// @return The claims struct containing reward distribution info
    function getClaims(uint256 _id) external view returns (Claims memory) {
        return commitments[_id].claims;
    }

    /// @notice Checks if a participant has claimed their rewards/refund for a given token ID
    /// @param _tokenId The NFT ID
    /// @return True if participant has claimed, false otherwise
    function isParticipantClaimed(uint256 _tokenId) public view returns (bool) {
        return commitments[_tokenId >> 128].participants.nftsClaimed[_tokenId];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates an address is not zero
    /// @param _addr The address to validate
    function _validateAddress(address _addr) internal pure {
        if (_addr == address(0)) {
            revert InvalidAddress();
        }
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param _newImplementation The address of the new implementation
    /// @dev Only owner can upgrade the contract
    function _authorizeUpgrade(
        address _newImplementation
    ) internal view override onlyOwner {
        if (_newImplementation == address(0)) {
            revert InvalidImplementationAddress();
        }
    }

    /// @notice Returns the metadata URI for a given token ID
    /// @param _id The token ID to get the URI for
    /// @return The metadata URI string
    function tokenURI(
        uint256 _id
    ) public view override returns (string memory) {
        return commitments[_id >> 128].info.metadataURI;
    }

    /// @notice Updates the metadata URI for a commitment
    /// @param _id The commitment ID to update
    /// @param _uri The new metadata URI
    function updateMetadataURI(uint256 _id, string memory _uri) public {
        if (
            msg.sender != commitments[_id].info.creator && msg.sender != owner()
        ) {
            revert OnlyCreatorOrOwnerCanUpdateURI();
        }
        commitments[_id].info.metadataURI = _uri;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevents accidental ETH transfers to contract
    receive() external payable {
        revert DirectDepositsNotAllowed();
    }
}
