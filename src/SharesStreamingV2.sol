// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/draft-IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// idea: all streams are separate and receiver can only claim from one stream at a time
contract SharesStreamingV2 {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    IERC4626 public immutable vault;

    constructor(IERC4626 _vault) {
        vault = _vault;
    }

    struct Stream {
        uint256 totalShares;
        uint256 ratePerSecond;
        uint256 startTime;
        uint256 lastClaimTime;
    }

    mapping(uint256 => Stream) public streamsById;

    event StreamOpened(address indexed streamer, address indexed receiver, uint256 totalShares, uint256 ratePerSecond);
    event Claimed(address indexed receiver, uint256 amount);
    event StreamClosed(address indexed streamer, address indexed receiver, uint256 remainingShares);

    function getStreamId(address _streamer, address _receiver) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_streamer, _receiver)));
    }

    function getStream(uint256 streamId) public view returns (Stream memory) {
        return streamsById[streamId];
    }

    function openStream(address _receiver, uint256 _shares, uint256 _duration) public {
        require(_receiver != address(0), "Receiver cannot be zero address");
        require(_shares > 0, "Shares amount must be greater than zero");
        require(_duration > 0, "Duration must be greater than zero");

        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream storage stream = streamsById[streamId];

        if (stream.totalShares > 0) {
            // If the stream already exists and isn't expired, revert
            require(
                block.timestamp > stream.startTime + stream.totalShares / stream.ratePerSecond, "Stream already exists"
            );

            // if is expired, transfer unclaimed shares to receiver
            vault.safeTransfer(_receiver, stream.totalShares);
        }

        uint256 _ratePerSecond = _shares / _duration;

        stream.totalShares = _shares;
        stream.ratePerSecond = _ratePerSecond;
        stream.startTime = block.timestamp;
        stream.lastClaimTime = block.timestamp;

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit StreamOpened(msg.sender, _receiver, stream.totalShares, stream.ratePerSecond);
    }

    function topUpStream(address _receiver, uint256 _additionalShares, uint256 _additionalDuration) external {
        require(_receiver != address(0), "Receiver cannot be zero address");
        require(_additionalShares > 0, "Shares amount must be greater than zero");

        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream storage stream = streamsById[streamId];

        require(stream.totalShares > 0, "Stream does not exist");

        uint256 timeRemaining = stream.totalShares / stream.ratePerSecond;

        require(block.timestamp < stream.lastClaimTime + timeRemaining, "Stream expired");

        stream.totalShares += _additionalShares;

        uint256 newRatePerSecond = stream.totalShares / (timeRemaining + _additionalDuration);

        require(
            newRatePerSecond >= stream.ratePerSecond,
            "New rate per second must be greater than or equal to current rate"
        );

        stream.ratePerSecond = newRatePerSecond;

        vault.safeTransferFrom(msg.sender, address(this), _additionalShares);

        // TODO: event
    }

    function claim(address _streamer) public returns (uint256 sharesClaimed) {
        uint256 streamId = getStreamId(_streamer, msg.sender);
        Stream storage stream = streamsById[streamId];

        require(stream.totalShares > 0, "Stream does not exist");

        uint256 elapsedTime = block.timestamp - stream.lastClaimTime;
        uint256 claimableShares = elapsedTime * stream.ratePerSecond;

        require(claimableShares > 0, "No shares to claim");

        // Cap the claimable shares at the total allocated shares
        if (claimableShares >= stream.totalShares) {
            claimableShares = stream.totalShares;

            // delete stream because it expired?
            delete streamsById[streamId];

            // emit event?
        } else {
            stream.lastClaimTime = block.timestamp;
            stream.totalShares -= claimableShares;
        }

        vault.safeTransfer(msg.sender, claimableShares);

        emit Claimed(msg.sender, claimableShares);

        return claimableShares;
    }

    function previewClaim(address _streamer, address _receiver) public view returns (uint256) {
        uint256 streamId = getStreamId(_streamer, _receiver);
        Stream storage stream = streamsById[streamId];

        require(stream.totalShares > 0, "Stream does not exist");

        uint256 elapsedTime = block.timestamp - stream.lastClaimTime;
        uint256 claimableShares = elapsedTime * stream.ratePerSecond;

        // Cap the claimable shares at the total allocated shares
        if (claimableShares > stream.totalShares) claimableShares = stream.totalShares;

        return claimableShares;
    }

    function closeStream(address _receiver) external returns (uint256 remainingShares) {
        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream storage stream = streamsById[streamId];

        require(stream.totalShares > 0, "Stream does not exist");

        uint256 elapsedTime = block.timestamp - stream.lastClaimTime;
        uint256 streamedShares = elapsedTime * stream.ratePerSecond;

        if (streamedShares > stream.totalShares) streamedShares = stream.totalShares;

        remainingShares = stream.totalShares - streamedShares;

        delete streamsById[streamId];

        if (remainingShares > 0) vault.safeTransfer(msg.sender, remainingShares);

        if (streamedShares > 0) vault.safeTransfer(_receiver, streamedShares);

        emit StreamClosed(msg.sender, _receiver, remainingShares);
    }

    function previewCloseStream(address _streamer, address _receiver) public view returns (uint256) {
        uint256 streamId = getStreamId(_streamer, _receiver);
        Stream storage stream = streamsById[streamId];

        uint256 elapsedTime = block.timestamp - stream.lastClaimTime;
        uint256 streamedShares = elapsedTime * stream.ratePerSecond;

        if (streamedShares > stream.totalShares) streamedShares = stream.totalShares;

        uint256 remainingShares = stream.totalShares - streamedShares;

        return remainingShares;
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

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        sharesStreaming = new SharesStreamingV2(IERC4626(address(vault)));
    }

    // *** #openShareStream ***

    function test_openShareStream() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        sharesStreaming.openStream(bob, shares, 1 days);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);

        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.totalShares, shares);
        assertEq(stream.ratePerSecond, shares / 1 days);
        assertEq(stream.startTime, block.timestamp);
        assertEq(stream.lastClaimTime, block.timestamp);
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

        vm.expectRevert("Stream already exists");
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

        vm.expectRevert("Receiver cannot be zero address");
        sharesStreaming.openStream(address(0), shares, 1 days);
    }

    function test_openShareStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Shares amount must be greater than zero");
        sharesStreaming.openStream(bob, 0, 1 days);
    }

    function test_openShareStream_failsIfDurationIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Duration must be greater than zero");
        sharesStreaming.openStream(bob, shares, 0);
    }

    function test_openShareStream_failsIfSharesIsGreaterThanBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares + 1);

        vm.expectRevert();
        sharesStreaming.openStream(bob, shares + 1, 1 days);
    }

    // *** #claimShares ***

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
        assertEq(stream.totalShares, 0, "totalShares");
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
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");
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

        vm.expectRevert("No shares to claim");
        vm.prank(bob);
        sharesStreaming.claim(alice);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 4, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(bob), shares * 3 / 4, 0.0001e18, "receiver balance");
    }

    // *** #closeStream ***

    function test_closeStream_failsIfStreamDoesNotExist() public {
        vm.expectRevert("Stream does not exist");
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
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertEq(vault.balanceOf(bob), shares, "receiver balance");

        // assert stream is deleted
        SharesStreamingV2.Stream memory stream = sharesStreaming.getStream(sharesStreaming.getStreamId(alice, bob));
        assertEq(stream.totalShares, 0, "totalShares");
        assertEq(stream.ratePerSecond, 0, "ratePerSecond");
        assertEq(stream.startTime, 0, "startTime");
        assertEq(stream.lastClaimTime, 0, "lastClaimTime");
    }

    function test_closeStrea_failsIfAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        vm.expectRevert("Stream does not exist");
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
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance");

        // around 1/4 should be claimable
        vm.warp(block.timestamp + 6 hours);

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares / 4, 0.0001e18, "this balance");
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
        assertEq(vault.balanceOf(alice), 0, "this balance 1 ");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 1");

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance 2");
        assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.0001e18, "this balance 2");
        assertApproxEqRel(vault.balanceOf(bob), shares / 2, 0.0001e18, "receiver balance 2");
    }

    // *** #topUpStream ***

    function test_topUpStream_addsSharesAndExtendsDuration() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 12 hours);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);
        sharesStreaming.topUpStream(bob, shares, 1 days);

        assertEq(vault.balanceOf(address(sharesStreaming)), shares * 2, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");
    }

    function test_topUpStream_failsIfSharesIsZero() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Shares amount must be greater than zero");
        sharesStreaming.topUpStream(bob, 0, 1 days);
    }

    function test_topUpStream_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Receiver cannot be zero address");
        sharesStreaming.topUpStream(address(0), shares, 1 days);
    }

    function test_topUpStream_failsIfStreamDoesNotExist() public {
        uint256 shares = _depositToVault(alice, 1e18);

        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Stream does not exist");
        sharesStreaming.topUpStream(bob, shares, 1 days);
    }

    function test_topUpStream_failsIfStreamIsExpired() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _openStream(alice, bob, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1);

        shares = _depositToVault(alice, 1e18);
        vm.startPrank(alice);
        vault.approve(address(sharesStreaming), shares);

        vm.expectRevert("Stream expired");
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
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertEq(vault.balanceOf(bob), firstClaim, "receiver balance");

        vm.warp(block.timestamp + 12 hours);

        vm.prank(bob);
        uint256 secondClaim = sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "this balance");
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
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertEq(vault.balanceOf(bob), 0, "receiver balance");

        vm.warp(block.timestamp + 6 hours);

        vm.prank(bob);
        sharesStreaming.claim(alice);

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares, 0.0001e18, "sharesStreaming balance");
        assertEq(vault.balanceOf(alice), 0, "this balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");

        vm.prank(alice);
        sharesStreaming.closeStream(bob);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(alice), shares, 0.0001e18, "this balance");
        assertApproxEqRel(vault.balanceOf(bob), shares, 0.0001e18, "receiver balance");
    }

    // TODO:
    // test from multiple streamers to single receiver
    // test single streamer to multiple receivers
    // test consecutive calls to claimShares and closeShareStream - done
    // top up stream - done
    // top up stream and claim - done
    // top up stream and close - done
    // top up stream and claim and close - done
    // error types
    // events
    // open with permit

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
