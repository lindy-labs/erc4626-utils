// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {TestCommon} from "./common/TestCommon.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract ERC20StreamingTest is TestCommon {
    using FixedPointMathLib for uint256;

    ERC20Streaming public scEthStreaming;
    ERC20Streaming public scUsdcStreaming;
    IERC4626 public scEth;
    IERC20 public weth;
    IERC20 public usdc;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        scEth = IERC4626(0x4c406C068106375724275Cbff028770C544a1333); // scETH mainnet address
        weth = IERC20(scEth.asset());

        scEthStreaming = new ERC20Streaming(scEth);
    }

    function test_openStream_claimTokens() public {
        uint256 duration = 2 days;
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, address(scEthStreaming), alice, shares);

        vm.prank(alice);
        scEthStreaming.openStream(bob, shares, duration);

        assertEq(scEth.balanceOf(address(scEthStreaming)), shares, "contract shares");

        _generateYield(scEth, 0.05e18); // 5%

        vm.warp(block.timestamp + duration / 2);

        // assert token stream
        uint256 previewClaim = scEthStreaming.previewClaim(alice, bob);
        assertApproxEqRel(previewClaim, shares / 2, 0.00001e18, "previewClaimShares");

        vm.prank(bob);
        scEthStreaming.claim(alice, bob);

        assertEq(scEth.balanceOf(bob), previewClaim, "bob's shares");
        assertEq(scEth.balanceOf(address(scEthStreaming)), shares - previewClaim, "contract shares");
    }

    function test_closeStream() public {
        uint256 duration = 2 days;
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, address(scEthStreaming), alice, shares);

        vm.prank(alice);
        scEthStreaming.openStream(bob, shares, duration);

        assertEq(scEth.balanceOf(address(scEthStreaming)), shares, "contract shares");

        vm.warp(block.timestamp + duration / 2);

        // assert shares stream
        uint256 previewClaim = scEthStreaming.previewClaim(alice, bob);
        assertApproxEqRel(previewClaim, shares / 2, 0.00001e18, "previewClaimShares");

        vm.prank(alice);
        scEthStreaming.closeStream(bob);

        assertEq(scEth.balanceOf(bob), previewClaim, "bob's shares");
        assertEq(scEth.balanceOf(alice), shares - previewClaim, "alice's shares");
        assertEq(scEth.balanceOf(address(scEthStreaming)), 0, "contract shares");
    }

    function test_openMultipleTokenStreams() public {
        // alice and bob open streams to carol
        // carol opens a stream to alice
        uint256 alicesShares = _depositToVault(scEth, alice, 1 ether);
        uint256 alicesDuration = 2 days;
        uint256 bobsShares = _depositToVault(scEth, bob, 2 ether);
        uint256 bobsDuration = 4 days;

        _approve(scEth, address(scEthStreaming), alice, alicesShares);
        _approve(scEth, address(scEthStreaming), bob, bobsShares);

        vm.prank(alice);
        scEthStreaming.openStream(carol, alicesShares, alicesDuration);
        vm.prank(bob);
        scEthStreaming.openStream(carol, bobsShares, bobsDuration);

        vm.warp(block.timestamp + 1 days);

        uint256 carolsShares = _depositToVault(scEth, carol, 3 ether);
        uint256 carolsDuration = 6 days;
        _approve(scEth, address(scEthStreaming), carol, carolsShares);

        vm.prank(carol);
        scEthStreaming.openStream(alice, carolsShares, carolsDuration);

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(carol);
        scEthStreaming.claim(alice, carol);
        scEthStreaming.claim(bob, carol);
        vm.stopPrank();

        assertEq(scEth.balanceOf(alice), 0, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(scEth.balanceOf(carol), alicesShares + bobsShares / 2, 0.00001e18, "carol's shares");

        vm.prank(alice);
        scEthStreaming.claim(carol, alice);

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(carol);
        scEthStreaming.claim(bob, carol);
        scEthStreaming.closeStream(alice);
        vm.stopPrank();

        assertApproxEqRel(scEth.balanceOf(alice), carolsShares / 2, 0.00001e18, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(
            scEth.balanceOf(carol), alicesShares + bobsShares + carolsShares / 2, 0.00001e18, "carol's shares"
        );
    }
}
