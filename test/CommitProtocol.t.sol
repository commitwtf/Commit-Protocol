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

    uint256 tokenId0 = 1 << 128;
    uint256 tokenId1 = tokenId0 + 2;
    address userA = 0x0000000000000000000000000000000000000001;
    address userB = 0x0000000000000000000000000000000000000002;
    address userC = 0x0000000000000000000000000000000000000003;
    address userD = 0x0000000000000000000000000000000000000004;

    function setUp() public {
        protocol = new CommitProtocol();
        token = new TestToken();

        protocol.initialize(address(this), userD);
        protocol.addAllowedToken(address(token));

        vm.deal(userA, 1 ether);
        vm.deal(userB, 1 ether);
        vm.deal(userC, 1 ether);
        vm.deal(userD, 1 ether);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                        ERC20 HELPERS
    //////////////////////////////////////////////////////////////*/

    function create(
        address _user,
        uint256 _stakeAmount,
        uint256 _creatorShare
    ) public returns (uint256) {
        vm.deal(_user, protocol.PROTOCOL_CREATE_FEE());

        vm.startPrank(_user);

        token.deal(100);
        token.approve(address(protocol), type(uint256).max);
        uint256 id = protocol.createCommitment{
            value: protocol.PROTOCOL_CREATE_FEE()
        }(
            address(token), // _tokenAddress,
            _stakeAmount, // _stakeAmount,
            _creatorShare, // _creatorShare,
            "Test", // _description,
            block.timestamp + 1, // _joinDeadline,
            block.timestamp + 11, // _fulfillmentDeadline,
            "http://test.com"
        );

        vm.stopPrank();

        return id;
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
            _commitmentId,
            address(0)
        );

        vm.stopPrank();
    }

    function resolve(uint256 _commitmentId) public {
        address creator = protocol.getCommitmentDetails(_commitmentId).creator;
        vm.startPrank(creator);

        protocol.resolveCommitmentMerklePath(_commitmentId, root, leavesCount);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 TEST CASES
    //////////////////////////////////////////////////////////////*/

    function test_Create() public {
        create(userA, 100, 10);
    }

    function test_Join() public {
        uint256 commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);
    }

    function test_Join_WithClient() public {
        uint256 commitmentId = create(userA, 100, 5);
        vm.startPrank(userB);
        uint256 clientFee = 10;
        protocol.addClient(userB, userC, clientFee);
        token.deal(200);
        token.approve(address(protocol), type(uint256).max);
        uint256 balanceBefore = token.balanceOf(userC);
        protocol.joinCommitment{value: protocol.PROTOCOL_JOIN_FEE()}(
            commitmentId,
            userB
        );
        uint256 balanceAfter = token.balanceOf(userC);
        require(
            balanceAfter - balanceBefore ==
                (clientFee * 200) / protocol.BASIS_POINTS(),
            "Client fee not credited"
        );
        vm.stopPrank();
    }

    function test_RewardSingleClaim() public {
        uint256 commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);

        vm.warp(13);

        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = token.balanceOf(userB);
        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings

        protocol.claimRewards(tokenId1, proof);
        uint256 balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 99),
            "Fee not credited"
        );

        vm.stopPrank();
    }

    function test_RewardMultiClaim() public {
        uint256 commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);
        join(commitmentId, userC, 100, 5);

        vm.warp(13);

        resolve(commitmentId);

        vm.startPrank(userB);

        uint256 balanceBBefore = token.balanceOf(userB);
        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 198,
            "Invalid Reward"
        );

        protocol.claimRewards(tokenId1, proof);
        uint256 balanceBAfter = token.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare

        vm.stopPrank();
    }

    function test_CreatorClaim() public {
        uint256 commitmentId = create(userA, 100, 5);
        join(commitmentId, userB, 100, 5);

        vm.startPrank(userA);

        uint256 balanceBefore = token.balanceOf(userA);
        protocol.claimCreator(commitmentId);
        uint256 balanceAfter = token.balanceOf(userA);

        require(balanceAfter - balanceBefore == 5, "Fee not credited");

        vm.stopPrank();
    }

    function test_ProtocolFees() public {
        uint256 commitmentId = create(userA, 100, 10);
        join(commitmentId, userB, 100, 10);

        uint256 beforeFees = protocol.getProtocolFees(address(0));
        uint256 beforeBalance = address(this).balance;
        require(
            beforeFees ==
                protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );

        protocol.claimProtocolFees(address(0));
        uint256 afterFees = protocol.getProtocolFees(address(0));
        uint256 afterBalance = address(this).balance;
        require(afterFees == 0, "Fees not cleared");
        require(
            afterBalance - beforeBalance == beforeFees,
            "Balance not updated"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE TOKEN HELPERS
    //////////////////////////////////////////////////////////////*/

    function create_native(
        address _user,
        uint256 _stakeAmount,
        uint256 _creatorShare
    ) public returns (uint256) {
        vm.startPrank(_user);

        uint256 id = protocol.createCommitmentNativeToken{
            value: protocol.PROTOCOL_CREATE_FEE() + _stakeAmount
        }(
            _creatorShare, // _creatorShare,
            "Test", // _description,
            block.timestamp + 1, // _joinDeadline,
            block.timestamp + 11, // _fulfillmentDeadline
            "test.com"
        );

        vm.stopPrank();

        return id;
    }

    function join_native(
        uint256 _commitmentId,
        address _user,
        uint256 _stakeAmount
    ) public {
        vm.startPrank(_user);

        protocol.joinCommitment{
            value: protocol.PROTOCOL_JOIN_FEE() + _stakeAmount
        }(_commitmentId, address(0));

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE TEST CASES
    //////////////////////////////////////////////////////////////*/

    function test_Create_native() public {
        create_native(userA, 100, 10);
    }

    function test_Join_native() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);
    }
    function test_Join_WithClient_native() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        vm.startPrank(userB);
        uint256 clientFee = 10;
        protocol.addClient(userB, userC, clientFee);
        clientFee = (clientFee * 100) / protocol.BASIS_POINTS();
        uint256 balanceBefore = address(userC).balance;
        protocol.joinCommitment{
            value: protocol.PROTOCOL_JOIN_FEE() + 100 + clientFee
        }(commitmentId, userB);
        uint256 balanceAfter = address(userC).balance;
        require(
            balanceAfter - balanceBefore == clientFee,
            "Client fee not credited"
        );
        vm.stopPrank();
    }

    function test_RewardSingleClaim_native() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);

        vm.warp(13);

        resolve(commitmentId);

        vm.startPrank(userB);

        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings
        protocol.claimRewards(tokenId1, proof);

        vm.stopPrank();
    }

    function test_RewardMultiClaim_native() public {
        uint256 commitmentId = create_native(userA, 100, 5);

        join_native(commitmentId, userB, 100);
        join_native(commitmentId, userC, 100);

        vm.warp(13);
        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;

        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 198,
            "Invalid Reward"
        );

        protocol.claimRewards(tokenId1, proof);
        uint256 balanceBAfter = userB.balance;

        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function test_CreatorClaim_native() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);

        vm.startPrank(userA);

        uint256 balanceBefore = userA.balance;
        protocol.claimCreator(commitmentId);
        uint256 balanceAfter = userA.balance;

        require(balanceAfter - balanceBefore == 5, "Fee not credited");

        vm.stopPrank();
    }

    function test_ProtocolFees_native() public {
        uint256 commitmentId = create_native(userA, 100, 10);
        join_native(commitmentId, userB, 100);

        uint256 beforeFees = protocol.getProtocolFees(address(0));
        uint256 beforeBalance = address(this).balance;
        require(
            beforeFees ==
                protocol.PROTOCOL_CREATE_FEE() + protocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );

        protocol.claimProtocolFees(address(0));
        uint256 afterFees = protocol.getProtocolFees(address(0));
        uint256 afterBalance = address(this).balance;

        require(afterFees == 0, "Fees not cleared");
        require(
            afterBalance - beforeBalance == beforeFees,
            "Balance not updated"
        );
    }

    function test_RewardSingleClaim_nativeWithFunding() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);

        protocol.fund{value: 100}(commitmentId, 0);
        vm.warp(13);

        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolve(commitmentId);

        vm.startPrank(userB);

        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 99 + 100,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings, 100 = funding
        protocol.claimRewards(tokenId1, proof);

        vm.stopPrank();
    }

    function test_RewardMultiClaim_nativeWithFunding() public {
        uint256 commitmentId = create_native(userA, 100, 5);

        join_native(commitmentId, userB, 100);
        join_native(commitmentId, userC, 100);

        protocol.fund{value: 100}(commitmentId, 0);

        vm.warp(13);

        resolve(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;

        require(
            protocol.getClaims(commitmentId).winnerClaim == 99 + 198 + 100,
            "Invalid Reward"
        );

        protocol.claimRewards(tokenId1, proof);
        uint256 balanceBAfter = userB.balance;

        require(
            balanceBAfter - balanceBBefore == (99 + 198 + 100),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare, 100 = funding

        vm.stopPrank();
    }

    function test_RemoveFunding_WhenCommitmentIsActive() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);

        protocol.fund{value: 100}(commitmentId, 0);

        vm.warp(13);

        protocol.removeFunding(commitmentId, 100);
    }

    function test_RemoveFunding_RevertWhen_CommitmentIsResolved() public {
        uint256 commitmentId = create_native(userA, 100, 5);
        join_native(commitmentId, userB, 100);

        protocol.fund{value: 100}(commitmentId, 0);

        vm.warp(13);

        resolve(commitmentId);

        vm.expectRevert(abi.encodeWithSignature("CommitmentNotActive()"));
        protocol.removeFunding(commitmentId, 100);
    }
}
