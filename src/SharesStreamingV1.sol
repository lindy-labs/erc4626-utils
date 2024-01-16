// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// idea: receiver can claim shares from multiple streams at the same time
// NOTE: the issue with this implementation is that we cannot know when a stream is expired,
// so when there are multiple streams to the same receiver and one of them expires,
// cumulative rate per second will remain unchanged allowing the receiver to claim shares from other streams at a faster rate than intended
contract SharesStreaming {
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
    }

    mapping(address => mapping(address => Stream)) public streams;
    mapping(address => uint256) public cumulativeRatePerSecond;
    mapping(address => uint256) public lastClaimedTimestamp;
    mapping(address => uint256) public totalAllocatedShares;

    event ShareStreamOpened(
        address indexed streamer, address indexed receiver, uint256 totalShares, uint256 ratePerSecond
    );
    event AllSharesClaimed(address indexed receiver, uint256 amount);
    event ShareStreamClosed(address indexed streamer, address indexed receiver, uint256 remainingShares);

    function getStream(address _streamer, address _receiver) public view returns (Stream memory) {
        return streams[_streamer][_receiver];
    }

    function openShareStream(address _receiver, uint256 _shares, uint256 _duration) public {
        require(_receiver != address(0), "Receiver cannot be zero address");
        require(_shares > 0, "Additional shares must be greater than zero");
        require(_duration > 0, "Duration must be greater than zero");

        Stream storage stream = streams[msg.sender][_receiver];

        if (stream.totalShares > 0) {
            // If the stream already exists and isn't expired, revert
            require(block.timestamp > stream.startTime + _shares / stream.ratePerSecond, "Stream already exists");
        }

        // Create a new stream
        // uint256 streamDuration = _shares / _ratePerSecond;
        uint256 _ratePerSecond = _shares / _duration;

        stream.totalShares = _shares;
        stream.ratePerSecond = _ratePerSecond;
        stream.startTime = block.timestamp;

        // Update the cumulative rate for the receiver
        cumulativeRatePerSecond[_receiver] += _ratePerSecond;

        if (totalAllocatedShares[_receiver] == 0) {
            lastClaimedTimestamp[_receiver] = block.timestamp;
        }

        // Update the total allocated shares for the receiver
        totalAllocatedShares[_receiver] += _shares;

        // Transfer the additional shares to the contract
        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit ShareStreamOpened(msg.sender, _receiver, stream.totalShares, stream.ratePerSecond);
    }

    function claimAllStreamedShares() public {
        uint256 elapsedTime = block.timestamp - lastClaimedTimestamp[msg.sender];
        uint256 claimableShares = elapsedTime * cumulativeRatePerSecond[msg.sender];

        require(claimableShares > 0, "No shares to claim");

        // Cap the claimable shares at the total allocated shares
        if (claimableShares > totalAllocatedShares[msg.sender]) {
            claimableShares = totalAllocatedShares[msg.sender];
        }

        lastClaimedTimestamp[msg.sender] = block.timestamp;

        uint256 availableShares = vault.balanceOf(address(this));
        require(claimableShares <= availableShares, "Insufficient shares in vault");

        vault.safeTransfer(msg.sender, claimableShares);
        totalAllocatedShares[msg.sender] -= claimableShares;

        // If all allocated shares are claimed, reset the cumulative rate
        if (totalAllocatedShares[msg.sender] == 0) {
            cumulativeRatePerSecond[msg.sender] = 0;
        }

        emit AllSharesClaimed(msg.sender, claimableShares);
    }

    function closeShareStream(address _receiver) public {
        require(streams[msg.sender][_receiver].totalShares > 0, "Stream does not exist");
        Stream storage stream = streams[msg.sender][_receiver];

        uint256 elapsedTime = block.timestamp - stream.startTime;
        uint256 streamedShares = elapsedTime * stream.ratePerSecond;

        uint256 lastClaimTime =
            lastClaimedTimestamp[_receiver] > stream.startTime ? lastClaimedTimestamp[_receiver] : stream.startTime;

        uint256 unclaimedShares = 0;
        uint256 claimedShares = 0;

        if (lastClaimTime > 0) {
            // If the stream has been claimed before, calculate the amount of shares that have been streamed
            uint256 elapsedTimeOnLastClaim = lastClaimTime - stream.startTime;

            claimedShares = elapsedTimeOnLastClaim * stream.ratePerSecond;
            unclaimedShares = (block.timestamp - lastClaimTime) * stream.ratePerSecond;
            if (unclaimedShares > stream.totalShares) {
                unclaimedShares = stream.totalShares;
            }
        }

        if (streamedShares > stream.totalShares) {
            streamedShares = stream.totalShares;
        }

        uint256 remainingShares = stream.totalShares - streamedShares;

        if (stream.ratePerSecond > 0) {
            cumulativeRatePerSecond[_receiver] -= stream.ratePerSecond;
        }

        // consider already claimed shares
        totalAllocatedShares[_receiver] -= stream.totalShares - claimedShares;

        delete streams[msg.sender][_receiver];

        if (remainingShares > 0) {
            vault.safeTransfer(msg.sender, remainingShares);
        }

        if (unclaimedShares > 0) {
            vault.safeTransfer(_receiver, unclaimedShares);
        }

        emit ShareStreamClosed(msg.sender, _receiver, remainingShares);
    }
}

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract SharesStreamingTest is Test {
    MockERC20 public asset;
    MockERC4626 public vault;
    SharesStreaming public sharesStreaming;

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        sharesStreaming = new SharesStreaming(IERC4626(address(vault)));
    }

    function test_openShareStream() public {
        uint256 amount = 1e18;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        vault.approve(address(sharesStreaming), shares);

        uint256 ratePerSecond = shares / 1 days; // stream for 1 day

        address receiver = address(0x1);

        sharesStreaming.openShareStream(receiver, shares, 1 days);

        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(address(sharesStreaming)), shares);
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, shares);
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, ratePerSecond);
    }

    function test_claimAllStreamedShares() public {
        uint256 amount = 1e18;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        vault.approve(address(sharesStreaming), shares);

        uint256 ratePerSecond = shares / 1 days; // stream for 1 day

        address receiver = address(0x1);

        sharesStreaming.openShareStream(receiver, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1); // warp 1 day and 1 second

        vm.prank(receiver);
        sharesStreaming.claimAllStreamedShares();

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(sharesStreaming.totalAllocatedShares(receiver), 0, "totalAllocatedShares");
        assertEq(vault.balanceOf(receiver), shares, "receiver balance");
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, shares, "totalShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, ratePerSecond, "ratePerSecond");
    }

    function test_closeShareStream() public {
        uint256 amount = 1e18;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        vault.approve(address(sharesStreaming), shares);

        address receiver = address(0x1);

        sharesStreaming.openShareStream(receiver, shares, 1 days);

        vm.warp(block.timestamp + 1 days + 1); // warp 1 day and 1 second

        sharesStreaming.closeShareStream(receiver);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(vault.balanceOf(address(this)), 0, "this balance");
        assertEq(vault.balanceOf(receiver), shares, "receiver balance");
        assertEq(sharesStreaming.totalAllocatedShares(receiver), 0, "totalAllocatedShares");
        assertEq(sharesStreaming.cumulativeRatePerSecond(receiver), 0, "cumulativeRatePerSecond");
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, 0, "totalShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, 0, "ratePerSecond");
    }

    function test_claimAllStreamedShares_closeShareStream() public {
        uint256 amount = 1e18;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        vault.approve(address(sharesStreaming), shares);

        uint256 ratePerSecond = shares / 1 days; // stream for 1 day

        address receiver = address(0x1);

        sharesStreaming.openShareStream(receiver, shares, 1 days);

        vm.warp(block.timestamp + 12 hours); // around half should be claimable

        vm.prank(receiver);
        sharesStreaming.claimAllStreamedShares();

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(sharesStreaming.totalAllocatedShares(receiver), shares / 2, 0.0001e18, "totalAllocatedShares");
        assertEq(vault.balanceOf(address(this)), 0, "this balance");
        assertApproxEqRel(vault.balanceOf(receiver), shares / 2, 0.0001e18, "receiver balance");
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, shares, "totalShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, ratePerSecond, "ratePerSecond");

        sharesStreaming.closeShareStream(receiver);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(address(this)), shares / 2, 0.0001e18, "this balance");
        assertApproxEqRel(vault.balanceOf(receiver), shares / 2, 0.0001e18, "receiver balance");
    }

    function test_claimAllStreamedShares_closeShareStream_withLeftOvers() public {
        uint256 amount = 1e18;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        vault.approve(address(sharesStreaming), shares);

        uint256 ratePerSecond = shares / 1 days; // stream for 1 day

        address receiver = address(0x1);

        sharesStreaming.openShareStream(receiver, shares, 1 days);

        vm.warp(block.timestamp + 12 hours); // around half should be claimable

        vm.prank(receiver);
        sharesStreaming.claimAllStreamedShares();

        assertApproxEqRel(vault.balanceOf(address(sharesStreaming)), shares / 2, 0.0001e18, "sharesStreaming balance");
        assertApproxEqRel(sharesStreaming.totalAllocatedShares(receiver), shares / 2, 0.0001e18, "totalAllocatedShares");
        assertEq(vault.balanceOf(address(this)), 0, "this balance");
        assertApproxEqRel(vault.balanceOf(receiver), shares / 2, 0.0001e18, "receiver balance");
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, shares, "totalShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, ratePerSecond, "ratePerSecond");

        vm.warp(block.timestamp + 6 hours); // around 1/4 should be claimable

        sharesStreaming.closeShareStream(receiver);

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertApproxEqRel(vault.balanceOf(address(this)), shares / 4, 0.0001e18, "this balance");
        assertApproxEqRel(vault.balanceOf(receiver), shares * 3 / 4, 0.0001e18, "receiver balance");

        assertEq(vault.balanceOf(address(sharesStreaming)), 0, "sharesStreaming balance");
        assertEq(sharesStreaming.totalAllocatedShares(receiver), 0, "totalAllocatedShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).totalShares, 0, "totalShares");
        assertEq(sharesStreaming.getStream(address(this), receiver).ratePerSecond, 0, "ratePerSecond");
    }
    // test from multiple streamers to single receiver
    // single streamer to multiple receivers
}
