// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./common/TestCommon.sol";
import "src/common/Errors.sol";
import {ERC20Streams} from "src/ERC20Streams.sol";

contract ERC20StreamsTest is TestCommon {
    using FixedPointMathLib for uint256;

    MockERC20 public asset;
    MockERC4626 public vault;
    ERC20Streams public streams;

    event StreamOpened(address indexed streamer, address indexed receiver, uint256 amount, uint256 duration);
    event TokensClaimed(address indexed streamer, address indexed receiver, uint256 claimed);
    event StreamClosed(address indexed streamer, address indexed receiver, uint256 remaining, uint256 claimed);
    event StreamToppedUp(address indexed streamer, address indexed receiver, uint256 added, uint256 addedDuration);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        streams = new ERC20Streams(IERC4626(address(vault)));
    }

    /*
     * --------------------
     *     #constructor
     * --------------------
     */

    function test_constructor_failsForAddress0() public {
        vm.expectRevert(CommonErrors.AddressZero.selector);
        new ERC20Streams(IERC4626(address(0)));
    }

    /*
     * --------------------
     *     #openStream
     * --------------------
     */

    function test_openStream_createsNewStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _approve(alice, shares);

        vm.prank(alice);
        streams.open(bob, shares, duration);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(streams)), shares);

        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(stream.amount, shares, "stream amount");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "stream rate per second");
        assertEq(stream.startTime, block.timestamp, "stream start time");
        assertEq(stream.lastClaimTime, block.timestamp, "stream last claim time");
    }

    function test_openStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 2 days;
        _approve(alice, shares);

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(alice, bob, shares, duration);

        vm.prank(alice);
        streams.open(bob, shares, duration);
    }

    function test_openStream_failsIfStreamAlreadyExists() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.prank(alice);
        streams.open(bob, shares, 1 days);

        shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(ERC20Streams.StreamAlreadyExists.selector);
        vm.prank(alice);
        streams.open(bob, shares, 1 days);
    }

    function test_openStream_worksIfExistingStreamHasExpiredAndIsNotClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _approve(alice, shares);

        vm.prank(alice);
        streams.open(bob, shares, duration);

        uint256 shares2 = _depositToVault(alice, 3e18);
        uint256 duration2 = 2 days;
        _approve(alice, shares2);

        vm.warp(block.timestamp + duration + 1);

        // old stream is closed and new stream is opened
        vm.expectEmit(true, true, true, true);
        emit StreamClosed(alice, bob, 0, shares);

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(alice, bob, shares2, duration2);

        vm.prank(alice);
        streams.open(bob, shares2, duration2);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver's balance");
        assertEq(vault.balanceOf(address(streams)), shares2, "contract balance");
    }

    function test_openStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        streams.open(address(0), shares, 1 days);
    }

    function test_openStream_failsIfAmountIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        streams.open(bob, 0, 1 days);
    }

    function test_openStream_failsIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(ERC20Streams.ZeroDuration.selector);
        vm.prank(alice);
        streams.open(bob, shares, 0);
    }

    function test_openStream_failsIfAmountIsGreaterThanBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert();
        vm.prank(alice);
        streams.open(bob, shares + 1, 1 days);
    }

    function test_openStream_failsIfReceiverIsSameAsCaller() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(ERC20Streams.CannotOpenStreamToSelf.selector);
        vm.prank(alice);
        streams.open(alice, shares, 1 days);
    }

    /*
     * --------------------
     *       #claim
     * --------------------
     */

    function test_claim_failsIfStreamDoesNotExist() public {
        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        vm.prank(bob);
        streams.claim(alice, bob);
    }

    function test_claim_worksWhenStreamIsComplete() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "amount");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_claim_worksWhenStreamIsNotComplete() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares / 2, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");
        assertApproxEqRel(claimed, shares / 2, 0.0001e18, "claimed");
    }

    function test_claim_transfersClaimedAmountToSpecifiedAccount() public {
        _openStream(alice, bob, 1e18, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        // send claimed shares to carol
        uint256 claimed = streams.claim(alice, carol);

        assertEq(vault.balanceOf(bob), 0, "bob's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(carol), claimed, 0.0001e18, "carol's balance");
    }

    function test_claim_failsIfTransferToAccountIsZeroAddress() public {
        _openStream(alice, bob, 1e18, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        vm.expectRevert(CommonErrors.AddressZero.selector);
        streams.claim(alice, address(0));
    }

    function test_claim_twoConsecutiveClaims() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // warp 12 hours so the stream is half claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares / 2, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        vm.expectRevert(ERC20Streams.NoTokensToClaim.selector);
        vm.prank(bob);
        streams.claim(alice, bob);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares / 4, 0.0001e18, "contract balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
    }

    function test_claim_emitsEvent() public {
        uint256 duration = 1 days;
        uint256 shares = _openStream(alice, bob, 1e18, duration);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + duration + 1);

        // also emits closeStream if stream is complete
        vm.expectEmit(true, true, true, true);
        emit StreamClosed(alice, bob, 0, 0);

        vm.expectEmit(true, true, true, true);
        emit TokensClaimed(alice, bob, shares);

        vm.startPrank(bob);
        streams.claim(alice, bob);
    }

    /*
     * --------------------
     *     #closeStream
     * --------------------
     */

    function test_closeStream_failsIfStreamDoesNotExist() public {
        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        vm.prank(bob);
        streams.close(bob);
    }

    function test_closeStream_transfersUnclaimedAmountToReceiver() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // warp 1 day and 1 second so the stream is completely claimable
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        streams.close(bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "amount");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_closeStream_emitsEvent() public {
        uint256 duration = 1 days;
        uint256 shares = _openStream(alice, bob, 1e18, duration);

        vm.warp(block.timestamp + duration + 1);

        vm.expectEmit(true, true, true, true);
        emit StreamClosed(alice, bob, 0, shares);

        vm.startPrank(alice);
        streams.close(bob);
    }

    function test_closeStream_failsIfAlreadyClosed() public {
        _openStream(alice, bob, 1e18, 1 days);

        vm.prank(alice);
        streams.close(bob);

        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        vm.prank(alice);
        streams.close(bob);
    }

    function test_closeStream_transfersRemainingUnclaimedAmountToReceiverAfterLastClaim() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 claimed = streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares / 2, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        // around 1/4 should be claimable
        vm.warp(block.timestamp + 6 hours);

        (uint256 remaining, uint256 unclaimed) = streams.previewClose(alice, bob);

        vm.prank(alice);
        streams.close(bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
        assertApproxEqRel(vault.balanceOf(alice), shares / 4, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(alice), remaining, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
        assertApproxEqRel(vault.balanceOf(bob), claimed + unclaimed, 0.0001e18, "receiver balance");
        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
    }

    function test_closeStream_transfersRemainingAmountToStreamer() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        // around half should be claimable
        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares / 2, 0.0001e18, "contract balance 1");
        assertEq(vault.balanceOf(alice), 0, "alice's balance 1 ");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 1");

        vm.prank(alice);
        streams.close(bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance 2");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.0001e18, "alice's balance 2");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 2");
    }

    /*
     * --------------------
     *     #topUpStream
     * --------------------
     */

    function test_topUpStream_addsAmountToStreamAndExtendsDuration() public {
        uint256 duration = 1 days;
        uint256 shares = _openStream(alice, bob, 1e18, duration);

        uint256 streamId = streams.getStreamId(alice, bob);
        ERC20Streams.Stream memory stream = streams.getStream(streamId);

        vm.warp(block.timestamp + 12 hours);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(streams), shares);
        streams.topUp(bob, additionalShares, additionalDuration);

        assertEq(vault.balanceOf(address(streams)), shares + additionalShares, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streams.Stream memory updatedStream = streams.getStream(streamId);

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
        uint256 duration = 1 days;
        uint256 shares = _openStream(alice, bob, 1e18, duration);

        uint256 additionalShares = _depositToVault(alice, 1e18);
        uint256 additionalDuration = 1 days;
        vm.startPrank(alice);
        vault.approve(address(streams), shares);

        vm.expectEmit(true, true, true, true);
        emit StreamToppedUp(alice, bob, additionalShares, additionalDuration);
        streams.topUp(bob, additionalShares, additionalDuration);
    }

    function test_topUpStream_failsIfSAmountIsZero() public {
        _openStream(alice, bob, 1e18, 1 days);

        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        streams.topUp(bob, 0, 1 days);
    }

    function test_topUpStream_failsIfReceiverIsZeroAddress() public {
        _openStream(alice, bob, 1e18, 1 days);

        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        streams.topUp(address(0), shares, 1 days);
    }

    function test_topUpStream_failsIfStreamDoesNotExist() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        vm.prank(alice);
        streams.topUp(bob, shares, 1 days);
    }

    function test_topUpStream_failsIfStreamIsExpired() public {
        _openStream(alice, bob, 1e18, 1 days);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);

        vm.expectRevert(ERC20Streams.StreamExpired.selector);
        vm.prank(alice);
        streams.topUp(bob, shares, 1 days);
    }

    function test_topUpStream_worksAfterSomeSharesAreClaimed() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 firstClaim = streams.claim(alice, bob);

        shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);
        vm.prank(alice);
        streams.topUp(bob, shares, 1 days);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares * 3 / 2, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), firstClaim, "receiver balance");

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 secondClaim = streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), firstClaim + secondClaim, 0.0001e18, "receiver balance");
    }

    function test_topUpStream_worksWhenAddedDurationIsZero() public {
        uint256 shares = _openStream(alice, bob, 1e18, 1 days);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        _approve(alice, shares);
        vm.prank(alice);
        streams.topUp(bob, shares, 0);

        assertEq(vault.balanceOf(address(streams)), shares * 2, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertApproxEqRel(vault.balanceOf(address(streams)), shares, 0.0001e18, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");

        vm.prank(alice);
        streams.close(bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
        assertApproxEqRel(vault.balanceOf(alice), shares, 0.0001e18, "alice's balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");
    }

    function test_topUpStream_failsIfRatePerSecondDrops() public {
        uint256 duration = 1 days;
        uint256 shares = _openStream(alice, bob, 1e18, duration);

        vm.warp(block.timestamp + 6 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(streams), shares);

        // top up with same amount of shares and 2x the initial duration will decrease the rate per second
        vm.expectRevert(ERC20Streams.RatePerSecondDecreased.selector);
        streams.topUp(bob, shares, duration * 2);
    }

    /*
     * --------------------
     *  #openStreamUsingPermit
     * --------------------
     */

    function test_openStreamUsingPermit() public {
        uint256 shares = _depositToVault(dave, 1 ether);
        uint256 duration = 2 days;
        uint256 nonce = vault.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC4626(address(vault)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(streams), shares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        streams.openUsingPermit(alice, shares, duration, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(streams)), shares, "contract balance");

        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(dave, alice));
        assertEq(stream.amount, shares, "amount");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "ratePerSecond");
        assertEq(stream.startTime, block.timestamp, "startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "lastClaimTime");
    }

    /*
     * --------------------
     *  #topUpStreamUsingPermit
     * --------------------
     */

    function test_topUpStreamUsingPermit() public {
        uint256 duration = 1 days;
        uint256 shares = _openStream(dave, bob, 1e18, duration);

        vm.warp(block.timestamp + 12 hours);

        // top up params
        uint256 additionalShares = _depositToVault(dave, 1e18);
        uint256 additionalDuration = 1 days;
        uint256 nonce = vault.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC4626(address(vault)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(streams), additionalShares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        streams.topUpUsingPermit(bob, additionalShares, additionalDuration, deadline, v, r, s);

        assertEq(vault.balanceOf(address(streams)), shares + additionalShares, "contract balance");
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        ERC20Streams.Stream memory updatedStream = streams.getStream(streams.getStreamId(dave, bob));
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
        streams.claim(dave, bob);

        assertApproxEqRel(
            vault.balanceOf(address(streams)), (shares + additionalShares) / 2, 0.0001e18, "contract balance"
        );
        assertEq(vault.balanceOf(dave), 0, "dave's balance");
        assertApproxEqRel(vault.balanceOf(bob), (shares + additionalShares) / 2, 0.0001e18, "receiver balance");
    }

    /*
     * --------------------
     *     #multicall
     * --------------------
     */

    function test_multicall() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;
        _approve(alice, shares);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(streams.open, (bob, shares / 2, duration));
        data[1] = abi.encodeCall(streams.open, (carol, shares / 2, duration));

        vm.prank(alice);
        streams.multicall(data);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(stream.amount, shares / 2, "bob's stream shares");
        stream = streams.getStream(streams.getStreamId(alice, carol));
        assertEq(stream.amount, shares / 2, "carol's stream shares");
    }

    /*
     * --------------------
     *   multiple streamers / receivers
     * --------------------
     */

    function test_oneStreamertoMultipleReceivers() public {
        // alice streams to bob and carol
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 bobsStreamShares = shares / 4;
        uint256 bobsStreamDuration = 1 days;
        uint256 carolsStreamShares = shares - bobsStreamShares;
        uint256 carolsStreamDuration = 3 days;

        vm.startPrank(alice);
        vault.approve(address(streams), shares);

        streams.open(bob, bobsStreamShares, bobsStreamDuration);
        streams.open(carol, carolsStreamShares, carolsStreamDuration);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.balanceOf(address(streams)), shares);

        assertEq(streams.previewClaim(alice, bob), 0, "previewClaim(alice, bob)");
        ERC20Streams.Stream memory bobsStream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(bobsStream.amount, bobsStreamShares, "bob's stream shares");
        assertEq(
            bobsStream.ratePerSecond, bobsStreamShares.divWadUp(bobsStreamDuration), "bob's stream rate per second"
        );
        assertEq(bobsStream.startTime, block.timestamp, "bob's stream start time");
        assertEq(bobsStream.lastClaimTime, block.timestamp, "bob's stream last claim time");

        assertEq(streams.previewClaim(alice, carol), 0, "previewClaim(alice, carol)");
        ERC20Streams.Stream memory carolsStream = streams.getStream(streams.getStreamId(alice, carol));
        assertEq(carolsStream.amount, carolsStreamShares, "carol's stream shares");
        assertEq(
            carolsStream.ratePerSecond,
            carolsStreamShares.divWadUp(carolsStreamDuration),
            "carol's stream rate per second"
        );
        assertEq(carolsStream.startTime, block.timestamp, "carol's stream start time");
        assertEq(carolsStream.lastClaimTime, block.timestamp, "carol's stream last claim time");

        vm.warp(block.timestamp + 36 hours);

        assertEq(streams.previewClaim(alice, bob), bobsStreamShares, "previewClaim(alice, bob)");
        assertApproxEqRel(
            streams.previewClaim(alice, carol), carolsStreamShares / 2, 0.0001e18, "previewClaim(alice, carol)"
        );

        vm.prank(bob);
        uint256 bobsClaim = streams.claim(alice, bob);

        assertEq(vault.balanceOf(address(streams)), shares - bobsClaim, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(bobsClaim, bobsStreamShares, "bobsClaim");

        vm.prank(carol);
        uint256 carolsClaim = streams.claim(alice, carol);

        assertEq(vault.balanceOf(address(streams)), shares - bobsClaim - carolsClaim, "contract balance");
        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
        assertApproxEqRel(carolsClaim, carolsStreamShares / 2, 0.0001e18, "claimed");

        ERC20Streams.Stream memory stream = streams.getStream(streams.getStreamId(alice, bob));
        assertEq(stream.amount, 0, "bob's stream not deleted - amount");
        assertEq(stream.ratePerSecond, 0, "bob's stream not deleted - ratePerSecond");
        assertEq(stream.startTime, 0, "bob's stream not deleted - startTime");
        assertEq(stream.lastClaimTime, 0, "bob's stream not deleted - lastClaimTime");

        stream = streams.getStream(streams.getStreamId(alice, carol));
        assertEq(stream.amount, carolsStreamShares - carolsClaim, "carol's stream - amount");
        assertEq(
            stream.ratePerSecond, carolsStreamShares.divWadUp(carolsStreamDuration), "carol's stream - ratePerSecond"
        );
        assertEq(stream.startTime, carolsStream.startTime, "carol's stream - startTime");
        assertEq(stream.lastClaimTime, block.timestamp, "carol's stream - lastClaimTime");

        vm.startPrank(alice);
        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        streams.close(bob);

        streams.close(carol);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance");
        assertEq(vault.balanceOf(alice), shares - bobsClaim - carolsClaim, "alice's balance");
        assertEq(vault.balanceOf(bob), bobsStreamShares, "bob's balance");
        assertEq(vault.balanceOf(carol), carolsClaim, "carol's balance");
    }

    function test_multipleStreamersToSingleReceiver() public {
        // alice and bob stream to carol
        uint256 alicesShares = _openStream(alice, carol, 1e18, 1 days);
        uint256 bobsShares = _openStream(bob, carol, 2e18, 2 days);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(carol), 0);

        vm.startPrank(carol);
        vm.expectRevert(ERC20Streams.NoTokensToClaim.selector);
        streams.claim(alice, carol);
        vm.expectRevert(ERC20Streams.NoTokensToClaim.selector);
        streams.claim(bob, carol);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(streams.previewClaim(alice, carol), alicesShares, "previewClaim(alice, carol)");
        assertApproxEqRel(streams.previewClaim(bob, carol), bobsShares / 2, 0.0001e18, "previewClaim(bob, carol)");

        vm.startPrank(carol);
        uint256 claimFromAlice = streams.claim(alice, carol);
        uint256 claimFromBob = streams.claim(bob, carol);
        vm.stopPrank();

        assertEq(
            vault.balanceOf(address(streams)),
            alicesShares + bobsShares - claimFromAlice - claimFromBob,
            "contract balance after claims"
        );
        assertEq(vault.balanceOf(alice), 0, "alice's balance after claims");
        assertEq(vault.balanceOf(bob), 0, "bob's balance after claims");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after claims");

        vm.prank(alice);
        vm.expectRevert(ERC20Streams.StreamDoesNotExist.selector);
        streams.close(carol);

        vm.prank(bob);
        streams.close(carol);

        assertEq(vault.balanceOf(address(streams)), 0, "contract balance after closing");
        assertEq(vault.balanceOf(alice), 0, "alice's balance after closing");
        assertEq(vault.balanceOf(bob), bobsShares - claimFromBob, "bob's balance after closing");
        assertEq(vault.balanceOf(carol), claimFromAlice + claimFromBob, "carol's balance after closing");
    }

    /*
     * --------------------
     *       FUZZING
     * --------------------
     */

    function testFuzz_open_claim_close_stream(uint256 _amount, uint256 _duration) public {
        _amount = bound(_amount, 10000, 10000 ether);
        _duration = bound(_duration, 100 seconds, 5000 days);
        uint256 shares = _depositToVault(alice, _amount);
        uint256 sharesStreamedPerSecond = shares.divWadUp(_duration * 1e18);

        console2.log("amount", shares);
        console2.log("_duration", _duration);
        console2.log("streamedPerSecond", sharesStreamedPerSecond);

        vm.startPrank(alice);
        vault.approve(address(streams), shares);

        streams.open(bob, shares, _duration);

        vm.stopPrank();

        vm.warp(block.timestamp + _duration / 2);

        uint256 expectedSharesToClaim = shares / 2;

        // claim shares
        uint256 previewClaim = streams.previewClaim(alice, bob);
        assertApproxEqAbs(previewClaim, expectedSharesToClaim, sharesStreamedPerSecond, "previewClaim");
        console2.log("previewClaim", previewClaim);

        vm.prank(bob);
        streams.claim(alice, bob);

        assertEq(vault.balanceOf(bob), previewClaim, "claimed shares");
        assertEq(streams.previewClaim(alice, bob), 0, "previewClaim after claim");

        // close streams
        vm.startPrank(alice);
        streams.close(bob);

        assertEq(vault.balanceOf(address(streams)), 0, "contracts's shares");
        assertApproxEqAbs(vault.balanceOf(alice), shares / 2, sharesStreamedPerSecond, "alice's shares");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.01e18, "alice's shares");
    }

    /*
     * --------------------
     *     helper funcs
     * --------------------
     */

    function _depositToVault(address _account, uint256 _amount) internal returns (uint256 shares) {
        shares = _depositToVault(IERC4626(address(vault)), _account, _amount);
    }

    function _approve(address _account, uint256 _shares) internal {
        _approve(IERC20(address(vault)), address(streams), _account, _shares);
    }

    function _openStream(address _streamer, address _receiver, uint256 _amount, uint256 _duration)
        internal
        returns (uint256 shares)
    {
        shares = _depositToVault(_streamer, _amount);
        _approve(_streamer, shares);

        vm.prank(_streamer);
        streams.open(_receiver, shares, _duration);
    }
}
