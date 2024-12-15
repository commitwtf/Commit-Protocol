// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommitProtocol} from "./CommitProtocol.sol";
import "./errors.sol";
import "./logger.sol";
/// @title CommitProtocol — an onchain accountability protocol
/// @notice Enables users to create and participate in commitment-based challenges
/// @dev Implements stake management, fee distribution, and emergency controls
/// @author Rachit Anand Srivastava (@privacy_prophet)

contract CommitProtocolFactory is ReentrancyGuard, Ownable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public implementation;
    uint256 public commitmentId;
    uint256 public protocolFee;
    address payable public protocolFeeAddress;
    uint256 public constant PROTOCOL_CREATE_FEE = 0.001 ether; // Fixed ETH fee for creating
    EnumerableSet.AddressSet internal allowedTokens;

    address[] public commitments;
    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @param _implementation The address of the implementation contract
    constructor(address _implementation) Ownable(msg.sender) {
        require(
            _implementation != address(0),
            "Invalid implementation address"
        );
        implementation = _implementation;
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
        address _disperseContract,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        bytes calldata _description,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline,
        string calldata _metadataURI
    ) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.value != protocolFee) {
            revert InvalidCreationFee(msg.value, PROTOCOL_CREATE_FEE);
        }

        if (_tokenAddress == address(0)) {
            _stakeAmount = msg.value - PROTOCOL_CREATE_FEE;
        }

        if (_stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        require(allowedTokens.contains(_tokenAddress), "Token not allowed");

        protocolFee += PROTOCOL_CREATE_FEE;

        bytes memory initData = abi.encodeWithSignature(
            "initialize(uint256,address,address,address,address,uint256,uint256,bytes,uint256,uint256,string)",
            ++commitmentId,
            _disperseContract,
            msg.sender,
            _tokenAddress,
            _stakeAmount,
            _creatorFee,
            _description,
            _joinDeadline,
            _fulfillmentDeadline,
            _metadataURI
        );

        address proxy = address(new ERC1967Proxy(implementation, initData));
        commitments.push(proxy);
        CommitProtocol(payable(proxy)).setProtocolFeeAddress(
            protocolFeeAddress
        );

        // Transfer stake amount for creator
        IERC20(_tokenAddress).transferFrom(
            msg.sender,
            address(proxy),
            _stakeAmount
        );
    }

    /// @notice Allow a token for use in future commitments
    /// @param token The address of the token
    function addAllowedToken(address token) external onlyOwner {
        allowedTokens.add(token);

        emit TokenListUpdated(token, true);
    }

    function setProtocolFeeAddress(
        address payable _protocolFeeAddress
    ) external onlyOwner {
        protocolFeeAddress = _protocolFeeAddress;
    }

    function updateImplementation(address _implementation) external onlyOwner {
        implementation = _implementation;
    }

    /// @notice Prevent a token for use in future commitments
    /// @param token The address of the token
    function removeAllowedToken(address token) external onlyOwner {
        allowedTokens.remove(token);

        emit TokenListUpdated(token, false);
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
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevents accidental ETH transfers to contract
    receive() external payable {
        require(false, "Direct deposits not allowed");
    }
}
