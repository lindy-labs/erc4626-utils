// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/draft-IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// idea: all streams are separate and receiver can only claim from one stream at a time
contract SharesStreamingV2 is Multicall {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    IERC4626 public immutable vault;

    constructor(IERC4626 _vault) {
        vault = _vault;
    }

    struct Stream {
        uint256 shares;
        uint256 ratePerSecond;
        uint256 startTime;
        uint256 lastClaimTime;
    }

    error AddressZero();
    error ZeroDuration();
    error ZeroShares();
    error NotEnoughShares();
    error StreamAlreadyExists();
    error CannotOpenStreamToSelf();
    error StreamDoesNotExist();
    error StreamExpired();
    error StreamRatePerSecondMustNotDecrease();
    error NoSharesToClaim();

    mapping(uint256 => Stream) public streamsById;

    event OpenShareStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseShareStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpShareStream(
        address indexed streamer, address indexed receiver, uint256 addedShares, uint256 addedDuration
    );

    function getStreamId(address _streamer, address _receiver) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_streamer, _receiver)));
    }

    function getStream(uint256 streamId) public view returns (Stream memory) {
        return streamsById[streamId];
    }

    function openStream(address _receiver, uint256 _shares, uint256 _duration) public {
        _openStream(msg.sender, _receiver, _shares, _duration);
    }

    function openStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _duration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        _openStream(msg.sender, _receiver, _shares, _duration);
    }

    function _openStream(address _streamer, address _receiver, uint256 _shares, uint256 _duration) internal {
        _checkAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkShares(_streamer, _shares);
        _checkDuration(_duration);

        uint256 streamId = getStreamId(_streamer, _receiver);
        Stream storage stream = streamsById[streamId];

        if (stream.shares > 0) {
            // If the stream already exists and isn't expired, revert
            if (block.timestamp < stream.startTime + stream.shares / stream.ratePerSecond) {
                revert StreamAlreadyExists();
            }

            // if is expired, transfer unclaimed shares to receiver
            vault.safeTransfer(_receiver, stream.shares);
        }

        uint256 _ratePerSecond = _shares / _duration;

        stream.shares = _shares;
        stream.ratePerSecond = _ratePerSecond;
        stream.startTime = block.timestamp;
        stream.lastClaimTime = block.timestamp;

        vault.safeTransferFrom(_streamer, address(this), _shares);

        emit OpenShareStream(_streamer, _receiver, stream.shares, _duration);
    }

    function topUpStream(address _receiver, uint256 _additionalShares, uint256 _additionalDuration) external {
        _checkAddress(_receiver);
        _checkShares(msg.sender, _additionalShares);

        Stream storage stream = streamsById[getStreamId(msg.sender, _receiver)];

        _checkExistingStream(stream);

        uint256 timeRemaining = stream.shares / stream.ratePerSecond;

        if (block.timestamp > stream.lastClaimTime + timeRemaining) revert StreamExpired();

        stream.shares += _additionalShares;

        uint256 newRatePerSecond = stream.shares / (timeRemaining + _additionalDuration);

        if (newRatePerSecond < stream.ratePerSecond) revert StreamRatePerSecondMustNotDecrease();

        stream.ratePerSecond = newRatePerSecond;

        vault.safeTransferFrom(msg.sender, address(this), _additionalShares);

        emit TopUpShareStream(msg.sender, _receiver, _additionalShares, _additionalDuration);
    }

    function claim(address _streamer) public returns (uint256) {
        uint256 streamId = getStreamId(_streamer, msg.sender);
        Stream storage stream = streamsById[streamId];

        uint256 sharesToClaim = _previewClaim(stream);

        if (sharesToClaim == 0) revert NoSharesToClaim();

        // Cap the claimable shares at the total allocated shares
        if (sharesToClaim == stream.shares) {
            // delete stream because it expired?
            delete streamsById[streamId];

            // emit event?
        } else {
            stream.lastClaimTime = block.timestamp;
            stream.shares -= sharesToClaim;
        }

        vault.safeTransfer(msg.sender, sharesToClaim);

        emit ClaimShares(_streamer, msg.sender, sharesToClaim);

        return sharesToClaim;
    }

    function previewClaim(address _streamer, address _receiver) public view returns (uint256) {
        return _previewClaim(streamsById[getStreamId(_streamer, _receiver)]);
    }

    function _previewClaim(Stream memory _stream) internal view returns (uint256) {
        _checkExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimableShares = elapsedTime * _stream.ratePerSecond;

        // Cap the shares to claim to the total allocated shares
        if (claimableShares > _stream.shares) claimableShares = _stream.shares;

        return claimableShares;
    }

    function closeStream(address _receiver) external returns (uint256 remainingShares, uint256 streamedShares) {
        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream memory stream = streamsById[streamId];

        (remainingShares, streamedShares) = _previewCloseStream(stream);

        delete streamsById[streamId];

        if (remainingShares != 0) vault.safeTransfer(msg.sender, remainingShares);

        if (streamedShares != 0) vault.safeTransfer(_receiver, streamedShares);

        emit CloseShareStream(msg.sender, _receiver, remainingShares, streamedShares);
    }

    function previewCloseStream(address _streamer, address _receiver)
        public
        view
        returns (uint256 remainingShares, uint256 streamedShares)
    {
        Stream memory stream = streamsById[getStreamId(_streamer, _receiver)];

        return _previewCloseStream(stream);
    }

    function _previewCloseStream(Stream memory _stream)
        internal
        view
        returns (uint256 remainingShares, uint256 streamedShares)
    {
        _checkExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        streamedShares = elapsedTime * _stream.ratePerSecond;

        if (streamedShares > _stream.shares) streamedShares = _stream.shares;

        remainingShares = _stream.shares - streamedShares;

        return (remainingShares, streamedShares);
    }

    function _checkAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert AddressZero();
    }

    function _checkShares(address _streamer, uint256 _shares) internal view {
        if (_shares == 0) revert ZeroShares();

        if (vault.allowance(_streamer, address(this)) < _shares) revert NotEnoughShares();
    }

    function _checkDuration(uint256 _duration) internal pure {
        if (_duration == 0) revert ZeroDuration();
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }

    function _checkExistingStream(Stream memory _stream) internal pure {
        if (_stream.shares == 0) revert StreamDoesNotExist();
    }
}

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract SharesStreamingTest is Test {
    MockERC20 public asset;
    MockERC4626 public vault;
    SharesStreamingV2 public sharesStreaming;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    event OpenShareStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseShareStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpShareStream(
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
        emit OpenShareStream(alice, bob, shares, duration);

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
        emit TopUpShareStream(alice, bob, additionalShares, additionalDuration);
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
    // cleanup
    // upgrade open zeppelin
    // add docs
    // separate tests & contracts
    // top up using permit
    // prevent reentrancy?

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
