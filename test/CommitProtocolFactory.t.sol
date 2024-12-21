// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CommitProtocolFactory} from "../src/CommitProtocolFactory.sol";
import {CommitProtocol} from "../src/CommitProtocol.sol";
import {TestToken as MockERC20} from "./TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CommitProtocolFactoryTest is Test {
    CommitProtocolFactory public factory;
    CommitProtocol public implementationContract;
    MockERC20 public testToken;

    address public owner;
    address public creator;
    address public disperseContract;
    address public protocolFeeAddress;

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        disperseContract = makeAddr("disperseContract");
        protocolFeeAddress = makeAddr("protocolFeeAddress");

        vm.startPrank(owner);

        // Deploy mock implementation contract
        implementationContract = new CommitProtocol();

        // Deploy factory
        factory = new CommitProtocolFactory(address(implementationContract));

        // Deploy test token
        testToken = new MockERC20();

        // Add token to allowlist
        factory.addAllowedToken(address(testToken));

        // Set protocol fee address
        factory.setProtocolFeeAddress(payable(protocolFeeAddress));

        vm.stopPrank();
    }

    // Test creation of commitment with valid parameters
    function testCreateCommitment() public {
        // Prepare creator with tokens and approve factory
        vm.startPrank(creator);
        testToken.deal(100 ether);
        testToken.approve(address(factory), 10 ether);

        // Set up commitment parameters
        uint256 stakeAmount = 10 ether;
        uint256 creatorFee = 1 ether;
        bytes memory description = "Test Commitment";
        uint256 joinDeadline = block.timestamp + 1 weeks;
        uint256 fulfillmentDeadline = block.timestamp + 2 weeks;
        string memory metadataURI = "https://example.com/metadata";

        // Send protocol fee
        vm.deal(creator, 1 ether);

        // Create commitment
        factory.createCommitment{value: 0.001 ether}(
            address(testToken),
            disperseContract,
            stakeAmount,
            creatorFee,
            description,
            joinDeadline,
            fulfillmentDeadline,
            metadataURI
        );

        vm.stopPrank();

        assertEq(factory.commitmentId(), 1);
    }

    // Test creating commitment with invalid protocol fee
    function testCreateCommitmentInvalidFee() public {
        vm.startPrank(creator);
        testToken.deal(100 ether);
        testToken.approve(address(factory), 10 ether);

        vm.expectRevert(
            abi.encodeWithSignature(
                "InvalidCreationFee(uint256,uint256)",
                0,
                0.001 ether
            )
        );
        factory.createCommitment{value: 0}(
            address(testToken),
            disperseContract,
            10 ether,
            1 ether,
            "Test",
            block.timestamp + 1 weeks,
            block.timestamp + 2 weeks,
            "https://example.com/metadata"
        );

        vm.stopPrank();
    }

    // Test adding and removing allowed tokens
    function testAddRemoveAllowedToken() public {
        vm.startPrank(owner);

        // Create new token
        MockERC20 newToken = new MockERC20();

        // Add token
        factory.addAllowedToken(address(newToken));

        // Remove token
        factory.removeAllowedToken(address(newToken));

        vm.stopPrank();
    }

    // Test emergency pause and unpause
    function testEmergencyPauseUnpause() public {
        vm.startPrank(owner);

        // Pause
        factory.emergencyPauseAll();

        // Try to create commitment (should fail)
        vm.startPrank(creator);
        testToken.deal(100 ether);
        testToken.approve(address(factory), 10 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        factory.createCommitment(
            address(testToken),
            disperseContract,
            10 ether,
            1 ether,
            "Test",
            block.timestamp + 1 weeks,
            block.timestamp + 2 weeks,
            "https://example.com/metadata"
        );

        // Unpause as owner
        vm.startPrank(owner);
        factory.emergencyUnpauseAll();

        // Now creation should work
        vm.startPrank(creator);
        vm.deal(creator, 0.001 ether);
        factory.createCommitment{value: 0.001 ether}(
            address(testToken),
            disperseContract,
            10 ether,
            1 ether,
            "Test",
            block.timestamp + 1 weeks,
            block.timestamp + 2 weeks,
            "https://example.com/metadata"
        );

        vm.stopPrank();
    }

    // Test update implementation
    function testUpdateImplementation() public {
        vm.startPrank(owner);

        CommitProtocol newImplementation = new CommitProtocol();
        factory.updateImplementation(address(newImplementation));

        assertEq(factory.implementation(), address(newImplementation));

        vm.stopPrank();
    }
}
