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

    uint256 constant STAKE_AMOUNT = 10 ether;
    uint256 constant CREATOR_FEE = 1 ether;
    uint256 constant INITIAL_BALANCE = 100 ether;
    uint256 constant JOIN_PERIOD = 1 weeks;
    uint256 constant FULFILLMENT_PERIOD = 2 weeks;
    uint256 constant PROTOCOL_CREATE_FEE = 0.001 ether;

    bytes constant DESCRIPTION = "Test Commitment";
    string constant METADATA_URI = "https://example.com/metadata";

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        disperseContract = makeAddr("disperseContract");
        protocolFeeAddress = makeAddr("protocolFeeAddress");

        vm.startPrank(owner);

        implementationContract = new CommitProtocol();
        factory = new CommitProtocolFactory(address(implementationContract));
        testToken = new MockERC20();

        factory.addAllowedToken(address(testToken));
        factory.setProtocolFeeAddress(payable(protocolFeeAddress));

        vm.stopPrank();
    }

    function testCreateCommitment() public {
        vm.startPrank(creator);
        testToken.deal(INITIAL_BALANCE);
        testToken.approve(address(factory), STAKE_AMOUNT);

        vm.deal(creator, PROTOCOL_CREATE_FEE);

        factory.createCommitment{value: PROTOCOL_CREATE_FEE}(
            address(testToken),
            disperseContract,
            STAKE_AMOUNT,
            CREATOR_FEE,
            DESCRIPTION,
            block.timestamp + JOIN_PERIOD,
            block.timestamp + FULFILLMENT_PERIOD,
            METADATA_URI
        );

        vm.stopPrank();

        assertEq(factory.commitmentId(), 1);
    }

    function testCreateCommitmentInvalidFee() public {
        vm.startPrank(creator);
        testToken.deal(INITIAL_BALANCE);
        testToken.approve(address(factory), STAKE_AMOUNT);

        vm.expectRevert(abi.encodeWithSignature("InvalidCreationFee(uint256,uint256)", 0, PROTOCOL_CREATE_FEE));
        factory.createCommitment{value: 0}(
            address(testToken),
            disperseContract,
            STAKE_AMOUNT,
            CREATOR_FEE,
            DESCRIPTION,
            block.timestamp + JOIN_PERIOD,
            block.timestamp + FULFILLMENT_PERIOD,
            METADATA_URI
        );

        vm.stopPrank();
    }

    function testAddRemoveAllowedToken() public {
        vm.startPrank(owner);

        MockERC20 newToken = new MockERC20();
        factory.addAllowedToken(address(newToken));
        factory.removeAllowedToken(address(newToken));

        vm.stopPrank();
    }

    function testEmergencyPauseUnpause() public {
        vm.startPrank(owner);
        factory.emergencyPauseAll();

        vm.startPrank(creator);
        testToken.deal(INITIAL_BALANCE);
        testToken.approve(address(factory), STAKE_AMOUNT);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        factory.createCommitment(
            address(testToken),
            disperseContract,
            STAKE_AMOUNT,
            CREATOR_FEE,
            DESCRIPTION,
            block.timestamp + JOIN_PERIOD,
            block.timestamp + FULFILLMENT_PERIOD,
            METADATA_URI
        );

        vm.startPrank(owner);
        factory.emergencyUnpauseAll();

        vm.startPrank(creator);
        vm.deal(creator, PROTOCOL_CREATE_FEE);
        factory.createCommitment{value: PROTOCOL_CREATE_FEE}(
            address(testToken),
            disperseContract,
            STAKE_AMOUNT,
            CREATOR_FEE,
            DESCRIPTION,
            block.timestamp + JOIN_PERIOD,
            block.timestamp + FULFILLMENT_PERIOD,
            METADATA_URI
        );

        vm.stopPrank();
    }

    function testUpdateImplementation() public {
        vm.startPrank(owner);

        CommitProtocol newImplementation = new CommitProtocol();
        factory.updateImplementation(address(newImplementation));

        assertEq(factory.implementation(), address(newImplementation));

        vm.stopPrank();
    }
}
