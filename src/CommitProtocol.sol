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
/// @custom:co-author Carlo Miguel Dy (@carlomigueldy)
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
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Modifier to validate the creation fee.
     * @param value The value to be checked against the protocol creation fee.
     * Requirements:
     * - `value` must be greater than or equal to `PROTOCOL_CREATE_FEE`.
     * Reverts with `InvalidCreationFee` if the requirement is not met.
     */
    modifier validCreationFee(uint256 value) {
        require(
            value >= PROTOCOL_CREATE_FEE,
            InvalidCreationFee(value, PROTOCOL_CREATE_FEE)
        );
        _;
    }

    /**
     * @dev Modifier to check if a token is allowed.
     * @param _tokenAddress The address of the token to check.
     * Reverts with a `TokenNotAllowed` error if the token is not allowed.
     */
    modifier allowedToken(address _tokenAddress) {
        require(
            allowedTokens.contains(_tokenAddress),
            TokenNotAllowed(_tokenAddress)
        );
        _;
    }

    /**
     * @dev Modifier to validate the length of a description.
     * Reverts if the description length exceeds the maximum allowed length.
     * @param _description The description to be validated.
     */
    modifier validDescription(bytes calldata _description) {
        require(
            _description.length <= MAX_DESCRIPTION_LENGTH,
            DescriptionTooLong()
        );
        _;
    }

    /**
     * @dev Modifier to validate that the join deadline is in the future.
     * @param _joinDeadline The timestamp of the join deadline to be validated.
     * Reverts with `JoinDealineTooEarly` if the join deadline is not in the future.
     */
    modifier validJoinDeadline(uint256 _joinDeadline) {
        require(_joinDeadline > block.timestamp, JoinDealineTooEarly());
        _;
    }

    /**
     * @dev Modifier to validate the fulfillment deadline.
     * @param _joinDeadline The deadline for joining.
     * @param _fulfillmentDeadline The deadline for fulfillment.
     * Requirements:
     * - `_fulfillmentDeadline` must be greater than `_joinDeadline`.
     * - `_fulfillmentDeadline` must be less than or equal to the current block timestamp plus the maximum deadline duration.
     * Reverts with `InvalidFullfillmentDeadline` if the conditions are not met.
     */
    modifier validFulfillmentDeadline(
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline
    ) {
        require(
            _fulfillmentDeadline > _joinDeadline &&
                _fulfillmentDeadline <= block.timestamp + MAX_DEADLINE_DURATION,
            InvalidFullfillmentDeadline()
        );
        _;
    }

    /**
     * @dev Modifier to validate that the stake amount is not zero.
     * @param _stakeAmount The amount of stake to be validated.
     * Reverts with `InvalidStakeAmount` if `_stakeAmount` is zero.
     */
    modifier validStakeAmount(uint256 _stakeAmount) {
        require(_stakeAmount != 0, InvalidStakeAmount());
        _;
    }

    /**
     * @dev Modifier to check if a commitment is active.
     * @param _id The ID of the commitment to check.
     * Reverts with CommitmentNotActive error if the commitment is not active.
     */
    modifier isCommitmentActive(uint256 _id) {
        require(
            commitments[_id].info.status == CommitmentStatus.Active,
            CommitmentNotActive()
        );
        _;
    }

    /**
     * @dev Modifier to check if a commitment has not been resolved.
     * @param _id The ID of the commitment to check.
     * Reverts with CommitmentAlreadyResolved if the commitment status is Resolved.
     */
    modifier isCommitmentNotResolved(uint256 _id) {
        require(
            commitments[_id].info.status != CommitmentStatus.Resolved,
            CommitmentAlreadyResolved()
        );
        _;
    }

    /**
     * @dev Modifier to check if a commitment with the given ID exists.
     * @param _id The ID of the commitment to check.
     * Requirements:
     * - The commitment ID must be less than or equal to the current commitment ID count.
     * Reverts with a CommitmentNotExists error if the commitment does not exist.
     */
    modifier commitmentExists(uint256 _id) {
        require(_id <= commitmentIDCount, CommitmentNotExists(_id));
        _;
    }

    /**
     * @dev Modifier to validate the join fee.
     * @param value The fee value to be validated.
     * Requirements:
     * - `value` must be greater than or equal to `PROTOCOL_JOIN_FEE`.
     * Reverts with `InvalidJoinFee` error if the requirement is not met.
     */
    modifier validJoinFee(uint256 value) {
        require(
            value >= PROTOCOL_JOIN_FEE,
            InvalidJoinFee(value, PROTOCOL_JOIN_FEE)
        );
        _;
    }

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

        require(_protocolFeeAddress != address(0), InvalidAddress());

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
        string calldata _metadataURI
    )
        external
        payable
        nonReentrant
        whenNotPaused
        validCreationFee(msg.value)
        allowedToken(_tokenAddress)
        validDescription(_description)
        validJoinDeadline(_joinDeadline)
        validFulfillmentDeadline(_joinDeadline, _fulfillmentDeadline)
        validStakeAmount(_stakeAmount)
        returns (uint256)
    {
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
    )
        external
        payable
        nonReentrant
        whenNotPaused
        validCreationFee(msg.value)
        validDescription(_description)
        validJoinDeadline(_joinDeadline)
        validFulfillmentDeadline(_joinDeadline, _fulfillmentDeadline)
        validStakeAmount(msg.value - PROTOCOL_CREATE_FEE)
        returns (uint256)
    {
        protocolFees[address(0)] += PROTOCOL_CREATE_FEE;

        uint256 commitmentId = ++commitmentIDCount;
        uint256 stakeAmount = msg.value - PROTOCOL_CREATE_FEE;

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
        uint256 _id
    )
        external
        payable
        nonReentrant
        whenNotPaused
        commitmentExists(_id)
        validJoinFee(msg.value)
    {
        Commitment storage commitment = commitments[_id];

        require(
            commitment.info.status == CommitmentStatus.Active,
            InvalidState(commitment.info.status)
        );
        require(
            block.timestamp < commitment.info.joinDeadline,
            JoiningPeriodEnded(block.timestamp, commitment.info.joinDeadline)
        );

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

        // Transfer total amount in one transaction

        if (commitment.info.tokenAddress == address(0)) {
            require(
                msg.value - PROTOCOL_JOIN_FEE == commitment.info.stakeAmount,
                InvalidStakeAmountNative()
            );
        } else {
            // Transfer total amount in one transaction
            IERC20(commitment.info.tokenAddress).transferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
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
    )
        public
        nonReentrant
        whenNotPaused
        commitmentExists(_id)
        isCommitmentNotResolved(_id)
    {
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
    )
        external
        nonReentrant
        whenNotPaused
        commitmentExists(_id)
        isCommitmentNotResolved(_id)
    {
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
            require(success, DisperseCallFailed());
        }
    }

    /// @notice Allows creator or owner to cancel a commitment before anyone else joins
    /// @param _id The ID of the commitment to cancel
    /// @dev This calls resolveCommitment internally to handle refunds properly
    /// @dev Requires exactly 1 participant (the creator) since creator auto-joins on creation
    function cancelCommitment(
        uint256 _id
    ) external whenNotPaused commitmentExists(_id) isCommitmentActive(_id) {
        Commitment storage commitment = commitments[_id];

        require(
            msg.sender == commitment.info.creator || msg.sender == owner(),
            OnlyCreatorOrOwnerCanCancel()
        );

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

        require(
            commitment.status == CommitmentStatus.Cancelled,
            CommitmentNotCancelled()
        );
        require(
            !commitments[_id].participants.nftsClaimed[_tokenId],
            AlreadyClaimed()
        );
        require(
            _tokenId - (_id << 128) == commitmentTokenCount[_id],
            InvalidTokenId()
        );
        require(ownerOf(_tokenId) == msg.sender, NotAParticipant());
        require(commitment.stakeAmount > 0, NoRewardsToClaim());

        uint256 amount = commitment.stakeAmount;

        // Mark as claimed before transfer to prerror reentrancy
        commitments[_id].participants.nftsClaimed[_tokenId] = true;

        if (commitment.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, NativeTokenTransferFailed());
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

        require(
            commitment.info.status == CommitmentStatus.Resolved,
            CommitmentNotResolved()
        );
        require(ownerOf(_tokenId) == msg.sender, NotAParticipant());
        require(
            !commitment.participants.nftsClaimed[_tokenId],
            AlreadyClaimed()
        );

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender)))
        );
        bool isValidWinner = MerkleProof.verify(
            _proof,
            commitment.claims.root,
            leaf
        );
        require(isValidWinner, InvalidWinner(msg.sender));

        uint256 amount = commitment.claims.winnerClaim;
        require(amount > 0, NoRewardsToClaim());

        // Mark as claimed before transfer to prevent reentrancy
        commitment.participants.nftsClaimed[_tokenId] = true;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, NativeTokenTransferFailed());
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

        require(commitment.info.creator == msg.sender, OnlyCreatorCanClaim());

        uint256 amount = commitment.claims.creatorClaim -
            commitment.claims.creatorClaimed;
        require(amount > 0, NoCreatorFeesToClaim());

        // Update how much they have claimed to prevent reclaiming the same funds
        commitment.claims.creatorClaimed += amount;

        if (commitment.info.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, NativeTokenTransferFailed());
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

    function fund(
        uint256 _id,
        uint256 _amount
    ) external payable isCommitmentActive(_id) {
        CommitmentInfo memory commitment = commitments[_id].info;

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

        emit CommitmentFunded(_id, msg.sender, _amount);
    }

    function removeFunding(
        uint256 _id,
        uint256 _amount
    ) external payable isCommitmentActive(_id) {
        CommitmentInfo memory commitment = commitments[_id].info;

        require(
            publicFunding[msg.sender][_id] >= _amount,
            InvalidFundingAmount()
        );
        commitment.funding -= _amount;

        if (commitment.tokenAddress == address(0)) {
            (bool success, ) = msg.sender.call{value: _amount}("");
            require(success, NativeTokenTransferFailed());
        } else {
            IERC20(commitment.tokenAddress).transfer(msg.sender, _amount);
        }

        commitments[_id].info = commitment;
        publicFunding[msg.sender][_id] -= _amount;

        emit CommitmentFundingRemoved(_id, msg.sender, _amount);
    }

    /// @notice Internal function to resolve a commitment and calculate winner rewards
    /// @param _id The commitment ID to resolve
    /// @param _winnerCount The number of successful participants
    /// @dev Only creator can resolve, must be after fulfillment deadline
    function _resolveCommitment(
        uint256 _id,
        uint256 _winnerCount
    ) internal isCommitmentActive(_id) {
        Commitment storage commitment = commitments[_id];
        require(msg.sender == commitment.info.creator, OnlyCreatorCanResolve());
        require(
            block.timestamp > commitment.info.fulfillmentDeadline,
            FulfillmentPeriodNotEnded(
                block.timestamp,
                commitment.info.fulfillmentDeadline
            )
        ); // TODO: <@rac-sri> fix, insecure

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
        require(_newAddress != address(0), InvalidAddress());

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

        require(amount > 0, NoProtocolFeesToClaim());

        // Clear balance before transfer to prevent reentrancy
        protocolFees[_token] = 0;

        if (_token == address(0)) {
            // Transfer creation fee in ETH
            (bool sent, ) = protocolFeeAddress.call{value: amount}("");
            require(sent, NativeTokenTransferFailed());
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
        require(_amount > 0 && _amount <= balance, InvalidWithdrawalAmount());

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
        require(_addr != address(0), InvalidAddress());
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param _newImplementation The address of the new implementation
    /// @dev Only owner can upgrade the contract
    function _authorizeUpgrade(
        address _newImplementation
    ) internal view override onlyOwner {
        require(_newImplementation != address(0), InvalidAddress());
    }

    function tokenURI(
        uint256 _id
    ) public view override returns (string memory) {
        return commitments[_id >> 128].info.metadataURI;
    }

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
        require(false, "Direct deposits not allowed");
    }
}
