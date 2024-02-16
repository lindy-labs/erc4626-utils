// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "../src/common/Errors.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";
import {stdMath} from "forge-std/StdMath.sol";

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

    function proveFail_constructor_failsForAddress0() public {
        new ERC20Streaming(IERC4626(address(0)));
    }

    // *** #openStream *** ///

    function prove_openStream_createsNewStream(uint256 amount, uint256 duration) public {
        uint256 shares = _depositToVault(alice, amount);

        vm.prank(alice);
        vault.approve(address(streaming), shares);
        vm.prank(alice);
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

    /// *** From fuzzing to formal verification *** ///

    function prove_open_claim_close_stream(uint256 _amount, uint256 _duration) public {
        //require(10000 <= _amount && _amount <= 10000 ether);
        //require(100 seconds <= _duration && _duration <= 5000 days);
        uint256 shares = _depositToVault(alice, _amount);
        uint256 sharesStreamedPerSecond = shares.divWadUp(_duration * 1e18);

        vm.prank(alice);
        vault.approve(address(streaming), shares);
        vm.prank(alice);
        streaming.openStream(bob, shares, _duration);

        vm.warp(block.timestamp + _duration / 2);

        uint256 expectedSharesToClaim = shares / 2;

        // claim shares
        uint256 previewClaim = streaming.previewClaim(alice, bob);

        _assertApproxEqAbs(previewClaim, expectedSharesToClaim, sharesStreamedPerSecond);

        vm.prank(bob);
        streaming.claim(alice, bob);

        assert(vault.balanceOf(bob) == previewClaim);
        assert(streaming.previewClaim(alice, bob) == 0);

        // close streams
        vm.prank(alice);
        streaming.closeStream(bob);

        assert(vault.balanceOf(address(streaming)) == 0);
        _assertApproxEqAbs(vault.balanceOf(alice), shares / 2, sharesStreamedPerSecond);
        _assertApproxEqRel(vault.balanceOf(alice), shares / 2, 0.01e18);
       
    }

    function _depositToVault(address _account, uint256 _amount) internal returns (uint256 shares) {
        vm.prank(_account);
        asset.mint(_account, _amount);
        vm.prank(_account);
        asset.approve(address(vault), _amount);
        vm.prank(_account);
        shares = vault.deposit(_amount, _account);
    }

    function _assertApproxEqAbs(uint256 a, uint256 b, uint256 maxDelta) internal {
        require(stdMath.delta(a, b) <= maxDelta);
    }

    function _assertApproxEqRel(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta
    ) internal {
        if (b == 0) return assert(a == b);
        require(stdMath.percentDelta(a, b) <= maxPercentDelta);
    }

}
