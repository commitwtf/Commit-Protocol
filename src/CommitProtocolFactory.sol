// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CommitProtocol} from "./CommitProtocol.sol";
import {CommitmentInfo} from "./storage.sol";

import "./errors.sol";
import "./logger.sol";

/// @title CommitProtocolFactory - Factory contract for deploying CommitProtocol instances
/// @notice Enables users to create new commitment-based challenges by deploying proxy contracts
/// @dev Implements proxy deployment, token allowlist, and emergency controls
/// @author Rachit Anand Srivastava (@privacy_prophet)
contract CommitProtocolFactory is ReentrancyGuard, Ownable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public implementation;
    uint256 public commitmentId;
    uint256 public protocolFee;
    address payable public protocolFeeAddress;
    uint256 public constant PROTOCOL_CREATE_FEE = 0.001 ether;
    EnumerableSet.AddressSet internal allowedTokens;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the factory with an implementation contract
    /// @param _implementation The address of the implementation contract to clone
    constructor(address _implementation) Ownable(msg.sender) {
        if (_implementation == address(0)) revert InvalidImplementation();
        implementation = _implementation;
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new commitment by deploying a proxy contract
    /// @param _tokenAddress The ERC20 token used for staking (address(0) for ETH)
    /// @param _disperseContract The contract used for distributing rewards
    /// @param _stakeAmount The amount each participant must stake
    /// @param _creatorFee Additional fee required to join (set by creator)
    /// @param _description Description of the commitment requirements
    /// @param _joinDeadline Timestamp when joining period ends
    /// @param _fulfillmentDeadline Timestamp when commitment period ends
    /// @param _metadataURI URI pointing to commitment metadata
    /// @dev Deploys proxy, initializes it, and handles creator's stake
    function createCommitment(
        address _tokenAddress,
        address _disperseContract,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        bytes calldata _description,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline,
        string calldata _metadataURI
    ) external payable nonReentrant whenNotPaused {
        if (msg.value < PROTOCOL_CREATE_FEE) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }

        if (_tokenAddress == address(0)) {
            _stakeAmount = msg.value - PROTOCOL_CREATE_FEE;
        }

        if (_stakeAmount == 0) revert InvalidStakeAmount();
        if (!allowedTokens.contains(_tokenAddress)) {
            revert TokenNotAllowed(_tokenAddress);
        }

        protocolFee += PROTOCOL_CREATE_FEE;

        CommitmentInfo memory commitmentInfo = CommitmentInfo({
            id: ++commitmentId,
            creator: msg.sender,
            tokenAddress: _tokenAddress,
            stakeAmount: _stakeAmount,
            creatorFee: _creatorFee,
            description: _description,
            joinDeadline: _joinDeadline,
            fulfillmentDeadline: _fulfillmentDeadline,
            metadataURI: _metadataURI,
            status: CommitmentStatus.Active
        });

        bytes memory initData = abi.encodeWithSignature(
            "initialize((uint256,address,address,uint256,uint256,bytes,uint256,uint256,string,uint8),address,address)",
            commitmentInfo,
            _disperseContract,
            protocolFeeAddress
        );

        address proxy = Clones.clone(implementation);
        (bool success,) = proxy.call(initData);
        if (!success) revert InitializationFailed();

        IERC20(_tokenAddress).transferFrom(msg.sender, proxy, _stakeAmount);
    }

    /// @notice Adds a token to the allowlist for use in commitments
    /// @param token The token contract address to allow
    function addAllowedToken(address token) external onlyOwner {
        allowedTokens.add(token);
        emit TokenListUpdated(token, true);
    }

    /// @notice Sets the address that receives protocol fees
    /// @param _protocolFeeAddress The address to receive fees
    function setProtocolFeeAddress(address payable _protocolFeeAddress) external onlyOwner {
        protocolFeeAddress = _protocolFeeAddress;
    }

    /// @notice Updates the implementation contract for future deployments
    /// @param _implementation The new implementation contract address
    function updateImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert InvalidImplementation();
        implementation = _implementation;
    }

    /// @notice Removes a token from the allowlist
    /// @param token The token contract address to disallow
    function removeAllowedToken(address token) external onlyOwner {
        allowedTokens.remove(token);
        emit TokenListUpdated(token, false);
    }

    /// @notice Pauses core contract functionality
    function emergencyPauseAll() external onlyOwner {
        _pause();
        emit ContractPaused();
    }

    /// @notice Resumes core contract functionality
    function emergencyUnpauseAll() external onlyOwner {
        _unpause();
        emit ContractUnpaused();
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevents accidental ETH transfers to contract
    receive() external payable {
        revert DirectDepositsNotAllowed();
    }
}
