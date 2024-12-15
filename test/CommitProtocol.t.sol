// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

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
    address sender = address(0);
    address tokenAddress = address(0);
    uint256 stakeAmount = 100;
    uint256 creatorFee = 10;

    uint256 joinDeadline = block.timestamp + 1 days;
    uint256 fulfillmentDeadline = block.timestamp + 7 days;

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
        address _protocolFeeAddress,
        address _disperseContract,
        address _sender,
        address _tokenAddress,
        uint256 _stakeAmount,
        uint256 _creatorFee,
        uint256 _joinDeadline,
        uint256 _fulfillmentDeadline
    ) public {
        bytes memory _description = bytes("Test commitment");
        string memory _metadataURI = "ipfs://test";
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
        vm.stopPrank();
    }

    function join(
        uint256 _commitmentId,
        address _user,
        uint256 _stakeAmount,
        uint256 _joinFee
    ) public {
        vm.startPrank(_user);
        token.deal(_stakeAmount + _joinFee);
        token.approve(address(protocol), type(uint256).max);
        protocol.joinCommitment{value: protocol.PROTOCOL_JOIN_FEE()}(
            _commitmentId
        );
        vm.stopPrank();
    }

    function resolve(uint256 _commitmentId, address[] memory _winners) public {
        (uint256 id, address creator, , , , , , , , ) = protocol
            .commitmentInfo();

        vm.startPrank(creator);
        protocol.resolveCommitmentMerklePath(_commitmentId, root, leavesCount);
        vm.stopPrank();
    }

    function test_Create() public {
        create(
            commitmentId,
            protocolFeeAddress,
            disperseContract,
            sender,
            tokenAddress,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
    }

    function test_Join() public {
        create(
            commitmentId,
            protocolFeeAddress,
            disperseContract,
            sender,
            tokenAddress,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );

        join(commitmentId, userB, stakeAmount, 5);
    }

    function test_RewardSingleClaim() public {
        create(
            commitmentId,
            protocolFeeAddress,
            disperseContract,
            sender,
            tokenAddress,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(commitmentId, userB, stakeAmount, 5);

        vm.warp(13);
        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId, winners);

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
            protocolFeeAddress,
            disperseContract,
            sender,
            tokenAddress,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(commitmentId, userB, stakeAmount, 5);
        join(commitmentId, userC, stakeAmount, 5);

        vm.warp(13);
        address[] memory winners = new address[](2);
        winners[0] = userB;
        winners[1] = userC;
        resolve(commitmentId, winners);

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
            protocolFeeAddress,
            disperseContract,
            sender,
            tokenAddress,
            stakeAmount,
            creatorFee,
            joinDeadline,
            fulfillmentDeadline
        );
        join(commitmentId, userB, stakeAmount, 5);
        vm.startPrank(userA);
        uint256 balanceBefore = token.balanceOf(userA);
        protocol.claimCreator(commitmentId);
        uint256 balanceAfter = token.balanceOf(userA);
        require(balanceAfter - balanceBefore == 5, "Fee not credited");
        vm.stopPrank();
    }

    // function test_ProtocolFees() public {
    //     create(
    //         commitmentId,
    //         protocolFeeAddress,
    //         disperseContract,
    //         sender,
    //         tokenAddress,
    //         stakeAmount,
    //         creatorFee,
    //         joinDeadline,
    //         fulfillmentDeadline
    //     );
    //     join(commitmentId, userB, stakeAmount, 5);

    //     uint256 beforeFees = protocol.getProtocolFees(address(0));
    //     uint256 beforeBalance = address(this).balance;
    //     require(
    //         beforeFees ==
    //             protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
    //         "Fees not credited"
    //     );
    //     protocol.claimProtocolFees(address(0));
    //     uint256 afterFees = protocol.getProtocolFees(address(0));
    //     uint256 afterBalance = address(this).balance;
    //     require(afterFees == 0, "Fees not cleared");
    //     require(
    //         afterBalance - beforeBalance == beforeFees,
    //         "Balance not updated"
    //     );
    // }

    // function create_native(
    //     address user,
    //     uint256 stakeAmount,
    //     uint256 creatorShare
    // ) public returns (uint256) {
    //     vm.startPrank(user);

    //     uint256 id = protocol.createCommitmentNativeToken{
    //         value: protocol.PROTOCOL_CREATE_FEE() + stakeAmount
    //     }(
    //         creatorShare, // _creatorShare,
    //         "Test", // _description,
    //         block.timestamp + 1, // _joinDeadline,
    //         block.timestamp + 11, // _fulfillmentDeadline
    //         "test.com"
    //     );
    //     vm.stopPrank();
    //     return id;
    // }

    // function join_native(
    //     uint256 commitmentId,
    //     address user,
    //     uint256 stakeAmount
    // ) public {
    //     vm.startPrank(user);
    //     protocol.joinCommitment{
    //         value: protocol.PROTOCOL_JOIN_FEE() + stakeAmount
    //     }(commitmentId);
    //     vm.stopPrank();
    // }

    // function test_Create_native() public {
    //     create_native(userA, 100, 10);
    // }

    // function test_Join_native() public {
    //     uint256 commitmentId = create_native(userA, 100, 5);
    //     join_native(commitmentId, userB, 100);
    // }

    // function test_RewardSingleClaim_native() public {
    //     uint256 commitmentId = create_native(userA, 100, 5);
    //     join_native(commitmentId, userB, 100);

    //     vm.warp(13);
    //     address[] memory winners = new address[](1);
    //     winners[0] = userB;
    //     resolve(commitmentId, winners);

    //     vm.startPrank(userB);

    //     require(
    //         protocol.getClaims(commitmentId).winnerClaim == 99 + 99,
    //         "Invalid Reward"
    //     ); // 99 = stake refund, 99 = earnings
    //     protocol.claimRewards(commitmentId, proof);

    //     vm.stopPrank();
    // }

    // function test_RewardMultiClaim_native() public {
    //     uint256 commitmentId = create_native(userA, 100, 5);
    //     join_native(commitmentId, userB, 100);
    //     join_native(commitmentId, userC, 100);

    //     vm.warp(13);
    //     address[] memory winners = new address[](2);
    //     winners[0] = userB;
    //     winners[1] = userC;
    //     resolve(commitmentId, winners);

    //     vm.startPrank(userB);
    //     uint256 balanceBBefore = userB.balance;

    //     require(
    //         protocol.getClaims(commitmentId).winnerClaim == 99 + 198,
    //         "Invalid Reward"
    //     );

    //     protocol.claimRewards(commitmentId, proof);
    //     uint256 balanceBAfter = userB.balance;

    //     require(
    //         balanceBAfter - balanceBBefore == (99 + 198),
    //         "Fee not credited"
    //     ); // 99 = stake refund, 49 = earnings - creatorShare
    //     vm.stopPrank();
    // }

    // function test_CreatorClaim_native() public {
    //     uint256 commitmentId = create_native(userA, 100, 5);
    //     join_native(commitmentId, userB, 100);

    //     vm.startPrank(userA);
    //     uint256 balanceBefore = userA.balance;
    //     protocol.claimCreator(commitmentId);
    //     uint256 balanceAfter = userA.balance;
    //     require(balanceAfter - balanceBefore == 5, "Fee not credited");
    //     vm.stopPrank();
    // }

    // function test_ProtocolFees_native() public {
    //     uint256 commitmentId = create_native(userA, 100, 10);
    //     join_native(commitmentId, userB, 100);

    //     uint256 beforeFees = protocol.getProtocolFees(address(0));
    //     uint256 beforeBalance = address(this).balance;
    //     require(
    //         beforeFees ==
    //             protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
    //         "Fees not credited"
    //     );
    //     protocol.claimProtocolFees(address(0));
    //     uint256 afterFees = protocol.getProtocolFees(address(0));
    //     uint256 afterBalance = address(this).balance;
    //     require(afterFees == 0, "Fees not cleared");
    //     require(
    //         afterBalance - beforeBalance == beforeFees,
    //         "Balance not updated"
    //     );
    // }
}
