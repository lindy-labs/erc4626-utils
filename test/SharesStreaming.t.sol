// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "../src/common/Errors.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract SharesStreamingTest is Test {
    using FixedPointMathLib for uint256;

    MockERC20 public asset;
    MockERC4626 public vault;
    ERC20Streaming public sharesStreaming;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    event OpenSharesStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseSharesStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpSharesStream(
        address indexed streamer, address indexed receiver, uint256 addedShares, uint256 addedDuration
    );

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        sharesStreaming = new ERC20Streaming(IERC4626(address(vault)));
    }

    // *** constructor *** ///

    function test_constructor_failsForAddress0() public {
        vm.expectRevert(AddressZero.selector);
        new ERC20Streaming(IERC4626(address(0)));
    }

    // *** #openShareStream *** ///

    function test_openShareStream_createsNewStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openSharesStream(bob, shares, duration);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);

        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, shares, "stream shares");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "stream rate per second");
        assertEq(stream.startTime, block.timestamp, "stream start time");
        assertEq(stream.lastClaimTime, block.timestamp, "stream last claim time");
    }

    function test_openShareStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 2 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectEmit(true, true, true, true);
        emit OpenSharesStream(alice, bob, shares, duration);

        sharesStreaming.openSharesStream(bob, shares, duration);
    }

    function test_openShareStream_failsIfStreamAlreadyExists() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openSharesStream(bob, shares, 1 days);
        vm.stopPrank();

        shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(ERC20Streaming.StreamAlreadyExists.selector);
        sharesStreaming.openSharesStream(bob, shares, 1 days);
    }

    function test_openShareStream_worksIfExistingStreamHasExpiredAndIsNotClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openSharesStream(bob, shares, duration);
        vm.stopPrank();

        uint256 shares2 = _depositToVault(alice, 3e18);
        uint256 duration2 = 2 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares2);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit CloseSharesStream(alice, bob, 0, shares);

        vm.expectEmit(true, true, true, true);
        emit OpenSharesStream(alice, bob, shares2, duration2);

        sharesStreaming.openSharesStream(bob, shares2, duration2);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver's balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), shares2, "sharesStreaming's balance");
    }

    function test_openShareStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(AddressZero.selector);
        sharesStreaming.openSharesStream(address(0), shares, 1 days);
    }

    function test_openShareStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(AmountZero.selector);
        sharesStreaming.openSharesStream(bob, 0, 1 days);
    }

    function test_openShareStream_failsIfSharesIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(TransferExceedsAllowance.selector);
        sharesStreaming.openSharesStream(bob, shares + 1, 1 days);
    }

    function test_openShareStream_failsIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(ERC20Streaming.ZeroDuration.selector);
        sharesStreaming.openSharesStream(bob, shares, 0);
    }

    function test_openShareStream_failsIfSharesIsGreaterThanBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares + 1);

        vm.expectRevert();
        sharesStreaming.openSharesStream(bob, shares + 1, 1 days);
    }

    function test_openShareStream_failsIfReceiverIsSameAsCaller() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(CannotOpenStreamToSelf.selector);
        sharesStreaming.openSharesStream(alice, shares, 1 days);
    }

    // *** #claimShares *** ///

    function test_claimShares_failsIfStreamDoesNotExist() public {
        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);
    }

    function test_claimShares_worksWhenStreamIsComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "totalShares");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_claimShares_worksWhenStreamIsNotComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");
        assertApproxEqRel(claimed, shares / 2, 0.0001e18, "claimed");
    }

    function test_claimShares_transfersSharesToSpecifiedAccount() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        // send claimed shares to carol
        uint256 claimed = sharesStreaming.claimShares(alice, carol);

        assertEq(vault.balanceOf(bob), 0, "bob's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(carol), claimed, 0.0001e18, "carol's balance");
    }

    function test_claimShares_failsIfTransferToAccountIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        vm.expectRevert(AddressZero.selector);
        sharesStreaming.claimShares(alice, address(0));
    }

    function test_claimShares_twoConsecutiveClaims() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        vm.expectRevert(ERC20Streaming.NoTokensToClaim.selector);
        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 4, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
    }

    function test_claimShares_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + duration + 1);

        // also emits CloseSharesStream if stream is complete
        vm.expectEmit(true, true, true, true);
        emit CloseSharesStream(alice, bob, 0, 0);

        vm.expectEmit(true, true, true, true);
        emit ClaimShares(alice, bob, shares);

        vm.startPrank(bob);
        sharesStreaming.claimShares(alice, bob);
    }

    // *** #closeSharesStream *** ///

    function test_closeSharesStream_failsIfStreamDoesNotExist() public {
        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(bob);
        sharesStreaming.closeSharesStream(bob);
    }

    function test_closeSharesStream_transfersUnclaimedSharesToReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "totalShares");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_closeSharesStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit CloseSharesStream(alice, bob, 0, shares);

        vm.startPrank(alice);
        sharesStreaming.closeSharesStream(bob);
    }

    function test_closeSharesStream_failsIfAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);

        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);
    }

    function test_closeSharesStream_transfersRemainingUnclaimedSharesToReceiverAfterLastClaim() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        // around 1/4 should be claimable
        vm.warp(block.timestamp + 6 hours);

        (uint256 remaining, uint256 unclaimed) = sharesStreaming.previewCloseSharesStream(alice, bob);

        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares / 4, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(alice), remaining, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
        assertApproxEqRel(vault.balanceOf(bob), claimed + unclaimed, 0.0001e18, "receiver balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
    }

    function test_closeSharesStream_transfersRemainingSharesToStreamer() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance 1");
        assertEq(vault.balanceOf(alice), 0, "alice's balance 1 ");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 1");

        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance 2");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.0001e18, "alice's balance 2");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 2");
    }

    // *** #topUpSharesStream *** ///

    function test_topUpSharesStream_addsSharesAndExtendsDuration() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _openStream(alice, bob, shares, duration);

        uint256 streamId = sharesStreaming.getStreamId(alice, bob);
        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(streamId);

        vm.warp(block.timestamp + 12 hours);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpSharesStream(bob, additionalShares, additionalDuration);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares + additionalShares, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streaming.Stream memory updatedStream = sharesStreaming.getStream(streamId);

        assertEq(updatedStream.shares, shares + additionalShares, "totalShares");
        assertApproxEqRel(
            updatedStream.ratePerSecond,
            (shares + additionalShares).divWadUp(duration + additionalDuration),
            0.00001e18,
            "ratePerSecond"
        );
        assertEq(updatedStream.startTime, stream.startTime, "startTime");
        assertEq(updatedStream.lastClaimTime, stream.lastClaimTime, "lastClaimTime");
    }

    function test_topUpSharesStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectEmit(true, true, true, true);
        emit TopUpSharesStream(alice, bob, additionalShares, additionalDuration);
        sharesStreaming.topUpSharesStream(bob, additionalShares, additionalDuration);
    }

    function test_topUpSharesStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(AmountZero.selector);
        sharesStreaming.topUpSharesStream(bob, 0, 1 days);
    }

    function test_topUpSharesStream_failsIfSharesIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(TransferExceedsAllowance.selector);
        sharesStreaming.topUpSharesStream(bob, shares + 1, 1 days);
    }

    function test_topUpSharesStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(AddressZero.selector);
        sharesStreaming.topUpSharesStream(address(0), shares, 1 days);
    }

    function test_topUpSharesStream_failsIfStreamDoesNotExist() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(StreamDoesNotExist.selector);
        sharesStreaming.topUpSharesStream(bob, shares, 1 days);
    }

    function test_topUpSharesStream_failsIfStreamIsExpired() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert(ERC20Streaming.StreamExpired.selector);
        sharesStreaming.topUpSharesStream(bob, shares, 1 days);
    }

    function test_topUpSERC20StreamingksAfterSomeSharesAreClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 firstClaim = sharesStreaming.claimShares(alice, bob);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpSharesStream(bob, shares, 1 days);
        vm.stopPrank();

        assertApproxEqRel(
            vault.balanceOf(address(sharesStreaming)), shares * 3 / 2, 0.0001e18, "sharesStreaming balance"
        );
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), firstClaim, "receiver balance");

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 secondClaim = sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), firstClaim + secondClaim, 0.0001e18, "receiver balance");
    }

    function test_topUpSharesStream_worksIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpSharesStream(bob, shares, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(sharesStreaming)), shares * 2, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");

        vm.prank(alice);
        sharesStreaming.closeSharesStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");
    }

    function test_topUpSharesStream_failsIfRatePerSecondDrops() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _openStream(alice, bob, shares, duration);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        // top up with same amount of shares and 2x the initial duration will decrease the rate per second
        vm.expectRevert(ERC20Streaming.RatePerSecondDecreased.selector);
        sharesStreaming.topUpSharesStream(bob, shares, duration * 2);
    }

    /// *** #openSharesSERC20Streamingt *** ///

    function test_openSharesStreamUsingPermit() public {
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
        sharesStreaming.openSharesStreamUsingPermit(alice, shares, duration, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(sharesStreaming)), shares, "sharesStreaming's balance");

        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(dave, alice));
        assertEq(stream.shares, shares, "totalShares");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "ratePerSecond");
        assertEq(stream.startTime, block.timestamp, "startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "lastClaimTime");
    }

    /// *** #topUpSharesStreamUsingPermit *** ///

    function test_topUpSharesStreamUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);
        uint256 shares = _depositToVault(dave, 1e18);
        uint256 duration = 1 days;
        _openStream(dave, bob, shares, duration);

        vm.warp(block.timestamp + 12 hours);

        // top up params
        uint256 additionalShares = _depositToVault(dave, 1e18);
        uint256 additionalDuration = 1 days;
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
                    keccak256(
                        abi.encode(PERMIT_TYPEHASH, dave, address(sharesStreaming), additionalShares, nonce, deadline)
                    )
                )
            )
        );

        vm.prank(dave);
        sharesStreaming.topUpSharesStreamUsingPermit(bob, additionalShares, additionalDuration, deadline, v, r, s);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares + additionalShares, "sharesStreaming balance");
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streaming.Stream memory updatedStream = sharesStreaming.getStream(sharesStreaming.getStreamId(dave, bob));
        assertEq(updatedStream.shares, shares + additionalShares, "totalShares");
        assertApproxEqRel(
            updatedStream.ratePerSecond,
            (shares + additionalShares).divWadUp(duration + additionalDuration),
            0.00001e18,
            "ratePerSecond"
        );

        // advance time to the half way point of the stream
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        sharesStreaming.claimShares(dave, bob);

        assertApproxEqRel(
            vault.balanceOf(address(sharesStreaming)),
            (shares + additionalShares) / 2,
            0.0001e18,
            "sharesStreaming balance"
        );
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertApproxEqRel(vault.balanceOf(bob), (shares + additionalShares) / 2, 0.0001e18, "receiver balance");
    }

    /// *** #multicall *** ///

    function test_multicall() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(sharesStreaming.openSharesStream, (bob, shares / 2, duration));
        data[1] = abi.encodeCall(sharesStreaming.openSharesStream, (carol, shares / 2, duration));

        sharesStreaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, shares / 2, "bob's stream shares");
        stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(stream.shares, shares / 2, "carol's stream shares");
    }

    /// *** multiple streamers / receivers *** ///

    function test_oneStreamertoMultipleReceivers() public {
        // alice streams to bob and carol
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 bobsStreamShares = shares / 4;
        uint256 bobsStreamDuration = 1 days;
        uint256 carolsStreamShares = shares - bobsStreamShares;
        uint256 carolsStreamDuration = 3 days;

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openSharesStream(bob, bobsStreamShares, bobsStreamDuration);
        sharesStreaming.openSharesStream(carol, carolsStreamShares, carolsStreamDuration);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);

        assertEq(sharesStreaming.previewClaimShares(alice, bob), 0, "previewClaim(alice, bob)");
        ERC20Streaming.Stream memory bobsStream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(bobsStream.shares, bobsStreamShares, "bob's stream shares");
        assertEq(
            bobsStream.ratePerSecond, bobsStreamShares.divWadUp(bobsStreamDuration), "bob's stream rate per second"
        );
        assertEq(bobsStream.startTime, block.timestamp, "bob's stream start time");
        assertEq(bobsStream.lastClaimTime, block.timestamp, "bob's stream last claim time");

        assertEq(sharesStreaming.previewClaimShares(alice, carol), 0, "previewClaim(alice, carol)");
        ERC20Streaming.Stream memory carolsStream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(carolsStream.shares, carolsStreamShares, "carol's stream shares");
        assertEq(
            carolsStream.ratePerSecond,
            carolsStreamShares.divWadUp(carolsStreamDuration),
            "carol's stream rate per second"
        );
        assertEq(carolsStream.startTime, block.timestamp, "carol's stream start time");
        assertEq(carolsStream.lastClaimTime, block.timestamp, "carol's stream last claim time");

        vm.warp(block.timestamp + 36 hours);

        assertEq(sharesStreaming.previewClaimShares(alice, bob), bobsStreamShares, "previewClaim(alice, bob)");
        assertApproxEqRel(
            sharesStreaming.previewClaimShares(alice, carol),
            carolsStreamShares / 2,
            0.0001e18,
            "previewClaim(alice, carol)"
        );

        vm.prank(bob);
        uint256 bobsClaim = sharesStreaming.claimShares(alice, bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares - bobsClaim, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(bobsClaim, bobsStreamShares, "bobsClaim");

        vm.prank(carol);
        uint256 carolsClaim = sharesStreaming.claimShares(alice, carol);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares - bobsClaim - carolsClaim, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
        assertApproxEqRel(carolsClaim, carolsStreamShares / 2, 0.0001e18, "claimed");

        ERC20Streaming.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.shares, 0, "bob's stream not deleted - totalShares");
        assertEq(stream.ratePerSecond, 0, "bob's stream not deleted - ratePerSecond");
        assertEq(stream.startTime, 0, "bob's stream not deleted - startTime");
        assertEq(stream.lastClaimTime, 0, "bob's stream not deleted - lastClaimTime");

        stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, carol));
        assertEq(stream.shares, carolsStreamShares - carolsClaim, "carol's stream - totalShares");
        assertEq(
            stream.ratePerSecond, carolsStreamShares.divWadUp(carolsStreamDuration), "carol's stream - ratePerSecond"
        );
        assertEq(stream.startTime, carolsStream.startTime, "carol's stream - startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "carol's stream - lastClaimTime");

        vm.startPrank(alice);
        vm.expectRevert(StreamDoesNotExist.selector);
        sharesStreaming.closeSharesStream(bob);

        sharesStreaming.closeSharesStream(carol);

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
        vm.expectRevert(ERC20Streaming.NoTokensToClaim.selector);
        sharesStreaming.claimShares(alice, carol);
        vm.expectRevert(ERC20Streaming.NoTokensToClaim.selector);
        sharesStreaming.claimShares(bob, carol);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(sharesStreaming.previewClaimShares(alice, carol), alicesShares, "previewClaim(alice, carol)");
        assertApproxEqRel(
            sharesStreaming.previewClaimShares(bob, carol), bobsShares / 2, 0.0001e18, "previewClaim(bob, carol)"
        );

        vm.startPrank(carol);
        uint256 claimFromAlice = sharesStreaming.claimShares(alice, carol);
        uint256 claimFromBob = sharesStreaming.claimShares(bob, carol);
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
        vm.expectRevert(StreamDoesNotExist.selector);
        sharesStreaming.closeSharesStream(carol);

        vm.prank(bob);
        sharesStreaming.closeSharesStream(carol);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance after closing");
        assertEq(vault.balanceOf(alice), 0, "alice's balance after closing");
        assertEq(vault.balanceOf(bob), bobsShares - claimFromBob, "bob's balance after closing");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after closing");
    }

    /// *** fuzzing *** ///

    function testFuzz_open_claim_close_stream(uint256 _amount, uint256 _duration) public {
        _amount = bound(_amount, 10000, 10000 ether);
        _duration = bound(_duration, 100 seconds, 5000 days);
        uint256 shares = _depositToVault(alice, _amount);
        uint256 sharesStreamedPerSecond = shares.divWadUp(_duration * 1e18);

        console2.log("shares", shares);
        console2.log("_duration", _duration);
        console2.log("sharesStreamedPerSecond", sharesStreamedPerSecond);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openSharesStream(bob, shares, _duration);

        vm.stopPrank();

        vm.warp(block.timestamp + _duration / 2);

        uint256 expectedSharesToClaim = shares / 2;

        // claim shares
        uint256 previewClaim = sharesStreaming.previewClaimShares(alice, bob);
        assertApproxEqAbs(previewClaim, expectedSharesToClaim, sharesStreamedPerSecond, "previewClaim");
        console2.log("previewClaim", previewClaim);

        vm.prank(bob);
        sharesStreaming.claimShares(alice, bob);

        assertEq(vault.balanceOf(bob), previewClaim, "claimed shares");
        assertEq(sharesStreaming.previewClaimShares(alice, bob), 0, "previewClaim after claim");

        // close streams
        vm.startPrank(alice);
        sharesStreaming.closeSharesStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "streamHub's shares");
        assertApproxEqAbs(vault.balanceOf(alice), shares / 2, sharesStreamedPerSecond, "alice's shares");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.01e18, "alice's shares");
    }

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
        sharesStreaming.openSharesStream(_receiver, _shares, _duration);

        vm.stopPrank();
    }
}
