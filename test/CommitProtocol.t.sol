// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {CommitProtocolV03} from "../src/CommitProtocolV03.sol";
import {TestToken} from "./TestToken.sol";
import "forge-std/console2.sol";

contract CommitTest is Test {
    CommitProtocolV03 private protocol;
    TestToken private token;

    address userA = 0x0000000000000000000000000000000000000001;
    address userB = 0x0000000000000000000000000000000000000002;
    address userC = 0x0000000000000000000000000000000000000003;
    address userD = 0x0000000000000000000000000000000000000004;

    function setUp() public {
        protocol = new CommitProtocolV03();
        token = new TestToken();
        protocol.initialize(address(this));
        protocol.addAllowedToken(address(token));
        vm.deal(userA, 100 ether);
        vm.deal(userB, 100 ether);
        vm.deal(userC, 100 ether);
        vm.deal(userD, 100 ether);
    }

    receive() external payable {}

    function create(
        address user,
        uint stakeAmount,
        uint creatorShare
    ) public returns (uint) {
        vm.deal(user, protocol.PROTOCOL_CREATE_FEE());
        vm.startPrank(user);
        token.deal(100);
        token.approve(address(protocol), type(uint256).max);
        uint id = protocol.createCommitment{
            value: protocol.PROTOCOL_CREATE_FEE()
        }(
            address(token), // _tokenAddress,
            stakeAmount, // _stakeAmount,
            creatorShare, // _creatorShare,
            "Test", // _description,
            block.timestamp + 1, // _joinDeadline,
            block.timestamp + 11 // _fulfillmentDeadline
        );
        vm.stopPrank();
        return id;
    }

    function join(
        uint commitmentId,
        address user,
        uint stakeAmount,
        uint joinFee
    ) public {
        vm.startPrank(user);
        token.deal(stakeAmount + joinFee);
        token.approve(address(protocol), type(uint256).max);
        protocol.joinCommitment{value: protocol.PROTOCOL_JOIN_FEE()}(
            commitmentId
        );
        vm.stopPrank();
    }

    function resolve(uint commitmentId, address[] memory winners) public {
        address creator = protocol.getCommitmentCreator(commitmentId);
        vm.startPrank(creator);
        protocol.resolveCommitment(commitmentId, winners);
        vm.stopPrank();
    }

    function test_Create() public {
        create(userA, 100, 10);
    }

    function test_Join() public {
        uint commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);
    }

    function test_RewardSingleClaim() public {
        uint commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);

        vm.warp(13);
        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId, winners);

        vm.startPrank(userB);
        uint balanceBBefore = token.balanceOf(userB);
        require(
            protocol.getCommitmentWinnerClaim(commitmentId) == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings
        protocol.claimRewards(commitmentId);
        uint balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 99),
            "Fee not credited"
        );
        vm.stopPrank();
    }

    function test_RewardMultiClaim() public {
        uint commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);
        join(commitmentId, userC, 100, 5);

        vm.warp(13);
        address[] memory winners = new address[](2);
        winners[0] = userB;
        winners[1] = userC;
        resolve(commitmentId, winners);

        vm.startPrank(userB);
        uint balanceBBefore = token.balanceOf(userB);
        require(
            protocol.getCommitmentWinnerClaim(commitmentId) == 99 + 49,
            "Invalid Reward"
        );
        protocol.claimRewards(commitmentId);
        uint balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 49),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function test_CreatorClaim() public {
        uint commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);

        vm.startPrank(userA);
        uint balanceBefore = token.balanceOf(userA);
        protocol.claimCreator(commitmentId);
        uint balanceAfter = token.balanceOf(userA);
        require(balanceAfter - balanceBefore == 5, "Fee not credited");
        vm.stopPrank();
    }

    function test_ProtocolFees() public {
        uint commitmentId = create(userA, 100, 10);
        join(commitmentId, userB, 100, 10);

        uint beforeFees = protocol.getProtocolFees(address(0));
        uint beforeBalance = address(this).balance;
        require(
            beforeFees ==
                protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );
        protocol.claimProtocolFees(address(0));
        uint afterFees = protocol.getProtocolFees(address(0));
        uint afterBalance = address(this).balance;
        require(afterFees == 0, "Fees not cleared");
        require(
            afterBalance - beforeBalance == beforeFees,
            "Balance not updated"
        );
    }

    function create_native(
        address user,
        uint stakeAmount,
        uint creatorShare
    ) public returns (uint) {
        vm.startPrank(user);

        uint id = protocol.createCommitmentNativeToken{
            value: protocol.PROTOCOL_CREATE_FEE() + stakeAmount
        }(
            creatorShare, // _creatorShare,
            "Test", // _description,
            block.timestamp + 1, // _joinDeadline,
            block.timestamp + 11 // _fulfillmentDeadline
        );
        vm.stopPrank();
        return id;
    }

    function join_native(
        uint commitmentId,
        address user,
        uint stakeAmount,
        uint joinFee
    ) public {
        vm.startPrank(user);
        protocol.joinCommitment{
            value: protocol.PROTOCOL_JOIN_FEE() + stakeAmount
        }(commitmentId);
        vm.stopPrank();
    }

    function test_Create_native() public {
        create_native(userA, 100, 10);
    }

    function test_Join_native() public {
        uint commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100, 5);
    }

    function test_RewardSingleClaim_native() public {
        uint commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100, 5);

        vm.warp(13);
        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId, winners);

        vm.startPrank(userB);
        uint balanceBBefore = userB.balance;
        require(
            protocol.getCommitmentWinnerClaim(commitmentId) == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings
        protocol.claimRewards(commitmentId);
        uint balanceBAfter = token.balanceOf(userB);

        vm.stopPrank();
    }

    function test_RewardMultiClaim_native() public {
        uint commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100, 5);
        join_native(commitmentId, userC, 100, 5);

        vm.warp(13);
        address[] memory winners = new address[](2);
        winners[0] = userB;
        winners[1] = userC;
        resolve(commitmentId, winners);

        vm.startPrank(userB);
        uint balanceBBefore = userB.balance;

        require(
            protocol.getCommitmentWinnerClaim(commitmentId) == 99 + 49,
            "Invalid Reward"
        );

        protocol.claimRewards(commitmentId);
        uint balanceBAfter = userB.balance;

        require(
            balanceBAfter - balanceBBefore == (99 + 49),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function test_CreatorClaim_native() public {
        uint commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100, 5);

        vm.startPrank(userA);
        uint balanceBefore = userA.balance;
        protocol.claimCreator(commitmentId);
        uint balanceAfter = userA.balance;
        require(balanceAfter - balanceBefore == 5, "Fee not credited");
        vm.stopPrank();
    }

    function test_ProtocolFees_native() public {
        uint commitmentId = create_native(userA, 100, 10);
        join_native(commitmentId, userB, 100, 10);

        uint beforeFees = protocol.getProtocolFees(address(0));
        uint beforeBalance = address(this).balance;
        require(
            beforeFees ==
                protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );
        protocol.claimProtocolFees(address(0));
        uint afterFees = protocol.getProtocolFees(address(0));
        uint afterBalance = address(this).balance;
        require(afterFees == 0, "Fees not cleared");
        require(
            afterBalance - beforeBalance == beforeFees,
            "Balance not updated"
        );
    }
}
