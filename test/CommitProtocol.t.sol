// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CommitProtocol} from "../src/CommitProtocol.sol";
import {TestToken} from "./TestToken.sol";

contract CommitTest is Test {
    CommitProtocol private protocol;
    TestToken private token;

    bytes32 root =
        0x1ab0c6948a275349ae45a06aad66a8bd65ac18074615d53676c09b67809099e0;
    bytes32[] public proof = new bytes32[](0);
    uint256 leavesCount = 1;

    address userA = 0x0000000000000000000000000000000000000001;
    address userB = 0x0000000000000000000000000000000000000002;
    address userC = 0x0000000000000000000000000000000000000003;
    address userD = 0x0000000000000000000000000000000000000004;

    uint256 commitmentId = 1;
    address protocolFeeAddress = address(this);
    address disperseContract = address(this);
    address sender = 0x0000000000000000000000000000000000000005;
    address tokenAddress = 0x0000000000000000000000000000000000000006;
    uint256 stakeAmount = 100;
    uint256 creatorFee = 10;

    uint256 joinDeadline = block.timestamp + 1;
    uint256 fulfillmentDeadline = block.timestamp + 11;

    function setUp() public {
        protocol = new CommitProtocol();
        token = new TestToken();
        vm.deal(userA, 1 ether);
        vm.deal(userB, 1 ether);
        vm.deal(userC, 1 ether);
        vm.deal(userD, 1 ether);
    }

    receive() external payable {}

    function create(
        uint256 _id,
        address _sender,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline
    ) public {
        bytes memory _description = bytes("Test commitment");

        vm.startPrank(_sender);
        token.deal(100);
        token.approve(address(protocol), type(uint256).max);
        CommitProtocol.CommitmentInfo memory _commitmentInfo;
        _commitmentInfo.id = _id;
        _commitmentInfo.creator = _sender;
        _commitmentInfo.tokenAddress = address(token);
        _commitmentInfo.stakeAmount = _stakeAmount;
        _commitmentInfo.creatorFee = _creatorFee;
        _commitmentInfo.description = _description;
        _commitmentInfo.joinDeadline = _joinDeadline;
        _commitmentInfo.fulfillmentDeadline = _fulfillmentDeadline;
        protocol.initialize(_commitmentInfo, disperseContract);
        // since the factory transfer the state on creation now.
        token.transfer(address(protocol), _stakeAmount);
        vm.stopPrank();
    }

    function join(
        address _user,
        uint256 _stakeAmount,
        uint256 _joinFee
    ) public {
        vm.startPrank(_user);
        token.deal(_stakeAmount + _joinFee);
        token.approve(address(protocol), type(uint256).max);
        protocol.joinCommitment{value: protocol.PROTOCOL_JOIN_FEE()}();
        vm.stopPrank();
    }

    function resolve(uint256 _commitmentId) public {
        (, address creator, , , , , , , , ) = protocol.commitmentInfo();

        vm.startPrank(creator);
        protocol.resolveCommitmentMerklePath(_commitmentId, root, leavesCount);
        vm.stopPrank();
    }

    function test_Create() public {
        create(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
    }

    function test_Join() public {
        create(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );

        join(userB, stakeAmount, creatorFee);
    }

    function test_RewardSingleClaim() public {
        create(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(userB, stakeAmount, creatorFee);

        vm.warp(13);
        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = token.balanceOf(userB);
        (uint256 winnerClaim, , , ) = protocol.claims();
        require(winnerClaim == 99 + 99, "Invalid Reward"); // 99 = stake refund, 99 = earnings
        protocol.claimRewards(commitmentId, proof);
        uint256 balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 99),
            "Fee not credited"
        );
        vm.stopPrank();
    }

    function test_RewardMultiClaim() public {
        create(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(userB, stakeAmount, creatorFee);
        join(userC, stakeAmount, creatorFee);

        vm.warp(13);
        address[] memory winners = new address[](2);
        winners[0] = userB;
        winners[1] = userC;
        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = token.balanceOf(userB);
        (uint256 winnerClaim, , , ) = protocol.claims();
        require(winnerClaim == 99 + 198, "Invalid Reward");

        protocol.claimRewards(commitmentId, proof);
        uint256 balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function test_CreatorClaim() public {
        create(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(userB, stakeAmount, creatorFee);
        vm.startPrank(sender);
        uint256 balanceBefore = token.balanceOf(sender);
        protocol.claimCreator(commitmentId);
        uint256 balanceAfter = token.balanceOf(sender);
        require(balanceAfter - balanceBefore == 10, "Fee not credited");
        vm.stopPrank();
    }

    function create_native(
        uint256 _id,
        address _sender,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline
    ) public {
        bytes memory _description = bytes("Test commitment");

        vm.deal(sender, _stakeAmount + _creatorFee);
        vm.startPrank(sender);
        CommitProtocol.CommitmentInfo memory _commitmentInfo;
        _commitmentInfo.id = _id;
        _commitmentInfo.creator = _sender;
        _commitmentInfo.tokenAddress = address(0);
        _commitmentInfo.stakeAmount = _stakeAmount;
        _commitmentInfo.creatorFee = _creatorFee;
        _commitmentInfo.description = _description;
        _commitmentInfo.joinDeadline = _joinDeadline;
        _commitmentInfo.fulfillmentDeadline = _fulfillmentDeadline;
        protocol.initialize{value: _stakeAmount}(
            _commitmentInfo,
            disperseContract
        );
        vm.stopPrank();
    }

    function join_native(address _user, uint256 _stakeAmount) public {
        vm.startPrank(_user);
        vm.deal(_user, protocol.PROTOCOL_JOIN_FEE() + _stakeAmount);
        protocol.joinCommitment{
            value: protocol.PROTOCOL_JOIN_FEE() + _stakeAmount
        }();
        vm.stopPrank();
    }

    function test_Create_native() public {
        create_native(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
    }

    function test_Join_native() public {
        create_native(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join_native(userB, stakeAmount);
    }

    function test_RewardSingleClaim_native() public {
        create_native(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join_native(userB, stakeAmount);

        vm.warp(13);
        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId);

        vm.startPrank(userB);
        (uint256 winnerClaim, , , ) = protocol.claims();
        require(winnerClaim == 99 + 99, "Invalid Reward"); // 99 = stake refund, 99 = earnings
        protocol.claimRewards(commitmentId, proof);

        vm.stopPrank();
    }

    function test_RewardMultiClaim_native() public {
        create_native(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join_native(userB, stakeAmount);
        join_native(userC, stakeAmount);

        vm.warp(13);
        address[] memory winners = new address[](2);
        winners[0] = userB;
        winners[1] = userC;
        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;
        (uint256 winnerClaim, , , ) = protocol.claims();
        require(winnerClaim == 99 + 198, "Invalid Reward");

        protocol.claimRewards(commitmentId, proof);
        uint256 balanceBAfter = userB.balance;

        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function test_CreatorClaim_native() public {
        create_native(
            commitmentId,
            sender,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join_native(userB, stakeAmount);

        vm.startPrank(sender);
        uint256 balanceBefore = sender.balance;
        protocol.claimCreator(commitmentId);
        uint256 balanceAfter = sender.balance;

        require(balanceAfter - balanceBefore == 10, "Fee not credited");
        vm.stopPrank();
    }
}
