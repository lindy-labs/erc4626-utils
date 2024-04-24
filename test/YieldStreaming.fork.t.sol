// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {TestCommon} from "./common/TestCommon.sol";
import {YieldStreaming} from "src/YieldStreaming.sol";

contract YieldStreamingTest is TestCommon {
    using FixedPointMathLib for uint256;

    YieldStreaming public scEthYield;
    YieldStreaming public scUsdcYield;
    IERC4626 public scEth;
    IERC20 public weth;
    IERC4626 public scUsdc;
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
        scUsdc = IERC4626(0x096697720056886b905D0DEB0f06AfFB8e4665E5); // scUSDC mainnet address
        usdc = IERC20(scUsdc.asset());

        scEthYield = new YieldStreaming(scEth);
        scUsdcYield = new YieldStreaming(scUsdc);
    }

    function test_open() public {
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, address(scEthYield), alice, shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "contract's balance");
        assertEq(scEthYield.receiverShares(bob), shares, "receiverShares");
        assertEq(scEthYield.receiverPrincipal(bob, 1), scEth.convertToAssets(shares), "receiverPrincipal");
        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0");

        _generateYield(scEth, 0.05e18); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yield before claim");

        vm.prank(bob);
        scEthYield.claimYield(bob);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0 after claim");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_open_toMultipleReceivers() public {
        // alice opens yield streams to bob and carol
        // principal = 3000 USDC
        uint256 shares = _depositToVault(scUsdc, alice, 3000e6);
        _approve(scUsdc, address(scUsdcYield), alice, shares);

        uint256 bobsShares = shares / 3;
        uint256 carolsShares = shares - bobsShares;

        vm.startPrank(alice);
        scUsdcYield.open(bob, bobsShares, 0);
        scUsdcYield.open(carol, carolsShares, 0);
        vm.stopPrank();

        assertEq(scUsdc.balanceOf(address(scUsdcYield)), shares, "contract's balance");
        assertEq(scUsdcYield.receiverShares(bob), bobsShares, "bob's receiverShares");
        assertEq(scUsdcYield.receiverPrincipal(bob, 1), scUsdc.convertToAssets(bobsShares), "bob's receiverPrincipal");
        assertEq(scUsdcYield.previewClaimYield(bob), 0, "bob's yield not 0");
        assertEq(scUsdcYield.receiverShares(carol), carolsShares, "carol's receiverShares");
        assertEq(
            scUsdcYield.receiverPrincipal(carol, 2), scUsdc.convertToAssets(carolsShares), "carol's receiverPrincipal"
        );
        assertEq(scUsdcYield.previewClaimYield(carol), 0, "carol's yield not 0");

        _generateYield(scUsdc, 0.05e18); // 5%

        uint256 bobsExpectedYield = 50e6;
        uint256 carolsExpectedYield = 100e6;

        assertApproxEqAbs(scUsdcYield.previewClaimYield(bob), bobsExpectedYield, 1, "bob's yield before claim");
        assertApproxEqAbs(scUsdcYield.previewClaimYield(carol), carolsExpectedYield, 1, "carol's yield before claim");

        vm.prank(bob);
        scUsdcYield.claimYield(bob);

        assertEq(scUsdcYield.previewClaimYield(bob), 0, "bob's yield not 0 after claim");
        assertEq(usdc.balanceOf(bob), bobsExpectedYield, "bob's balance");

        vm.prank(carol);
        scUsdcYield.claimYield(carol);
        assertEq(scUsdcYield.previewClaimYield(carol), 0, "carol's yield not 0 after claim");
        assertApproxEqAbs(usdc.balanceOf(carol), carolsExpectedYield, 1, "carol's balance");

        vm.prank(alice);
        scUsdcYield.close(1);

        _generateYield(scUsdc, 0.05e18); // 5%

        assertEq(scUsdcYield.previewClaimYield(bob), 0, "bob's yield not 0 after stream closed");
        assertApproxEqAbs(
            scUsdcYield.previewClaimYield(carol), carolsExpectedYield, 2, "carol's yield after bob's stream closed"
        );
    }

    function test_topUp() public {
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, address(scEthYield), alice, shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        _generateYield(scEth, 0.05e18); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yield");

        vm.prank(bob);
        scEthYield.claimYield(bob);
        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0 after claim");

        uint256 sharesBeforeTopUp = scEthYield.receiverShares(bob);

        uint256 topUpShares = _depositToVault(scEth, alice, 2 ether);
        _approve(scEth, address(scEthYield), alice, topUpShares);

        vm.prank(alice);
        scEthYield.topUp(1, topUpShares);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0 immediately after topUp");
        assertEq(scEthYield.receiverShares(bob), sharesBeforeTopUp + topUpShares, "receiverShares");

        uint256 profitPct = 0.1e18; // 10%
        expectedYield = scEth.convertToAssets(sharesBeforeTopUp + topUpShares).mulWadDown(profitPct);
        _generateYield(scEth, int256(profitPct));

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yield after topUp");
    }

    function test_open_fromTwoAccountsToSameReceiver() public {
        // alice and bob open yield streams to carol
        uint256 alicesPrincipal = 1 ether;
        uint256 alicesShares = _depositToVault(scEth, alice, alicesPrincipal);
        _approve(scEth, address(scEthYield), alice, alicesShares);
        vm.prank(alice);
        scEthYield.open(carol, alicesShares, 0);

        uint256 bobsPrincipal = 2 ether;
        uint256 bobsShares = _depositToVault(scEth, bob, bobsPrincipal);
        _approve(scEth, address(scEthYield), bob, bobsShares);
        vm.prank(bob);
        scEthYield.open(carol, bobsShares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), alicesShares + bobsShares, "contract's balance");
        assertEq(scEthYield.receiverShares(carol), alicesShares + bobsShares, "receiverShares");
        assertApproxEqAbs(scEthYield.receiverPrincipal(carol, 1), alicesPrincipal, 1, "alice's receiverPrincipal");
        assertApproxEqAbs(scEthYield.receiverPrincipal(carol, 2), bobsPrincipal, 1, "bob's receiverPrincipal");

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesPrincipal + bobsPrincipal).mulWadDown(profitPct);

        _generateYield(scEth, int256(profitPct));

        assertEq(scEthYield.previewClaimYield(alice), 0, "alice's yield not 0");
        assertEq(scEthYield.previewClaimYield(bob), 0, "bob's yield not 0");
        assertApproxEqAbs(scEthYield.previewClaimYield(carol), expectedYield, 1, "carol's yield before claim");

        vm.prank(carol);
        scEthYield.claimYield(carol);

        assertEq(scEthYield.previewClaimYield(carol), 0, "carol's yield not 0 after claim");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's assets");
    }

    function test_close() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(scEth, alice, principal);
        _approve(scEth, address(scEthYield), alice, shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "contract's balance");
        assertEq(scEthYield.receiverShares(bob), shares, "receiverShares");
        assertEq(scEthYield.receiverPrincipal(bob, 1), scEth.convertToAssets(shares), "receiverPrincipal");

        _generateYield(scEth, 0.05e18); // 5%

        vm.prank(alice);
        scEthYield.close(1);

        uint256 expectedShares = scEth.convertToShares(principal);
        assertApproxEqAbs(scEth.balanceOf(alice), expectedShares, 1, "alice's shares after close");

        uint256 expectedYield = 0.05 ether;
        assertApproxEqAbs(
            scEthYield.receiverShares(bob), scEth.convertToShares(expectedYield), 1, "receiverShares after close"
        );
        assertApproxEqAbs(scEthYield.receiverPrincipal(bob, 1), 0, 1, "receiverPrincipal after close");
        assertApproxEqAbs(scEthYield.receiverTotalPrincipal(bob), 0, 1, "receiverTotalPrincipal after close");

        _generateYield(scEth, 0.1e18); // 10%
        expectedYield = 0.055 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        scEthYield.claimYield(bob);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_close_fromTwoAccountsToSameReceiver() public {
        // alice and bob open yield streams to carol
        uint256 alicesPrincipal = 1 ether;
        uint256 alicesShares = _depositToVault(scEth, alice, alicesPrincipal);
        _approve(scEth, address(scEthYield), alice, alicesShares);

        vm.prank(alice);
        scEthYield.open(carol, alicesShares, 0);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _depositToVault(scEth, bob, bobsDepositAmount);
        _approve(scEth, address(scEthYield), bob, bobsShares);

        vm.prank(bob);
        scEthYield.open(carol, bobsShares, 0);

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesPrincipal + bobsDepositAmount).mulWadDown(profitPct);

        _generateYield(scEth, int256(profitPct));

        vm.prank(alice);
        scEthYield.close(1);

        vm.prank(carol);
        scEthYield.claimYield(carol);

        assertEq(scEthYield.previewClaimYield(carol), 0, "carol yield not 0 after claim");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's balance");

        expectedYield = bobsDepositAmount.mulWadDown(profitPct);
        _generateYield(scEth, int256(profitPct));

        assertApproxEqAbs(
            scEthYield.previewClaimYield(carol), expectedYield, 1, "carol's yield after alice's stream closed"
        );
    }
}
