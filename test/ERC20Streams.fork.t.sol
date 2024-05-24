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
import {ERC20Streams} from "../src/ERC20Streams.sol";

contract ERC20StreamsTest is TestCommon {
    using FixedPointMathLib for uint256;

    ERC20Streams public scEthStreams;
    IERC4626 public scEth;
    IERC20 public weth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        scEth = IERC4626(0x4c406C068106375724275Cbff028770C544a1333); // scETH mainnet address
        weth = IERC20(scEth.asset());

        scEthStreams = new ERC20Streams(scEth);
    }

    function test_openStream_claimTokens() public {
        uint256 duration = 2 days;
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, alice, address(scEthStreams), shares);

        vm.prank(alice);
        scEthStreams.open(bob, shares, duration);

        assertEq(scEth.balanceOf(address(scEthStreams)), shares, "contract shares");

        _generateYield(scEth, 0.05e18); // 5%

        vm.warp(block.timestamp + duration / 2);

        // assert token stream
        uint256 previewClaim = scEthStreams.previewClaim(alice, bob);
        assertApproxEqRel(previewClaim, shares / 2, 0.00001e18, "previewClaimShares");

        vm.prank(bob);
        scEthStreams.claim(alice, bob);

        assertEq(scEth.balanceOf(bob), previewClaim, "bob's shares");
        assertEq(scEth.balanceOf(address(scEthStreams)), shares - previewClaim, "contract shares");
    }

    function test_closeStream() public {
        uint256 duration = 2 days;
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, alice, address(scEthStreams), shares);

        vm.prank(alice);
        scEthStreams.open(bob, shares, duration);

        assertEq(scEth.balanceOf(address(scEthStreams)), shares, "contract shares");

        vm.warp(block.timestamp + duration / 2);

        // assert shares stream
        uint256 previewClaim = scEthStreams.previewClaim(alice, bob);
        assertApproxEqRel(previewClaim, shares / 2, 0.00001e18, "previewClaimShares");

        vm.prank(alice);
        scEthStreams.close(bob);

        assertEq(scEth.balanceOf(bob), previewClaim, "bob's shares");
        assertEq(scEth.balanceOf(alice), shares - previewClaim, "alice's shares");
        assertEq(scEth.balanceOf(address(scEthStreams)), 0, "contract shares");
    }

    function test_openMultipleTokenStreams() public {
        // alice and bob open streams to carol
        // carol opens a stream to alice
        uint256 alicesShares = _depositToVault(scEth, alice, 1 ether);
        uint256 alicesDuration = 2 days;
        uint256 bobsShares = _depositToVault(scEth, bob, 2 ether);
        uint256 bobsDuration = 4 days;

        _approve(scEth, alice, address(scEthStreams), alicesShares);
        _approve(scEth, bob, address(scEthStreams), bobsShares);

        vm.prank(alice);
        scEthStreams.open(carol, alicesShares, alicesDuration);
        vm.prank(bob);
        scEthStreams.open(carol, bobsShares, bobsDuration);

        vm.warp(block.timestamp + 1 days);

        uint256 carolsShares = _depositToVault(scEth, carol, 3 ether);
        uint256 carolsDuration = 6 days;
        _approve(scEth, carol, address(scEthStreams), carolsShares);

        vm.prank(carol);
        scEthStreams.open(alice, carolsShares, carolsDuration);

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(carol);
        scEthStreams.claim(alice, carol);
        scEthStreams.claim(bob, carol);
        vm.stopPrank();

        assertEq(scEth.balanceOf(alice), 0, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(scEth.balanceOf(carol), alicesShares + bobsShares / 2, 0.00001e18, "carol's shares");

        vm.prank(alice);
        scEthStreams.claim(carol, alice);

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(carol);
        scEthStreams.claim(bob, carol);
        scEthStreams.close(alice);
        vm.stopPrank();

        assertApproxEqRel(scEth.balanceOf(alice), carolsShares / 2, 0.00001e18, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(
            scEth.balanceOf(carol), alicesShares + bobsShares + carolsShares / 2, 0.00001e18, "carol's shares"
        );
    }
}
