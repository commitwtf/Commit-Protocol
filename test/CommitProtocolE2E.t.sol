// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CommitProtocol} from "../src/CommitProtocol.sol";
import {TestToken} from "./TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
                        E2E TEST SCENARIOS 
    //////////////////////////////////////////////////////////////*/

    function testE2ESuccessfulCommitmentLifecycleWithERC20() public {
        // 1. Creator creates commitment
        uint256 stakeAmount = 100;
        uint256 creatorShare = 5;
        uint256 commitmentId = createCommitment(
            userA,
            stakeAmount,
            creatorShare
        );

        // 2. Multiple users join
        joinCommitment(commitmentId, userB, stakeAmount, creatorShare);
        joinCommitment(commitmentId, userC, stakeAmount, creatorShare);

        // 3. Someone adds funding
        vm.startPrank(userD);
        testToken.deal(50);
        testToken.approve(address(commitProtocol), 50);
        commitProtocol.fund(commitmentId, 50);
        vm.stopPrank();

        // 4. Time passes, commitment is fulfilled and resolved
        vm.warp(13);
        resolveCommitment(commitmentId);

        // 5. Creator claims their share
        vm.startPrank(userA);
        uint256 creatorBalanceBefore = testToken.balanceOf(userA);
        commitProtocol.claimCreator(commitmentId);
        uint256 creatorBalanceAfter = testToken.balanceOf(userA);
        assertEq(creatorBalanceAfter - creatorBalanceBefore, creatorShare * 2); // Share from 2 joiners
        vm.stopPrank();

        // 6. Winner claims rewards
        vm.startPrank(userB);
        uint256 winnerBalanceBefore = testToken.balanceOf(userB);
        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 winnerBalanceAfter = testToken.balanceOf(userB);

        // Winner gets: their stake back + losing stakes + funding
        uint256 expectedReward = 99 + 198 + 50; // stake refund + earnings + funding
        assertEq(winnerBalanceAfter - winnerBalanceBefore, expectedReward);
        vm.stopPrank();
    }

    function testE2ESuccessfulCommitmentLifecycleWithNative() public {
        // 1. Creator creates commitment
        uint256 stakeAmount = 100;
        uint256 creatorShare = 5;
        uint256 commitmentId = createCommitmentNative(
            userA,
            stakeAmount,
            creatorShare
        );

        // 2. Multiple users join
        joinCommitmentNative(commitmentId, userB, stakeAmount);
        joinCommitmentNative(commitmentId, userC, stakeAmount);

        // 3. Someone adds funding
        vm.startPrank(userD);
        commitProtocol.fund{value: 50}(commitmentId, 0);
        vm.stopPrank();

        // 4. Time passes, commitment is fulfilled and resolved
        vm.warp(13);
        resolveCommitment(commitmentId);

        // 5. Creator claims their share
        vm.startPrank(userA);
        uint256 creatorBalanceBefore = userA.balance;
        commitProtocol.claimCreator(commitmentId);
        uint256 creatorBalanceAfter = userA.balance;
        assertEq(creatorBalanceAfter - creatorBalanceBefore, creatorShare * 2);
        vm.stopPrank();

        // 6. Winner claims rewards
        vm.startPrank(userB);
        uint256 winnerBalanceBefore = userB.balance;
        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 winnerBalanceAfter = userB.balance;

        uint256 expectedReward = 99 + 198 + 50; // stake refund + earnings + funding
        assertEq(winnerBalanceAfter - winnerBalanceBefore, expectedReward);
        vm.stopPrank();
    }

    function testE2ECancelledCommitmentLifecycle() public {
        // 1. Creator creates commitment
        uint256 stakeAmount = 100;
        uint256 creatorShare = 5;
        uint256 commitmentId = createCommitment(
            userA,
            stakeAmount,
            creatorShare
        );

        // 2. One user joins
        joinCommitment(commitmentId, userB, stakeAmount, creatorShare);

        // 3. Someone adds funding
        vm.startPrank(userD);
        testToken.deal(50);
        testToken.approve(address(commitProtocol), 50);
        commitProtocol.fund(commitmentId, 50);
        vm.stopPrank();

        // 4. Creator cancels commitment
        vm.startPrank(userA);
        commitProtocol.cancelCommitment(commitmentId);
        vm.stopPrank();

        // 5. Participants claim their stakes back
        vm.startPrank(userB);
        uint256 balanceBefore = testToken.balanceOf(userB);
        commitProtocol.claimCancelled(tokenId1);
        uint256 balanceAfter = testToken.balanceOf(userB);
        assertEq(balanceAfter - balanceBefore, stakeAmount);
        vm.stopPrank();

        // 6. Funder can remove their funding
        vm.startPrank(userD);
        uint256 funderBalanceBefore = testToken.balanceOf(userD);
        commitProtocol.removeFunding(commitmentId, 50);
        uint256 funderBalanceAfter = testToken.balanceOf(userD);
        assertEq(funderBalanceAfter - funderBalanceBefore, 50);
        vm.stopPrank();
    }

    function testE2EEmergencyScenario() public {
        // 1. Create and setup commitment
        uint256 stakeAmount = 100;
        uint256 creatorShare = 5;
        uint256 commitmentId = createCommitment(
            userA,
            stakeAmount,
            creatorShare
        );
        joinCommitment(commitmentId, userB, stakeAmount, creatorShare);

        // 2. Owner pauses contract
        vm.startPrank(address(this));
        commitProtocol.emergencyPauseAll();

        // 3. Verify operations are blocked
        vm.startPrank(userB);
        testToken.deal(stakeAmount + creatorShare);
        testToken.approve(address(commitProtocol), type(uint256).max);
        uint256 protocolFee = commitProtocol.PROTOCOL_JOIN_FEE();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        commitProtocol.joinCommitment{value: protocolFee}(
            commitmentId,
            address(0)
        );

        vm.stopPrank();

        // 4. Owner performs emergency withdrawal
        uint256 ownerBalanceBefore = testToken.balanceOf(address(this));
        commitProtocol.emergencyWithdrawToken(IERC20(address(testToken)), 200);
        uint256 ownerBalanceAfter = testToken.balanceOf(address(this));
        assertEq(ownerBalanceAfter - ownerBalanceBefore, 200);

        // 5. Owner unpauses contract
        commitProtocol.emergencyUnpauseAll();
        vm.stopPrank();

        // 6. Verify operations resume
        joinCommitment(commitmentId, userC, stakeAmount, creatorShare);
    }

    function testE2EClientRegistrationAndCommitmentLifecycle() public {
        // 1. Register client
        address clientAddress = userB;
        address clientWithdrawAddress = userC;
        uint256 clientFeeShare = 500; // 5% fee

        vm.startPrank(clientAddress);
        commitProtocol.addClient(clientWithdrawAddress, clientFeeShare);
        vm.stopPrank();

        // 2. Create commitment through client
        uint256 stakeAmount = 100;
        uint256 creatorShare = 10;

        vm.startPrank(userA);
        testToken.deal(
            stakeAmount +
                (clientFeeShare * stakeAmount) /
                commitProtocol.BASIS_POINTS()
        );
        testToken.approve(address(commitProtocol), type(uint256).max);

        CommitProtocol.CommitmentInfo memory info;
        info.creator = userA;
        info.tokenAddress = address(testToken);
        info.stakeAmount = stakeAmount;
        info.creatorFee = creatorShare;
        info.description = "Test Client Commitment";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";

        // Track client fee recipient balance
        uint256 clientBalanceBefore = testToken.balanceOf(
            clientWithdrawAddress
        );

        uint256 commitmentId = commitProtocol.createCommitment{
            value: commitProtocol.PROTOCOL_CREATE_FEE()
        }(info, clientAddress);

        // Verify client fee was paid
        uint256 clientBalanceAfter = testToken.balanceOf(clientWithdrawAddress);
        uint256 expectedClientFee = (clientFeeShare * stakeAmount) /
            commitProtocol.BASIS_POINTS();
        assertEq(
            clientBalanceAfter - clientBalanceBefore,
            expectedClientFee,
            "Client fee not paid correctly"
        );
        vm.stopPrank();

        // 3. Join commitment through client
        vm.startPrank(userB);
        testToken.deal(
            stakeAmount +
                creatorShare +
                (clientFeeShare * stakeAmount) /
                commitProtocol.BASIS_POINTS()
        );
        testToken.approve(address(commitProtocol), type(uint256).max);

        clientBalanceBefore = testToken.balanceOf(clientWithdrawAddress);

        commitProtocol.joinCommitment{
            value: commitProtocol.PROTOCOL_JOIN_FEE()
        }(commitmentId, clientAddress);

        // Verify client fee was paid for joining
        clientBalanceAfter = testToken.balanceOf(clientWithdrawAddress);
        assertEq(
            clientBalanceAfter - clientBalanceBefore,
            expectedClientFee,
            "Client join fee not paid correctly"
        );
        vm.stopPrank();

        // 4. Resolve commitment and verify rewards
        vm.warp(13);
        resolveCommitment(commitmentId);

        // 5. Verify winner claims
        vm.startPrank(userB);
        uint256 winnerBalanceBefore = testToken.balanceOf(userB);
        commitProtocol.claimRewards(tokenId1, merkleProof);
        uint256 winnerBalanceAfter = testToken.balanceOf(userB);

        // Winner should get their stake back plus earnings, less protocol fees
        uint256 expectedReward = 99 + 99; // stake refund + earnings
        assertEq(
            winnerBalanceAfter - winnerBalanceBefore,
            expectedReward,
            "Winner reward incorrect"
        );
        vm.stopPrank();
    }

    function testE2EClientRemovalAndReregistration() public {
        // 1. Register client
        address clientAddress = userB;
        address clientWithdrawAddress = userC;
        uint256 clientFeeShare = 500;

        vm.startPrank(clientAddress);
        commitProtocol.addClient(clientWithdrawAddress, clientFeeShare);

        // 2. Remove client
        commitProtocol.removeClient(clientAddress);

        // 3. Verify can't create commitment with removed client
        vm.stopPrank();

        vm.startPrank(userA);
        testToken.deal(1000);
        testToken.approve(address(commitProtocol), type(uint256).max);

        CommitProtocol.CommitmentInfo memory info;
        info.creator = userA;
        info.tokenAddress = address(testToken);
        info.stakeAmount = 1000;
        info.creatorFee = 10;
        info.description = "Test";
        info.joinDeadline = block.timestamp + 1;
        info.fulfillmentDeadline = block.timestamp + 11;
        info.metadataURI = "http://test.com";
        uint256 protocolFee = commitProtocol.PROTOCOL_CREATE_FEE();

        commitProtocol.createCommitment{value: protocolFee}(
            info,
            clientAddress
        );
        assertEq(testToken.balanceOf(userA), 0, "Creator balance incorrect");
        // 4. Re-register client with new parameters
        vm.stopPrank();

        vm.startPrank(clientAddress);
        address newWithdrawAddress = userD;
        uint256 newFeeShare = 1000;
        commitProtocol.addClient(newWithdrawAddress, newFeeShare);

        // 5. Verify can create commitment with re-registered client
        vm.stopPrank();

        vm.startPrank(userA);
        testToken.deal(1000);
        testToken.approve(address(commitProtocol), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                userA,
                0,
                (info.stakeAmount * newFeeShare) / commitProtocol.BASIS_POINTS()
            )
        );
        uint256 commitmentId = commitProtocol.createCommitment{
            value: protocolFee
        }(info, clientAddress);

        testToken.deal(100);
        commitmentId = commitProtocol.createCommitment{value: protocolFee}(
            info,
            clientAddress
        );

        // 6. Verify new client fee parameters are used
        uint256 expectedClientFee = (newFeeShare * info.stakeAmount) /
            commitProtocol.BASIS_POINTS();
        uint256 clientBalance = testToken.balanceOf(newWithdrawAddress);
        assertEq(
            clientBalance,
            expectedClientFee,
            "New client fee parameters not applied"
        );
        vm.stopPrank();
    }

    function testE2EMultipleClientsAndCommitments() public {
        // 1. Register multiple clients
        address[] memory clients = new address[](3);
        clients[0] = userB;
        clients[1] = userC;
        clients[2] = userD;

        uint256[] memory feeShares = new uint256[](3);
        feeShares[0] = 300; // 3%
        feeShares[1] = 500; // 5%
        feeShares[2] = 700; // 7%

        for (uint i = 0; i < clients.length; i++) {
            vm.startPrank(clients[i]);
            commitProtocol.addClient(clients[i], feeShares[i]);
            vm.stopPrank();
        }

        // 2. Create commitments through different clients
        uint256 stakeAmount = 1000;

        for (uint i = 0; i < clients.length; i++) {
            vm.startPrank(userA);
            testToken.deal(
                stakeAmount +
                    (feeShares[i] * stakeAmount) /
                    commitProtocol.BASIS_POINTS()
            );
            testToken.approve(address(commitProtocol), type(uint256).max);

            CommitProtocol.CommitmentInfo memory info;
            info.creator = userA;
            info.tokenAddress = address(testToken);
            info.stakeAmount = stakeAmount;
            info.creatorFee = 10;
            info.description = "Test Multi-Client";
            info.joinDeadline = block.timestamp + 1;
            info.fulfillmentDeadline = block.timestamp + 11;
            info.metadataURI = "http://test.com";

            uint256 clientBalanceBefore = testToken.balanceOf(clients[i]);

            commitProtocol.createCommitment{
                value: commitProtocol.PROTOCOL_CREATE_FEE()
            }(info, clients[i]);

            uint256 clientBalanceAfter = testToken.balanceOf(clients[i]);
            uint256 expectedClientFee = (feeShares[i] * stakeAmount) /
                commitProtocol.BASIS_POINTS();
            assertEq(
                clientBalanceAfter - clientBalanceBefore,
                expectedClientFee,
                string.concat(
                    "Client fee incorrect for client ",
                    vm.toString(i)
                )
            );

            vm.stopPrank();
        }
    }
}
