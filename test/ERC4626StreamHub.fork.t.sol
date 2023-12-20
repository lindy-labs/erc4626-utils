// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";
import {ERC4626StreamHubFactory} from "../src/ERC4626StreamHubFactory.sol";

contract ERC4626StreamHubForkTests is Test {
    using FixedPointMathLib for uint256;

    ERC4626StreamHub public wethStreamHub;
    ERC4626StreamHub public usdcStreamHub;
    ERC4626StreamHubFactory public factory;
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

        factory = new ERC4626StreamHubFactory();

        wethStreamHub = ERC4626StreamHub(factory.predictDeploy(address(scEth)));
        factory.create(address(scEth));
        usdcStreamHub = ERC4626StreamHub(factory.predictDeploy(address(scUsdc)));
        factory.create(address(scUsdc));
    }

    function test_openYieldStream() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, wethStreamHub);

        vm.prank(alice);
        wethStreamHub.openYieldStream(bob, shares);

        assertEq(scEth.balanceOf(address(wethStreamHub)), shares, "totalShares");
        assertEq(wethStreamHub.receiverShares(bob), shares, "receiverShares");
        assertEq(wethStreamHub.receiverPrincipal(bob, alice), scEth.convertToAssets(shares), "receiverPrincipal");
        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");

        _createProfitForVault(0.05e18, scEth); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(wethStreamHub.yieldFor(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        wethStreamHub.claimYield(bob);

        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_openYieldStream_toMultipleReceivers() public {
        uint256 depositAmount = 3000e6; // 1000 USDC
        uint256 shares = _deposit(scUsdc, alice, depositAmount);
        _approve(alice, shares, scUsdc, usdcStreamHub);

        uint256 bobsShares = shares / 3;
        uint256 carolsShares = shares - bobsShares;

        vm.startPrank(alice);
        usdcStreamHub.openYieldStream(bob, bobsShares);
        usdcStreamHub.openYieldStream(carol, carolsShares);
        vm.stopPrank();

        assertEq(scUsdc.balanceOf(address(usdcStreamHub)), shares, "totalShares");
        assertEq(usdcStreamHub.receiverShares(bob), bobsShares, "bob's receiverShares");
        assertEq(
            usdcStreamHub.receiverPrincipal(bob, alice), scUsdc.convertToAssets(bobsShares), "bob's receiverPrincipal"
        );
        assertEq(usdcStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertEq(usdcStreamHub.receiverShares(carol), carolsShares, "carol's receiverShares");
        assertEq(
            usdcStreamHub.receiverPrincipal(carol, alice),
            scUsdc.convertToAssets(carolsShares),
            "carol's receiverPrincipal"
        );
        assertEq(usdcStreamHub.yieldFor(carol), 0, "yieldFor carol");

        _createProfitForVault(0.05e18, scUsdc); // 5%

        uint256 bobsExpectedYield = 50e6;
        uint256 carolsExpectedYield = 100e6;

        assertApproxEqAbs(usdcStreamHub.yieldFor(bob), bobsExpectedYield, 1, "yieldFor bob");
        assertApproxEqAbs(usdcStreamHub.yieldFor(carol), carolsExpectedYield, 1, "yieldFor carol");

        vm.prank(bob);
        usdcStreamHub.claimYield(bob);

        assertEq(usdcStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertEq(usdc.balanceOf(bob), bobsExpectedYield, "bob's balance");

        vm.prank(carol);
        usdcStreamHub.claimYield(carol);
        assertEq(usdcStreamHub.yieldFor(carol), 0, "yieldFor carol");
        assertApproxEqAbs(usdc.balanceOf(carol), carolsExpectedYield, 1, "carol's balance");

        vm.prank(alice);
        usdcStreamHub.closeYieldStream(bob);

        _createProfitForVault(0.05e18, scUsdc); // 5%

        assertEq(usdcStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertApproxEqAbs(usdcStreamHub.yieldFor(carol), carolsExpectedYield, 2, "yieldFor carol");
    }

    function test_openYieldStream_topUp() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, wethStreamHub);

        vm.prank(alice);
        wethStreamHub.openYieldStream(bob, shares);

        _createProfitForVault(0.05e18, scEth); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(wethStreamHub.yieldFor(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        wethStreamHub.claimYield(bob);
        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");

        uint256 sharesBeforeTopUp = wethStreamHub.receiverShares(bob);

        // make another deposit for the same amount
        uint256 topUpShares = _deposit(scEth, alice, 2 ether);
        _approve(alice, topUpShares, scEth, wethStreamHub);

        vm.prank(alice);
        wethStreamHub.openYieldStream(bob, topUpShares);

        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertEq(wethStreamHub.receiverShares(bob), sharesBeforeTopUp + topUpShares, "receiverShares");

        uint256 profitPct = 0.1e18; // 10%

        expectedYield = scEth.convertToAssets(sharesBeforeTopUp + topUpShares).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth); // 10%

        assertApproxEqAbs(wethStreamHub.yieldFor(bob), expectedYield, 1, "yieldFor bob");
    }

    function test_openYieldStream_fromTwoAccountsToSameReceiver() public {
        uint256 alicesDepositAmount = 1 ether;
        uint256 alicesShares = _deposit(scEth, alice, alicesDepositAmount);
        _approve(alice, alicesShares, scEth, wethStreamHub);
        vm.prank(alice);
        wethStreamHub.openYieldStream(carol, alicesShares);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _deposit(scEth, bob, bobsDepositAmount);
        _approve(bob, bobsShares, scEth, wethStreamHub);
        vm.prank(bob);
        wethStreamHub.openYieldStream(carol, bobsShares);

        assertEq(scEth.balanceOf(address(wethStreamHub)), alicesShares + bobsShares, "totalShares");
        assertEq(wethStreamHub.receiverShares(carol), alicesShares + bobsShares, "receiverShares");
        assertApproxEqAbs(
            wethStreamHub.receiverPrincipal(carol, alice), alicesDepositAmount, 1, "alice - receiverPrincipal"
        );
        assertApproxEqAbs(wethStreamHub.receiverPrincipal(carol, bob), bobsDepositAmount, 1, "bob - receiverPrincipal");

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesDepositAmount + bobsDepositAmount).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth);

        assertEq(wethStreamHub.yieldFor(alice), 0, "yieldFor alice");
        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertApproxEqAbs(wethStreamHub.yieldFor(carol), expectedYield, 1, "yieldFor carol");

        vm.prank(carol);
        wethStreamHub.claimYield(carol);

        assertEq(wethStreamHub.yieldFor(carol), 0, "yieldFor carol");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's balance");
    }

    function test_closeYieldStream() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, wethStreamHub);

        vm.prank(alice);
        wethStreamHub.openYieldStream(bob, shares);

        assertEq(scEth.balanceOf(address(wethStreamHub)), shares, "totalShares");
        assertEq(wethStreamHub.receiverShares(bob), shares, "receiverShares");
        assertEq(wethStreamHub.receiverPrincipal(bob, alice), scEth.convertToAssets(shares), "receiverPrincipal");

        _createProfitForVault(0.05e18, scEth); // 5%

        vm.prank(alice);
        wethStreamHub.closeYieldStream(bob);

        uint256 expectedShares = scEth.convertToShares(depositAmount);
        assertApproxEqAbs(scEth.balanceOf(alice), expectedShares, 1, "alice's shares");

        uint256 expectedYield = 0.05 ether;
        assertApproxEqAbs(wethStreamHub.receiverShares(bob), scEth.convertToShares(expectedYield), 1, "receiverShares");
        assertApproxEqAbs(wethStreamHub.receiverPrincipal(bob, alice), 0, 1, "receiverPrincipal");
        assertApproxEqAbs(wethStreamHub.receiverTotalPrincipal(bob), 0, 1, "receiverTotalPrincipal");

        _createProfitForVault(0.1e18, scEth); // 10%
        expectedYield = 0.055 ether;

        assertApproxEqAbs(wethStreamHub.yieldFor(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        wethStreamHub.claimYield(bob);

        assertEq(wethStreamHub.yieldFor(bob), 0, "yieldFor bob");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_closeYieldStream_fromTwoAccountsToSameReceiver() public {
        uint256 alicesDepositAmount = 1 ether;
        uint256 alicesShares = _deposit(scEth, alice, alicesDepositAmount);
        _approve(alice, alicesShares, scEth, wethStreamHub);
        vm.prank(alice);
        wethStreamHub.openYieldStream(carol, alicesShares);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _deposit(scEth, bob, bobsDepositAmount);
        _approve(bob, bobsShares, scEth, wethStreamHub);
        vm.prank(bob);
        wethStreamHub.openYieldStream(carol, bobsShares);

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesDepositAmount + bobsDepositAmount).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth);

        vm.prank(alice);
        wethStreamHub.closeYieldStream(carol);

        vm.prank(carol);
        wethStreamHub.claimYield(carol);

        assertEq(wethStreamHub.yieldFor(carol), 0, "yieldFor carol");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's balance");

        expectedYield = bobsDepositAmount.mulWadDown(profitPct);
        _createProfitForVault(int256(profitPct), scEth);

        assertApproxEqAbs(wethStreamHub.yieldFor(carol), expectedYield, 1, "yieldFor carol");
    }

    // *** helpers ***

    function _deposit(IERC4626 _vault, address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        IERC20 asset = IERC20(_vault.asset());

        deal(address(asset), _from, _amount);
        asset.approve(address(_vault), _amount);
        shares = _vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _approve(address _from, uint256 _shares, IERC4626 _vault, ERC4626StreamHub _streamHub) internal {
        vm.prank(_from);
        _vault.approve(address(_streamHub), _shares);
    }

    function _createProfitForVault(int256 _profit, IERC4626 _vault) internal {
        IERC20 asset = IERC20(_vault.asset());

        uint256 balance = asset.balanceOf(address(_vault));
        uint256 totalAssets = _vault.totalAssets();
        uint256 endTotalAssets = totalAssets.mulWadDown(uint256(1e18 + _profit));
        uint256 delta = endTotalAssets - totalAssets;

        deal(address(asset), address(_vault), balance + delta);
    }
}
