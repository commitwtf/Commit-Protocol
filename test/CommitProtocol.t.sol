// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CommitProtocol} from "../src/CommitProtocol.sol";
import {TestToken} from "./TestToken.sol";

contract CommitTest is Test {
    CommitProtocol private commitProtocol;
    TestToken private testToken;

    bytes32 merkleRoot =
        0x1ab0c6948a275349ae45a06aad66a8bd65ac18074615d53676c09b67809099e0;
    bytes32[] public merkleProof = new bytes32[](0);
    uint256 leavesCount = 1;

    uint256 tokenId0 = 1 << 128;
    uint256 tokenId1 = tokenId0 + 2;
    address userA = 0x0000000000000000000000000000000000000001;
    address userB = 0x0000000000000000000000000000000000000002;
    address userC = 0x0000000000000000000000000000000000000003;
    address userD = 0x0000000000000000000000000000000000000004;

    function setUp() public {
        commitProtocol = new CommitProtocol();
        testToken = new TestToken();

        commitProtocol.initialize(address(this), userD);
        commitProtocol.addAllowedToken(address(testToken));

        vm.deal(userA, 1 ether);
        vm.deal(userB, 1 ether);
        vm.deal(userC, 1 ether);
        vm.deal(userD, 1 ether);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                        ERC20 HELPERS
    //////////////////////////////////////////////////////////////*/

    function createCommitment(
        address _user,
        uint256 _stakeAmount,
        uint256 _creatorShare
    ) public returns (uint256) {
        vm.deal(_user, commitProtocol.PROTOCOL_CREATE_FEE());

        vm.startPrank(_user);

        testToken.deal(100);
        CommitProtocol.CommitmentInfo memory info;
        info.creator = _user;
        info.tokenAddress = address(testToken);
        info.stakeAmount = _stakeAmount;
        info.creatorFee = _creatorShare;
        info.description = "Test";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";
        testToken.approve(address(commitProtocol), type(uint256).max);
        uint256 id = commitProtocol.createCommitment{
            value: commitProtocol.PROTOCOL_CREATE_FEE()
        }(info, address(0));

        vm.stopPrank();

        return id;
    }

    function joinCommitment(
        uint256 _commitmentId,
        address _user,
        uint256 _stakeAmount,
        uint256 _joinFee
    ) public {
        vm.startPrank(_user);

        testToken.deal(_stakeAmount + _joinFee);
        testToken.approve(address(commitProtocol), type(uint256).max);
        commitProtocol.joinCommitment{
            value: commitProtocol.PROTOCOL_JOIN_FEE()
        }(_commitmentId, address(0));

        vm.stopPrank();
    }

    function resolveCommitment(uint256 _commitmentId) public {
        address creator = commitProtocol
            .getCommitmentDetails(_commitmentId)
            .creator;
        vm.startPrank(creator);

        commitProtocol.resolveCommitmentMerklePath(
            _commitmentId,
            merkleRoot,
            leavesCount
        );

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 TEST CASES
    //////////////////////////////////////////////////////////////*/

    function testCreateCommitment() public {
        createCommitment(userA, 100, 10);
    }

    function testCreateCommitmentWithClient() public {
        vm.startPrank(userB);
        uint256 stake = 1000000000000000000;
        uint256 clientFee = 10;
        commitProtocol.addClient(userC, clientFee);

        testToken.deal(
            stake + (clientFee * stake) / commitProtocol.BASIS_POINTS()
        );
        testToken.approve(address(commitProtocol), type(uint256).max);
        uint256 balanceBefore = testToken.balanceOf(userC);
        CommitProtocol.CommitmentInfo memory info;
        info.creator = userB;
        info.tokenAddress = address(testToken);
        info.stakeAmount = stake;
        info.creatorFee = 10;
        info.description = "Test";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";
        uint256 id = commitProtocol.createCommitment{
            value: commitProtocol.PROTOCOL_CREATE_FEE()
        }(info, userB);

        uint256 balanceAfter = testToken.balanceOf(userC);

        require(
            balanceAfter - balanceBefore ==
                (clientFee * stake) / commitProtocol.BASIS_POINTS(),
            "Client fee not credited"
        );

        vm.stopPrank();
    }

    function testJoinCommitment() public {
        uint256 commitmentId = createCommitment(userA, 100, 5);
        joinCommitment(commitmentId, userB, 100, 5);
    }

    function testJoinCommitmentWithClient() public {
        uint256 commitmentId = createCommitment(userA, 100, 5);
        vm.startPrank(userB);
        uint256 clientFee = 10;
        commitProtocol.addClient(userC, clientFee);
        testToken.deal(200);
        testToken.approve(address(commitProtocol), type(uint256).max);
        uint256 balanceBefore = testToken.balanceOf(userC);
        commitProtocol.joinCommitment{
            value: commitProtocol.PROTOCOL_JOIN_FEE()
        }(commitmentId, userB);
        uint256 balanceAfter = testToken.balanceOf(userC);
        require(
            balanceAfter - balanceBefore ==
                (clientFee * 200) / commitProtocol.BASIS_POINTS(),
            "Client fee not credited"
        );
        vm.stopPrank();
    }

    function testRewardSingleClaim() public {
        uint256 commitmentId = createCommitment(userA, 100, 5);
        joinCommitment(commitmentId, userB, 100, 5);

        vm.warp(13);

        resolveCommitment(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = testToken.balanceOf(userB);
        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings

        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 balanceBAfter = testToken.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 99),
            "Fee not credited"
        );

        vm.stopPrank();
    }

    function testRewardMultiClaim() public {
        uint256 commitmentId = createCommitment(userA, 100, 5);
        joinCommitment(commitmentId, userB, 100, 5);
        joinCommitment(commitmentId, userC, 100, 5);

        vm.warp(13);

        resolveCommitment(commitmentId);

        vm.startPrank(userB);

        uint256 balanceBBefore = testToken.balanceOf(userB);
        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 198,
            "Invalid Reward"
        );

        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 balanceBAfter = testToken.balanceOf(userB);
        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare

        vm.stopPrank();
    }

    function testCreatorClaim() public {
        uint256 commitmentId = createCommitment(userA, 100, 5);
        joinCommitment(commitmentId, userB, 100, 5);

        vm.startPrank(userA);

        uint256 balanceBefore = testToken.balanceOf(userA);
        commitProtocol.claimCreator(commitmentId);
        uint256 balanceAfter = testToken.balanceOf(userA);

        require(balanceAfter - balanceBefore == 5, "Fee not credited");

        vm.stopPrank();
    }

    function testProtocolFees() public {
        uint256 commitmentId = createCommitment(userA, 100, 10);
        joinCommitment(commitmentId, userB, 100, 10);

        uint256 beforeFees = commitProtocol.getProtocolFees(address(0));
        uint256 beforeBalance = address(this).balance;
        require(
            beforeFees ==
                commitProtocol.PROTOCOL_CREATE_FEE() +
                    commitProtocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );

        commitProtocol.claimProtocolFees(address(0));
        uint256 afterFees = commitProtocol.getProtocolFees(address(0));
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

    function createCommitmentNative(
        address _user,
        uint256 _stakeAmount,
        uint256 _creatorShare
    ) public returns (uint256) {
        vm.startPrank(_user);
        CommitProtocol.CommitmentInfo memory info;
        info.creator = _user;
        info.tokenAddress = address(0);
        info.stakeAmount = _stakeAmount;
        info.creatorFee = _creatorShare;
        info.description = "Test";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";

        uint256 id = commitProtocol.createCommitmentNativeToken{
            value: commitProtocol.PROTOCOL_CREATE_FEE() +
                _stakeAmount +
                _creatorShare
        }(info, address(0));

        vm.stopPrank();

        return id;
    }

    function joinCommitmentNative(
        uint256 _commitmentId,
        address _user,
        uint256 _stakeAmount
    ) public {
        vm.startPrank(_user);

        commitProtocol.joinCommitment{
            value: commitProtocol.PROTOCOL_JOIN_FEE() + _stakeAmount
        }(_commitmentId, address(0));

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE TEST CASES
    //////////////////////////////////////////////////////////////*/

    function testCreateCommitmentNative() public {
        createCommitmentNative(userA, 100, 10);
    }

    function testCreateCommitmentNativeWithClient() public {
        vm.startPrank(userB);
        uint256 stake = 1000000000000000000;
        uint256 clientFee = 10;
        vm.deal(userB, stake * 2);
        uint256 creatorShare = 10;
        commitProtocol.addClient(userC, clientFee);
        uint256 balanceBefore = address(userC).balance;
        CommitProtocol.CommitmentInfo memory info;
        info.creator = userB;
        info.tokenAddress = address(0);
        info.stakeAmount = stake;
        info.creatorFee = creatorShare;
        info.description = "Test";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";
        uint256 id = commitProtocol.createCommitmentNativeToken{
            value: commitProtocol.PROTOCOL_CREATE_FEE() +
                creatorShare +
                stake +
                ((clientFee * stake) / commitProtocol.BASIS_POINTS())
        }(info, userB);
        uint256 balanceAfter = address(userC).balance;

        require(
            balanceAfter - balanceBefore ==
                (clientFee * stake) / commitProtocol.BASIS_POINTS(),
            "Client fee not credited"
        );

        vm.stopPrank();
    }

    function testJoinCommitmentNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);
    }
    function testJoinCommitmentWithClientNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        vm.startPrank(userB);
        uint256 clientFee = 10;
        commitProtocol.addClient(userC, clientFee);
        clientFee = (clientFee * 100) / commitProtocol.BASIS_POINTS();
        uint256 balanceBefore = address(userC).balance;
        commitProtocol.joinCommitment{
            value: commitProtocol.PROTOCOL_JOIN_FEE() + 100 + clientFee
        }(commitmentId, userB);
        uint256 balanceAfter = address(userC).balance;
        require(
            balanceAfter - balanceBefore == clientFee,
            "Client fee not credited"
        );
        vm.stopPrank();
    }

    function testRewardSingleClaimNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);

        vm.warp(13);

        resolveCommitment(commitmentId);

        vm.startPrank(userB);

        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings
        commitProtocol.claimRewards(tokenId1, merkleProof);

        vm.stopPrank();
    }

    function testRewardMultiClaimNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);

        joinCommitmentNative(commitmentId, userB, 100);
        joinCommitmentNative(commitmentId, userC, 100);

        vm.warp(13);
        resolveCommitment(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;

        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 198,
            "Invalid Reward"
        );

        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 balanceBAfter = userB.balance;

        require(
            balanceBAfter - balanceBBefore == (99 + 198),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare
        vm.stopPrank();
    }

    function testCreatorClaimNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);

        vm.startPrank(userA);

        uint256 balanceBefore = userA.balance;
        commitProtocol.claimCreator(commitmentId);
        uint256 balanceAfter = userA.balance;

        require(balanceAfter - balanceBefore == 5, "Fee not credited");

        vm.stopPrank();
    }

    function testProtocolFeesNative() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 10);
        joinCommitmentNative(commitmentId, userB, 100);

        uint256 beforeFees = commitProtocol.getProtocolFees(address(0));
        uint256 beforeBalance = address(this).balance;
        require(
            beforeFees ==
                commitProtocol.PROTOCOL_CREATE_FEE() +
                    commitProtocol.PROTOCOL_JOIN_FEE(),
            "Fees not credited"
        );

        commitProtocol.claimProtocolFees(address(0));
        uint256 afterFees = commitProtocol.getProtocolFees(address(0));
        uint256 afterBalance = address(this).balance;

        require(afterFees == 0, "Fees not cleared");
        require(
            afterBalance - beforeBalance == beforeFees,
            "Balance not updated"
        );
    }

    function testRewardSingleClaimNativeWithFunding() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);

        commitProtocol.fund{value: 100}(commitmentId, 100, address(0));
        vm.warp(13);

        address[] memory winners = new address[](1);
        winners[0] = userB;
        resolveCommitment(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;
        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 99,
            "Invalid Reward"
        ); // 99 = stake refund, 99 = earnings
        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 balanceBAfter = userB.balance;
        require(
            balanceBAfter - balanceBBefore == (99 + 99 + 100),
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare

        vm.stopPrank();
    }

    function testRewardMultiClaimNativeWithFunding() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);

        joinCommitmentNative(commitmentId, userB, 100);
        joinCommitmentNative(commitmentId, userC, 100);

        commitProtocol.fund{value: 100}(commitmentId, 100, address(0));

        vm.warp(13);

        resolveCommitment(commitmentId);

        vm.startPrank(userB);
        uint256 balanceBBefore = userB.balance;

        require(
            commitProtocol.getClaims(commitmentId).winnerClaim == 99 + 198,
            "Invalid Reward"
        );

        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 balanceBAfter = userB.balance;
        assertEq(
            balanceBAfter - balanceBBefore,
            99 + 198 + 100,
            "Fee not credited"
        ); // 99 = stake refund, 49 = earnings - creatorShare, 100 = funding

        vm.stopPrank();
    }

    function testRemoveFundingWhenCommitmentIsActive() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);

        commitProtocol.fund{value: 100}(commitmentId, 100, address(0));

        vm.warp(13);

        commitProtocol.removeFunding(commitmentId, 100, address(0));
    }

    function testRemoveFundingRevertWhenCommitmentIsResolved() public {
        uint256 commitmentId = createCommitmentNative(userA, 100, 5);
        joinCommitmentNative(commitmentId, userB, 100);

        commitProtocol.fund{value: 100}(commitmentId, 100, address(0));

        vm.warp(13);

        resolveCommitment(commitmentId);

        vm.expectRevert(abi.encodeWithSignature("CommitmentNotActive()"));
        commitProtocol.removeFunding(commitmentId, 100, address(0));
    }
}
