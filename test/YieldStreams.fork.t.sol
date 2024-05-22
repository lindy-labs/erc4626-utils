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
import {YieldStreams} from "src/YieldStreams.sol";

contract YieldStreamsForkTest is TestCommon {
    using FixedPointMathLib for uint256;

    YieldStreams public scEthYield;
    YieldStreams public scUsdcYield;
    IERC4626 public scEth;
    IERC20 public weth;
    IERC4626 public scUsdc;
    IERC20 public usdc;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        scEth = IERC4626(0x4c406C068106375724275Cbff028770C544a1333); // scETH mainnet address
        weth = IERC20(scEth.asset());
        scUsdc = IERC4626(0x096697720056886b905D0DEB0f06AfFB8e4665E5); // scUSDC mainnet address
        usdc = IERC20(scUsdc.asset());

        scEthYield = new YieldStreams(scEth);
        scUsdcYield = new YieldStreams(scUsdc);
    }

    function test_open() public {
        uint256 shares = _depositToVault(scEth, alice, 1 ether);
        _approve(scEth, alice, address(scEthYield), shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "contract's balance");
        assertEq(scEthYield.receiverTotalShares(bob), shares, "receiverShares");
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
        _approve(scUsdc, alice, address(scUsdcYield), shares);

        uint256 bobsShares = shares / 3;
        uint256 carolsShares = shares - bobsShares;

        vm.startPrank(alice);
        scUsdcYield.open(bob, bobsShares, 0);
        scUsdcYield.open(carol, carolsShares, 0);
        vm.stopPrank();

        assertEq(scUsdc.balanceOf(address(scUsdcYield)), shares, "contract's balance");
        assertEq(scUsdcYield.receiverTotalShares(bob), bobsShares, "bob's receiverShares");
        assertEq(scUsdcYield.receiverPrincipal(bob, 1), scUsdc.convertToAssets(bobsShares), "bob's receiverPrincipal");
        assertEq(scUsdcYield.previewClaimYield(bob), 0, "bob's yield not 0");
        assertEq(scUsdcYield.receiverTotalShares(carol), carolsShares, "carol's receiverShares");
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
        _approve(scEth, alice, address(scEthYield), shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        _generateYield(scEth, 0.05e18); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yield");

        vm.prank(bob);
        scEthYield.claimYield(bob);
        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0 after claim");

        uint256 sharesBeforeTopUp = scEthYield.receiverTotalShares(bob);

        uint256 topUpShares = _depositToVault(scEth, alice, 2 ether);
        _approve(scEth, alice, address(scEthYield), topUpShares);

        vm.prank(alice);
        scEthYield.topUp(1, topUpShares);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yield not 0 immediately after topUp");
        assertEq(scEthYield.receiverTotalShares(bob), sharesBeforeTopUp + topUpShares, "receiverShares");

        uint256 profitPct = 0.1e18; // 10%
        expectedYield = scEth.convertToAssets(sharesBeforeTopUp + topUpShares).mulWadDown(profitPct);
        _generateYield(scEth, int256(profitPct));

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yield after topUp");
    }

    function test_open_fromTwoAccountsToSameReceiver() public {
        // alice and bob open yield streams to carol
        uint256 alicesPrincipal = 1 ether;
        uint256 alicesShares = _depositToVault(scEth, alice, alicesPrincipal);
        _approve(scEth, alice, address(scEthYield), alicesShares);
        vm.prank(alice);
        scEthYield.open(carol, alicesShares, 0);

        uint256 bobsPrincipal = 2 ether;
        uint256 bobsShares = _depositToVault(scEth, bob, bobsPrincipal);
        _approve(scEth, bob, address(scEthYield), bobsShares);
        vm.prank(bob);
        scEthYield.open(carol, bobsShares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), alicesShares + bobsShares, "contract's balance");
        assertEq(scEthYield.receiverTotalShares(carol), alicesShares + bobsShares, "receiverShares");
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

    function test_depositAndOpen() public {
        uint256 principal = 1000e6;
        uint256 shares = scUsdc.previewDeposit(principal);
        deal(address(usdc), alice, principal);
        vm.prank(alice);
        usdc.approve(address(scUsdcYield), principal);

        vm.prank(alice);
        scUsdcYield.depositAndOpen(bob, principal, 0);

        assertEq(scUsdc.balanceOf(address(scUsdcYield)), shares, "contract's balance");
        assertEq(scUsdcYield.receiverTotalShares(bob), shares, "receiverShares");
        assertEq(scUsdcYield.receiverPrincipal(bob, 1), principal, "receiverPrincipal");

        _generateYield(scUsdc, 0.05e18); // 5%

        uint256 expectedYield = 50e6;

        assertApproxEqAbs(scUsdcYield.previewClaimYield(bob), expectedYield, 1, "yield");

        vm.prank(bob);
        uint256 claimed = scUsdcYield.claimYield(bob);

        assertEq(scUsdcYield.previewClaimYield(bob), 0, "yield not 0 after claim");
        assertEq(usdc.balanceOf(bob), claimed, "bob's assets");
        assertApproxEqAbs(claimed, expectedYield, 1, "bob's claim");
    }

    function test_depositAndTopUp() public {
        uint256 principal = 1000e6;
        uint256 shares = _depositToVault(scUsdc, alice, principal);
        _approve(scUsdc, alice, address(scUsdcYield), shares);

        vm.prank(alice);
        uint256 streamId = scUsdcYield.open(bob, shares, 0);

        uint256 firstYield = 0.05e18; // 5%
        _generateYield(scUsdc, int256(firstYield)); // 5%

        assertApproxEqAbs(
            scUsdcYield.previewClaimYield(bob), principal.mulWadDown(firstYield), 1, "yield before top up"
        );

        // top up
        uint256 addedPrincipal = 2000e6;
        uint256 addedShares = scUsdc.previewDeposit(addedPrincipal);
        deal(address(usdc), alice, addedPrincipal);
        vm.prank(alice);
        usdc.approve(address(scUsdcYield), addedPrincipal);

        vm.prank(alice);
        scUsdcYield.depositAndTopUp(streamId, addedPrincipal);

        assertEq(scUsdcYield.receiverTotalShares(bob), shares + addedShares, "receiverShares");

        uint256 secondYield = 0.1e18; // 10%
        _generateYield(scUsdc, int256(secondYield));

        uint256 expectedYield = principal.mulWadDown(firstYield)
            + (principal + principal.mulWadDown(firstYield) + addedPrincipal).mulWadDown(secondYield);
        // 5% of 1000 + 10% of (1000 + 50 + 2000) = 50 + 305 = 355
        assertEq(expectedYield, 355e6, "expected total yield");

        assertApproxEqAbs(scUsdcYield.previewClaimYield(bob), expectedYield, 1, "yield after topUp");
        assertEq(scUsdcYield.receiverTotalShares(bob), shares + addedShares, "receiverShares after topUp");
        assertApproxEqAbs(
            scUsdcYield.receiverTotalPrincipal(bob), principal + addedPrincipal, 1, "receiverTotalPrincipal after topUp"
        );
        assertApproxEqAbs(
            scUsdcYield.receiverPrincipal(bob, 1), principal + addedPrincipal, 1, "receiverPrincipal after topUp"
        );
    }

    function test_close() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(scEth, alice, principal);
        _approve(scEth, alice, address(scEthYield), shares);

        vm.prank(alice);
        scEthYield.open(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "contract's balance");
        assertEq(scEthYield.receiverTotalShares(bob), shares, "receiverShares");
        assertEq(scEthYield.receiverPrincipal(bob, 1), scEth.convertToAssets(shares), "receiverPrincipal");

        _generateYield(scEth, 0.05e18); // 5%

        vm.prank(alice);
        scEthYield.close(1);

        uint256 expectedShares = scEth.convertToShares(principal);
        assertApproxEqAbs(scEth.balanceOf(alice), expectedShares, 1, "alice's shares after close");

        uint256 expectedYield = 0.05 ether;
        assertApproxEqAbs(
            scEthYield.receiverTotalShares(bob), scEth.convertToShares(expectedYield), 1, "receiverShares after close"
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
        _approve(scEth, alice, address(scEthYield), alicesShares);

        vm.prank(alice);
        scEthYield.open(carol, alicesShares, 0);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _depositToVault(scEth, bob, bobsDepositAmount);
        _approve(scEth, bob, address(scEthYield), bobsShares);

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

    function test_multicall_openTwoStreams() public {
        uint256 principal = 1000e6;
        uint256 shares = _depositToVault(scUsdc, alice, principal);
        _approve(scUsdc, alice, address(scUsdcYield), shares);

        bytes[] memory callData = new bytes[](2);

        callData[0] = abi.encodeWithSelector(YieldStreams.open.selector, bob, shares / 2, 0);
        callData[1] = abi.encodeWithSelector(YieldStreams.open.selector, carol, shares / 2, 0);

        vm.prank(alice);
        bytes[] memory results = scUsdcYield.multicall(callData);
        uint256 streamIdBob = abi.decode(results[0], (uint256));
        uint256 streamIdCarol = abi.decode(results[1], (uint256));

        assertApproxEqAbs(scUsdc.balanceOf(address(scUsdcYield)), shares, 1, "contract's balance");
        assertEq(scUsdcYield.receiverTotalShares(bob), shares / 2, "bob's receiverShares");
        assertApproxEqAbs(scUsdcYield.receiverPrincipal(bob, streamIdBob), principal / 2, 1, "bob's receiverPrincipal");
        assertEq(scUsdcYield.receiverTotalShares(carol), shares / 2, "carol's receiverShares");
        assertApproxEqAbs(
            scUsdcYield.receiverPrincipal(carol, streamIdCarol), principal / 2, 1, "carol's receiverPrincipal"
        );
    }

    function test_openMultiple_openTwoStreams() public {
        uint256 principal = 1000e6;
        uint256 shares = _depositToVault(scUsdc, alice, principal);
        _approve(scUsdc, alice, address(scUsdcYield), shares);

        address[] memory receivers = new address[](2);
        uint256[] memory allocations = new uint256[](2);

        receivers[0] = bob;
        allocations[0] = 0.5e18;
        receivers[1] = carol;
        allocations[1] = 0.5e18;

        vm.prank(alice);
        uint256[] memory streamIds = scUsdcYield.openMultiple(shares, receivers, allocations, 0);

        assertApproxEqAbs(scUsdc.balanceOf(address(scUsdcYield)), shares, 1, "contract's balance");
        assertEq(scUsdcYield.receiverTotalShares(bob), shares / 2, "bob's receiverShares");
        assertApproxEqAbs(scUsdcYield.receiverPrincipal(bob, streamIds[0]), principal / 2, 1, "bob's receiverPrincipal");
        assertEq(scUsdcYield.receiverTotalShares(carol), shares / 2, "carol's receiverShares");
        assertApproxEqAbs(
            scUsdcYield.receiverPrincipal(carol, streamIds[1]), principal / 2, 1, "carol's receiverPrincipal"
        );
    }

    function test_depositAndOpenMultipleUsingPermit() public {
        uint256 principal = 1000e6;
        uint256 shares = scUsdc.previewDeposit(principal);

        uint256 deadline = block.timestamp + 1 days;
        deal(address(usdc), dave, principal);

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC20(address(usdc)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(scUsdcYield), principal, 0, deadline))
                )
            )
        );

        // open streams to alice and bob
        address[] memory receivers = new address[](2);
        receivers[0] = alice;
        receivers[1] = bob;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.6e18;
        allocations[1] = 0.3e18;

        vm.prank(dave);
        scUsdcYield.depositAndOpenMultipleUsingPermit(principal, receivers, allocations, 0, deadline, v, r, s);

        // add some yield
        _generateYield(scUsdc, 0.1e18); // 10%

        // assert yield is as expected
        assertEq(scUsdc.balanceOf(address(scUsdcYield)), shares.mulWadDown(0.9e18), "contract's balance");
        assertApproxEqAbs(
            scUsdcYield.previewClaimYield(alice), principal.mulWadDown(0.6e18).mulWadDown(0.1e18), 1, "alice's yield"
        );
        assertApproxEqAbs(
            scUsdcYield.previewClaimYield(bob), principal.mulWadDown(0.3e18).mulWadDown(0.1e18), 1, "bob's yield"
        );
    }
}
