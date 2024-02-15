// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "../src/common/Errors.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract ERC20StreamingTest is Test {
    using FixedPointMathLib for uint256;

    MockERC20 public asset;
    MockERC4626 public vault;
    ERC20Streaming public streaming;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    event OpenStream(address indexed streamer, address indexed receiver, uint256 amount, uint256 duration);
    event Claim(address indexed streamer, address indexed receiver, uint256 claimed);
    event CloseStream(address indexed streamer, address indexed receiver, uint256 remaining, uint256 claimed);
    event TopUpStream(address indexed streamer, address indexed receiver, uint256 added, uint256 addedDuration);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        streaming = new ERC20Streaming(IERC4626(address(vault)));
    }

    // *** constructor *** ///

    function test_constructor_failsForAddress0() public {
        vm.expectRevert(AddressZero.selector);
        new ERC20Streaming(IERC4626(address(0)));
    }

    // *** #openStream *** ///

    function test_openStream_createsNewStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        streaming.openStream(bob, shares, duration);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(streaming)), shares);

        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, shares, "stream amount");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "stream rate per second");
        assertEq(stream.startTime, block.timestamp, "stream start time");
        assertEq(stream.lastClaimTime, block.timestamp, "stream last claim time");
    }

    function test_openStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 2 days;

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectEmit(true, true, true, true);
        emit OpenStream(alice, bob, shares, duration);

        streaming.openStream(bob, shares, duration);
    }

    function test_openStream_failsIfStreamAlreadyExists() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        streaming.openStream(bob, shares, 1 days);
        vm.stopPrank();

        shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(ERC20Streaming.StreamAlreadyExists.selector);
        streaming.openStream(bob, shares, 1 days);
    }

    function test_openStream_worksIfExistingStreamHasExpiredAndIsNotClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        streaming.openStream(bob, shares, duration);
        vm.stopPrank();

        uint256 shares2 = _depositToVault(alice, 3e18);
        uint256 duration2 = 2 days;

        vm.startPrank(alice);
        vault.approve(address(streaming), shares2);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit CloseStream(alice, bob, 0, shares);

        vm.expectEmit(true, true, true, true);
        emit OpenStream(alice, bob, shares2, duration2);

        streaming.openStream(bob, shares2, duration2);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver's balance");
        assertEq(vault.balanceOf(address(streaming)), shares2, "contract balance");
    }

    function test_openStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(AddressZero.selector);
        streaming.openStream(address(0), shares, 1 days);
    }

    function test_openStream_failsIfAmountIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(AmountZero.selector);
        streaming.openStream(bob, 0, 1 days);
    }

    function test_openStream_failsIfAmountIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert();
        streaming.openStream(bob, shares + 1, 1 days);
    }

    function test_openStream_failsIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(ERC20Streaming.ZeroDuration.selector);
        streaming.openStream(bob, shares, 0);
    }

    function test_openStream_failsIfAmountIsGreaterThanBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares + 1);

        vm.expectRevert();
        streaming.openStream(bob, shares + 1, 1 days);
    }

    function test_openStream_failsIfReceiverIsSameAsCaller() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(CannotOpenStreamToSelf.selector);
        streaming.openStream(alice, shares, 1 days);
    }

    // *** #claim *** ///

    function test_claim_failsIfStreamDoesNotExist() public {
        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(bob);
        streaming.claim(alice, bob);
    }

    function test_claim_worksWhenStreamIsComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "amount");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_claim_worksWhenStreamIsNotComplete() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares / 2, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");
        assertApproxEqRel(claimed, shares / 2, 0.0001e18, "claimed");
    }

    function test_claim_transfersClaimedAmountToSpecifiedAccount() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        // send claimed shares to carol
        uint256 claimed = streaming.claim(alice, carol);

        assertEq(vault.balanceOf(bob), 0, "bob's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(carol), claimed, 0.0001e18, "carol's balance");
    }

    function test_claim_failsIfTransferToAccountIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        vm.expectRevert(AddressZero.selector);
        streaming.claim(alice, address(0));
    }

    function test_claim_twoConsecutiveClaims() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares / 2, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        vm.expectRevert(ERC20Streaming.NoTokensToClaim.selector);
        vm.prank(bob);
        streaming.claim(alice, bob);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares / 4, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
    }

    function test_claim_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        _openStream(alice, bob, shares, duration);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + duration + 1);

        // also emits closeStream if stream is complete
        vm.expectEmit(true, true, true, true);
        emit CloseStream(alice, bob, 0, 0);

        vm.expectEmit(true, true, true, true);
        emit Claim(alice, bob, shares);

        vm.startPrank(bob);
        streaming.claim(alice, bob);
    }

    // *** #closeStream *** ///

    function test_closeStream_failsIfStreamDoesNotExist() public {
        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(bob);
        streaming.closeStream(bob);
    }

    function test_closeStream_transfersUnclaimedAmountToReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        streaming.closeStream(bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "amount");
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
        emit CloseStream(alice, bob, 0, shares);

        vm.startPrank(alice);
        streaming.closeStream(bob);
    }

    function test_closeStream_failsIfAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.prank(alice);
        streaming.closeStream(bob);

        vm.expectRevert(StreamDoesNotExist.selector);
        vm.prank(alice);
        streaming.closeStream(bob);
    }

    function test_closeStream_transfersRemainingUnclaimedAmountToReceiverAfterLastClaim() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares / 2, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        // around 1/4 should be claimable
        vm.warp(block.timestamp + 6 hours);

        (uint256 remaining, uint256 unclaimed) = streaming.previewCloseStream(alice, bob);

        vm.prank(alice);
        streaming.closeStream(bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
        assertApproxEqRel(vault.balanceOf(alice), shares / 4, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(alice), remaining, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
        assertApproxEqRel(vault.balanceOf(bob), claimed + unclaimed, 0.0001e18, "receiver balance");
        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
    }

    function test_closeStream_transfersRemainingAmountToStreamer() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares / 2, 0.0001e18, "contract balance 1");
        assertEq(vault.balanceOf(alice), 0, "alice's balance 1 ");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 1");

        vm.prank(alice);
        streaming.closeStream(bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance 2");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.0001e18, "alice's balance 2");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 2");
    }

    // *** #topUpStream *** ///

    function test_topUpStream_addsAmountToStreamAndExtendsDuration() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _openStream(alice, bob, shares, duration);

        uint256 streamId = streaming.getStreamId(alice, bob);
        ERC20Streaming.Stream memory stream = streaming.getStream(streamId);

        vm.warp(block.timestamp + 12 hours);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(streaming), shares);
        streaming.topUpStream(bob, additionalShares, additionalDuration);

        assertEq(vault.balanceOf(address(streaming)), shares + additionalShares, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streaming.Stream memory updatedStream = streaming.getStream(streamId);

        assertEq(updatedStream.amount, shares + additionalShares, "amount");
        assertApproxEqRel(
            updatedStream.ratePerSecond,
            (shares + additionalShares).divWadUp(duration + additionalDuration),
            0.00001e18,
            "ratePerSecond"
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
        vault.approve(address(streaming), shares);

        vm.expectEmit(true, true, true, true);
        emit TopUpStream(alice, bob, additionalShares, additionalDuration);
        streaming.topUpStream(bob, additionalShares, additionalDuration);
    }

    function test_topUpStream_failsIfSAmountIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(AmountZero.selector);
        streaming.topUpStream(bob, 0, 1 days);
    }

    function test_topUpStream_failsIfAmountIsGreaterThanAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert();
        streaming.topUpStream(bob, shares + 1, 1 days);
    }

    function test_topUpStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(AddressZero.selector);
        streaming.topUpStream(address(0), shares, 1 days);
    }

    function test_topUpStream_failsIfStreamDoesNotExist() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(StreamDoesNotExist.selector);
        streaming.topUpStream(bob, shares, 1 days);
    }

    function test_topUpStream_failsIfStreamIsExpired() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        vm.expectRevert(ERC20Streaming.StreamExpired.selector);
        streaming.topUpStream(bob, shares, 1 days);
    }

    function test_topUpSERC20StreamingksAfterSomeAmountIsClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 firstClaim = streaming.claim(alice, bob);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(streaming), shares);
        streaming.topUpStream(bob, shares, 1 days);
        vm.stopPrank();

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares * 3 / 2, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), firstClaim, "receiver balance");

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 secondClaim = streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), firstClaim + secondClaim, 0.0001e18, "receiver balance");
    }

    function test_topUpStream_worksWhenAddedDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(streaming), shares);
        streaming.topUpStream(bob, shares, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(streaming)), shares * 2, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streaming)), shares, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");

        vm.prank(alice);
        streaming.closeStream(bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
        assertApproxEqRel(vault.balanceOf(alice), shares, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");
    }

    function test_topUpStream_failsIfRatePerSecondDrops() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _openStream(alice, bob, shares, duration);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        // top up with same amount of shares and 2x the initial duration will decrease the rate per second
        vm.expectRevert(ERC20Streaming.RatePerSecondDecreased.selector);
        streaming.topUpStream(bob, shares, duration * 2);
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
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(streaming), shares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        streaming.openStreamUsingPermit(alice, shares, duration, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(streaming)), shares, "contract balance");

        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(dave, alice));
        assertEq(stream.amount, shares, "amount");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "ratePerSecond");
        assertEq(stream.startTime, block.timestamp, "startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "lastClaimTime");
    }

    /// *** #topUpStreamUsingPermit *** ///

    function test_topUpStreamUsingPermit() public {
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
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(streaming), additionalShares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        streaming.topUpStreamUsingPermit(bob, additionalShares, additionalDuration, deadline, v, r, s);

        assertEq(vault.balanceOf(address(streaming)), shares + additionalShares, "contract balance");
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streaming.Stream memory updatedStream = streaming.getStream(streaming.getStreamId(dave, bob));
        assertEq(updatedStream.amount, shares + additionalShares, "amount");
        assertApproxEqRel(
            updatedStream.ratePerSecond,
            (shares + additionalShares).divWadUp(duration + additionalDuration),
            0.00001e18,
            "ratePerSecond"
        );

        // advance time to the half way point of the stream
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        streaming.claim(dave, bob);

        assertApproxEqRel(
            vault.balanceOf(address(streaming)), (shares + additionalShares) / 2, 0.0001e18, "contract balance"
        );
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertApproxEqRel(vault.balanceOf(bob), (shares + additionalShares) / 2, 0.0001e18, "receiver balance");
    }

    /// *** #multicall *** ///

    function test_multicall() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(streaming.openStream, (bob, shares / 2, duration));
        data[1] = abi.encodeCall(streaming.openStream, (carol, shares / 2, duration));

        streaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, shares / 2, "bob's stream shares");
        stream = streaming.getStream(streaming.getStreamId(alice, carol));
        assertEq(stream.amount, shares / 2, "carol's stream shares");
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
        vault.approve(address(streaming), shares);

        streaming.openStream(bob, bobsStreamShares, bobsStreamDuration);
        streaming.openStream(carol, carolsStreamShares, carolsStreamDuration);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.balanceOf(address(streaming)), shares);

        assertEq(streaming.previewClaim(alice, bob), 0, "previewClaim(alice, bob)");
        ERC20Streaming.Stream memory bobsStream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(bobsStream.amount, bobsStreamShares, "bob's stream shares");
        assertEq(
            bobsStream.ratePerSecond, bobsStreamShares.divWadUp(bobsStreamDuration), "bob's stream rate per second"
        );
        assertEq(bobsStream.startTime, block.timestamp, "bob's stream start time");
        assertEq(bobsStream.lastClaimTime, block.timestamp, "bob's stream last claim time");

        assertEq(streaming.previewClaim(alice, carol), 0, "previewClaim(alice, carol)");
        ERC20Streaming.Stream memory carolsStream = streaming.getStream(streaming.getStreamId(alice, carol));
        assertEq(carolsStream.amount, carolsStreamShares, "carol's stream shares");
        assertEq(
            carolsStream.ratePerSecond,
            carolsStreamShares.divWadUp(carolsStreamDuration),
            "carol's stream rate per second"
        );
        assertEq(carolsStream.startTime, block.timestamp, "carol's stream start time");
        assertEq(carolsStream.lastClaimTime, block.timestamp, "carol's stream last claim time");

        vm.warp(block.timestamp + 36 hours);

        assertEq(streaming.previewClaim(alice, bob), bobsStreamShares, "previewClaim(alice, bob)");
        assertApproxEqRel(
            streaming.previewClaim(alice, carol), carolsStreamShares / 2, 0.0001e18, "previewClaim(alice, carol)"
        );

        vm.prank(bob);
        uint256 bobsClaim = streaming.claim(alice, bob);

        assertEq(vault.balanceOf(address(streaming)), shares - bobsClaim, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(bobsClaim, bobsStreamShares, "bobsClaim");

        vm.prank(carol);
        uint256 carolsClaim = streaming.claim(alice, carol);

        assertEq(vault.balanceOf(address(streaming)), shares - bobsClaim - carolsClaim, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
        assertApproxEqRel(carolsClaim, carolsStreamShares / 2, 0.0001e18, "claimed");

        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "bob's stream not deleted - amount");
        assertEq(stream.ratePerSecond, 0, "bob's stream not deleted - ratePerSecond");
        assertEq(stream.startTime, 0, "bob's stream not deleted - startTime");
        assertEq(stream.lastClaimTime, 0, "bob's stream not deleted - lastClaimTime");

        stream = streaming.getStream(streaming.getStreamId(alice, carol));
        assertEq(stream.amount, carolsStreamShares - carolsClaim, "carol's stream - amount");
        assertEq(
            stream.ratePerSecond, carolsStreamShares.divWadUp(carolsStreamDuration), "carol's stream - ratePerSecond"
        );
        assertEq(stream.startTime, carolsStream.startTime, "carol's stream - startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "carol's stream - lastClaimTime");

        vm.startPrank(alice);
        vm.expectRevert(StreamDoesNotExist.selector);
        streaming.closeStream(bob);

        streaming.closeStream(carol);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance");
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
        streaming.claim(alice, carol);
        vm.expectRevert(ERC20Streaming.NoTokensToClaim.selector);
        streaming.claim(bob, carol);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(streaming.previewClaim(alice, carol), alicesShares, "previewClaim(alice, carol)");
        assertApproxEqRel(streaming.previewClaim(bob, carol), bobsShares / 2, 0.0001e18, "previewClaim(bob, carol)");

        vm.startPrank(carol);
        uint256 claimFromAlice = streaming.claim(alice, carol);
        uint256 claimFromBob = streaming.claim(bob, carol);
        vm.stopPrank();

        assertEq(
            vault.balanceOf(address(streaming)),
            alicesShares + bobsShares - claimFromAlice - claimFromBob,
            "contract balance after claims"
        );
        assertEq(vault.balanceOf(alice), 0, "alice's balance after claims");
        assertEq(vault.balanceOf(bob), 0, "bob's balance after claims");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after claims");

        vm.prank(alice);
        vm.expectRevert(StreamDoesNotExist.selector);
        streaming.closeStream(carol);

        vm.prank(bob);
        streaming.closeStream(carol);

        assertEq(vault.balanceOf(address(streaming)), 0, "contract balance after closing");
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

        console2.log("amount", shares);
        console2.log("_duration", _duration);
        console2.log("streamedPerSecond", sharesStreamedPerSecond);

        vm.startPrank(alice);
        vault.approve(address(streaming), shares);

        streaming.openStream(bob, shares, _duration);

        vm.stopPrank();

        vm.warp(block.timestamp + _duration / 2);

        uint256 expectedSharesToClaim = shares / 2;

        // claim shares
        uint256 previewClaim = streaming.previewClaim(alice, bob);
        assertApproxEqAbs(previewClaim, expectedSharesToClaim, sharesStreamedPerSecond, "previewClaim");
        console2.log("previewClaim", previewClaim);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assertEq(vault.balanceOf(bob), previewClaim, "claimed shares");
        assertEq(streaming.previewClaim(alice, bob), 0, "previewClaim after claim");

        // close streams
        vm.startPrank(alice);
        streaming.closeStream(bob);

        assertEq(vault.balanceOf(address(streaming)), 0, "streamHub's shares");
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

        vault.approve(address(streaming), _shares);
        streaming.openStream(_receiver, _shares, _duration);

        vm.stopPrank();
    }
}
