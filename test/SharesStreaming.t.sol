// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {SharesStreamingV2} from "../src/SharesStreamingV2.sol";

contract SharesStreamingTest is Test {
    MockERC20 public asset;
    MockERC4626 public vault;
    SharesStreamingV2 public sharesStreaming;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    event OpenSharesStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseShareStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpSharesStream(
        address indexed streamer, address indexed receiver, uint256 addedShares, uint256 addedDuration
    );

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        sharesStreaming = new SharesStreamingV2(IERC4626(address(vault)));
    }

    // *** #openShareStream ***

    function test_openShareStream_createsNewStream() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openStream(bob, shares, 1 days);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);

        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, shares);
        assertEq(stream.ratePerSecond, shares / 1 days);
        assertEq(stream.startTime, block.timestamp);
        assertEq(stream.lastClaimTime, block.timestamp);
    }

    function test_openShareStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 2 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectEmit(true, true, true, true);
        emit OpenSharesStream(alice, bob, shares, duration);

        sharesStreaming.openStream(bob, shares, duration);
    }

    function test_openShareStream_failsIfStreamAlreadyExists() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openStream(bob, shares, 1 days);
        vm.stopPrank();

        shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.StreamAlreadyExists.selector);
        sharesStreaming.openStream(bob, shares, 1 days);
    }

    function test_openShareStream_worksIfExistingStreamHasExpiredAndIsNotClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openStream(bob, shares, 1 days);
        vm.stopPrank();

        shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.warp(block.timestamp + 1 days + 1);

        sharesStreaming.openStream(bob, shares, 1 days);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver's balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), shares, "sharesStreaming's balance");
    }

    function test_openShareStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.AddressZero.selector);
        sharesStreaming.openStream(address(0), shares, 1 days);
    }

    function test_openShareStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.ZeroShares.selector);
        sharesStreaming.openStream(bob, 0, 1 days);
    }

    function test_openShareStream_failsIfSharesIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.NotEnoughShares.selector);
        sharesStreaming.openStream(bob, shares + 1, 1 days);
    }

    function test_openShareStream_failsIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.ZeroDuration.selector);
        sharesStreaming.openStream(bob, shares, 0);
    }

    function test_openShareStream_failsIfSharesIsGreaterThanBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares + 1);

        vm.expectRevert();
        sharesStreaming.openStream(bob, shares + 1, 1 days);
    }

    function test_openShareStream_failsIfReceiverIsSameAsCaller() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.CannotOpenStreamToSelf.selector);
        sharesStreaming.openStream(alice, shares, 1 days);
    }

    // *** #claimShares ***

    function test_claim_failsIfStreamDoesNotExist() public {
        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        vm.prank(bob);
        sharesStreaming.claim(alice);
    }

    function test_claim_whenStreamIsComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "totalShares");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_claim_whenStreamIsNotComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");
        assertApproxEqRel(claimed, shares / 2, 0.0001e18, "claimed");
    }

    function test_claim_twoConsecutiveClaims() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        vm.expectRevert(SharesStreamingV2.NoSharesToClaim.selector);
        vm.prank(bob);
        sharesStreaming.claim(alice);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 4, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
    }

    function test_claim_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit ClaimShares(alice, bob, shares);

        vm.startPrank(bob);
        sharesStreaming.claim(alice);
    }

    // *** #closeStream *** ///

    function test_closeStream_failsIfStreamDoesNotExist() public {
        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        vm.prank(bob);
        sharesStreaming.closeStream(bob);
    }

    function test_closeStream_transfersUnclaimedSharesToReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "totalShares");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_closeStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit CloseShareStream(alice, bob, 0, shares);

        vm.startPrank(alice);
        sharesStreaming.closeStream(bob);
    }

    function test_closeStream_failsIfAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        vm.prank(alice);
        sharesStreaming.closeStream(bob);
    }

    function test_closeStream_transfersRemainingUnclaimedSharesToReceiverAfterLastClaim() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        // around 1/4 should be claimable
        vm.warp(block.timestamp + 6 hours);

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares / 4, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
    }

    function test_closeStream_transfersRemainingSharesToStreamer() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance 1");
        assertEq(vault.balanceOf(alice), 0, "alice's balance 1 ");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 1");

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance 2");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.0001e18, "alice's balance 2");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 2");
    }

    // *** #topUpStream ***

    function test_topUpStream_addsSharesAndExtendsDuration() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _openStream(alice, bob, shares, duration);

        uint256 streamId = sharesStreaming.getStreamId(alice, bob);
        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(streamId);

        vm.warp(block.timestamp + 12 hours);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpStream(bob, additionalShares, additionalDuration);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares + additionalShares, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        SharesStreamingV2.Stream memory updatedStream = sharesStreaming.getStream(streamId);

        assertEq(updatedStream.shares, shares + additionalShares, "totalShares");
        assertEq(
            updatedStream.ratePerSecond, (shares + additionalShares) / (duration + additionalDuration), "ratePerSecond"
        );
        assertEq(updatedStream.startTime, stream.startTime, "startTime");
        assertEq(updatedStream.lastClaimTime, stream.lastClaimTime, "lastClaimTime");
    }

    function test_topUpStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectEmit(true, true, true, true);
        emit TopUpSharesStream(alice, bob, additionalShares, additionalDuration);
        sharesStreaming.topUpStream(bob, additionalShares, additionalDuration);
    }

    function test_topUpStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.ZeroShares.selector);
        sharesStreaming.topUpStream(bob, 0, 1 days);
    }

    function test_topUpStream_failsIfSharesIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.NotEnoughShares.selector);
        sharesStreaming.topUpStream(bob, shares + 1, 1 days);
    }

    function test_topUpStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.AddressZero.selector);
        sharesStreaming.topUpStream(address(0), shares, 1 days);
    }

    function test_topUpStream_failsIfStreamDoesNotExist() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        sharesStreaming.topUpStream(bob, shares, 1 days);
    }

    function test_topUpStream_failsIfStreamIsExpired() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(SharesStreamingV2.StreamExpired.selector);
        sharesStreaming.topUpStream(bob, shares, 1 days);
    }

    function test_topUpStream_worksAfterSomeSharesAreClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 firstClaim = sharesStreaming.claim(alice);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpStream(bob, shares, 1 days);
        vm.stopPrank();

        assertApproxEqRel(
            vault.balanceOf(address(sharesStreaming)), shares * 3 / 2, 0.0001e18, "sharesStreaming balance"
        );
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), firstClaim, "receiver balance");

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 secondClaim = sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), firstClaim + secondClaim, 0.0001e18, "receiver balance");
    }

    function test_topUpStream_worksIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpStream(bob, shares, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(sharesStreaming)), shares * 2, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");
    }

    /// *** #openStreamUsingPermit *** ///

    function test_openStreamUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 shares = _depositToVault(dave, 1 ether);
        uint256 duration = 2 days;
        uint256 nonce = vault.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC4626(address(vault)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(sharesStreaming), shares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        sharesStreaming.openStreamUsingPermit(alice, shares, duration, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), shares, "sharesStreaming's balance");

        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(dave, alice));
        assertEq(stream.shares, shares, "totalShares");
        assertEq(stream.ratePerSecond, shares / duration, "ratePerSecond");
        assertEq(stream.startTime, block.timestamp, "startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "lastClaimTime");
    }

    /// *** #multicall *** ///

    function test_multicall() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(sharesStreaming.openStream, (bob, shares / 2, duration));
        data[1] = abi.encodeCall(sharesStreaming.openStream, (carol, shares / 2, duration));

        sharesStreaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, shares / 2, "bob's stream shares");
        stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(stream.shares, shares / 2, "carol's stream shares");
    }

    function test_oneStreamertoMultipleReceivers() public {
        // alice streams to bob and carol
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 bobsStreamShares = shares / 4;
        uint256 bobsStreamDuration = 1 days;
        uint256 carolsStreamShares = shares - bobsStreamShares;
        uint256 carolsStreamDuration = 3 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openStream(bob, bobsStreamShares, bobsStreamDuration);
        sharesStreaming.openStream(carol, carolsStreamShares, carolsStreamDuration);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);

        assertEq(sharesStreaming.previewClaim(alice, bob), 0, "previewClaim(alice, bob)");
        SharesStreamingV2.Stream memory bobsStream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(bobsStream.shares, bobsStreamShares, "bob's stream shares");
        assertEq(bobsStream.ratePerSecond, bobsStreamShares / bobsStreamDuration, "bob's stream rate per second");
        assertEq(bobsStream.startTime, block.timestamp, "bob's stream start time");
        assertEq(bobsStream.lastClaimTime, block.timestamp, "bob's stream last claim time");

        assertEq(sharesStreaming.previewClaim(alice, carol), 0, "previewClaim(alice, carol)");
        SharesStreamingV2.Stream memory carolsStream =
            sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(carolsStream.shares, carolsStreamShares, "carol's stream shares");
        assertEq(
            carolsStream.ratePerSecond, carolsStreamShares / carolsStreamDuration, "carol's stream rate per second"
        );
        assertEq(carolsStream.startTime, block.timestamp, "carol's stream start time");
        assertEq(carolsStream.lastClaimTime, block.timestamp, "carol's stream last claim time");

        vm.warp(block.timestamp + 36 hours);

        assertEq(sharesStreaming.previewClaim(alice, bob), bobsStreamShares, "previewClaim(alice, bob)");
        assertApproxEqRel(
            sharesStreaming.previewClaim(alice, carol), carolsStreamShares / 2, 0.0001e18, "previewClaim(alice, carol)"
        );

        vm.prank(bob);
        uint256 bobsClaim = sharesStreaming.claim(alice);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares - bobsClaim, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(bobsClaim, bobsStreamShares, "bobsClaim");

        vm.prank(carol);
        uint256 carolsClaim = sharesStreaming.claim(alice);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares - bobsClaim - carolsClaim, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
        assertApproxEqRel(carolsClaim, carolsStreamShares / 2, 0.0001e18, "claimed");

        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "bob's stream not deleted - totalShares");
        assertEq(stream.ratePerSecond, 0, "bob's stream not deleted - ratePerSecond");
        assertEq(stream.startTime, 0, "bob's stream not deleted - startTime");
        assertEq(stream.lastClaimTime, 0, "bob's stream not deleted - lastClaimTime");

        stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(stream.shares, carolsStreamShares - carolsClaim, "carol's stream - totalShares");
        assertEq(stream.ratePerSecond, carolsStreamShares / carolsStreamDuration, "carol's stream - ratePerSecond");
        assertEq(stream.startTime, carolsStream.startTime, "carol's stream - startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "carol's stream - lastClaimTime");

        vm.startPrank(alice);
        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        sharesStreaming.closeStream(bob);

        sharesStreaming.closeStream(carol);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), shares - bobsClaim - carolsClaim, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
    }

    function test_multipleStreamersToSingleReceiver() public {
        // alice and bob stream to carol
        uint256 alicesShares = _depositToVault(alice, 1e18);
        uint256 bobsShares = _depositToVault(bob, 2e18);

        _openStream(alice, carol, alicesShares, 1 days);
        _openStream(bob, carol, bobsShares, 2 days);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);

        vm.startPrank(carol);
        vm.expectRevert(SharesStreamingV2.NoSharesToClaim.selector);
        sharesStreaming.claim(alice);
        vm.expectRevert(SharesStreamingV2.NoSharesToClaim.selector);
        sharesStreaming.claim(bob);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(sharesStreaming.previewClaim(alice, carol), alicesShares, "previewClaim(alice, carol)");
        assertApproxEqRel(
            sharesStreaming.previewClaim(bob, carol), bobsShares / 2, 0.0001e18, "previewClaim(bob, carol)"
        );

        vm.startPrank(carol);
        uint256 claimFromAlice = sharesStreaming.claim(alice);
        uint256 claimFromBob = sharesStreaming.claim(bob);
        vm.stopPrank();

        assertEq(
            vault.balanceOf(address(sharesStreaming)),
            alicesShares + bobsShares - claimFromAlice - claimFromBob,
            "sharesStreaming balance after claims"
        );
        assertEq(vault.balanceOf(alice), 0, "alice's balance after claims");
        assertEq(vault.balanceOf(bob), 0, "bob's balance after claims");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after claims");

        vm.prank(alice);
        vm.expectRevert(SharesStreamingV2.StreamDoesNotExist.selector);
        sharesStreaming.closeStream(carol);

        vm.prank(bob);
        sharesStreaming.closeStream(carol);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance after closing");
        assertEq(vault.balanceOf(alice), 0, "alice's balance after closing");
        assertEq(vault.balanceOf(bob), bobsShares - claimFromBob, "bob's balance after closing");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after closing");
    }

    // TODO:
    // test from multiple streamers to single receiver - done
    // test single streamer to multiple receivers - done
    // test consecutive calls to claimShares and closeShareStream - done
    // top up stream - done
    // top up stream and claim - done
    // top up stream and close - done
    // top up stream and claim and close - done
    // open with permit - done
    // error types - done
    // events - done
    // multicall - done
    // refactor - done
    // cleanup / renaming
    // upgrade open zeppelin
    // add docs - done
    // separate tests & contracts - done
    // top up using permit
    // prevent reentrancy?
    // gas optimizations
    // improve integer operations precision?
    // fork/fuzz tests

    function _depositToVault(address _account, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_account);

        asset.mint(_account, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _account);

        vm.stopPrank();
    }

    function _openStream(address _streamer, address _receiver, uint256 _shares, uint256 _duration) internal {
        vm.startPrank(_streamer);

        vault.approve(address(sharesStreaming), _shares);
        sharesStreaming.openStream(_receiver, _shares, _duration);

        vm.stopPrank();
    }
}
