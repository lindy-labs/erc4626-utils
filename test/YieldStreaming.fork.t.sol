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

import {YieldStreaming} from "src/YieldStreaming.sol";

contract YieldStreamingTest is Test {
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

    /// *** yield streaming tests *** ///

    function test_openYieldStream() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, scEthYield);

        vm.prank(alice);
        scEthYield.openYieldStream(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "totalShares");
        assertEq(scEthYield.receiverShares(bob), shares, "receiverShares");
        assertEq(scEthYield.receiverPrincipal(bob, 1), scEth.convertToAssets(shares), "receiverPrincipal");
        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");

        _createProfitForVault(0.05e18, scEth); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        scEthYield.claimYield(bob);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_openYieldStream_toMultipleReceivers() public {
        uint256 depositAmount = 3000e6; // 3000 USDC
        uint256 shares = _deposit(scUsdc, alice, depositAmount);
        _approve(alice, shares, scUsdc, scUsdcYield);

        uint256 bobsShares = shares / 3;
        uint256 carolsShares = shares - bobsShares;

        vm.startPrank(alice);
        scUsdcYield.openYieldStream(bob, bobsShares, 0);
        scUsdcYield.openYieldStream(carol, carolsShares, 0);
        vm.stopPrank();

        assertEq(scUsdc.balanceOf(address(scUsdcYield)), shares, "totalShares");
        assertEq(scUsdcYield.receiverShares(bob), bobsShares, "bob's receiverShares");
        assertEq(scUsdcYield.receiverPrincipal(bob, 1), scUsdc.convertToAssets(bobsShares), "bob's receiverPrincipal");
        assertEq(scUsdcYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(scUsdcYield.receiverShares(carol), carolsShares, "carol's receiverShares");
        assertEq(
            scUsdcYield.receiverPrincipal(carol, 2), scUsdc.convertToAssets(carolsShares), "carol's receiverPrincipal"
        );
        assertEq(scUsdcYield.previewClaimYield(carol), 0, "yieldFor carol");

        _createProfitForVault(0.05e18, scUsdc); // 5%

        uint256 bobsExpectedYield = 50e6;
        uint256 carolsExpectedYield = 100e6;

        assertApproxEqAbs(scUsdcYield.previewClaimYield(bob), bobsExpectedYield, 1, "yieldFor bob");
        assertApproxEqAbs(scUsdcYield.previewClaimYield(carol), carolsExpectedYield, 1, "yieldFor carol");

        vm.prank(bob);
        scUsdcYield.claimYield(bob);

        assertEq(scUsdcYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(usdc.balanceOf(bob), bobsExpectedYield, "bob's balance");

        vm.prank(carol);
        scUsdcYield.claimYield(carol);
        assertEq(scUsdcYield.previewClaimYield(carol), 0, "yieldFor carol");
        assertApproxEqAbs(usdc.balanceOf(carol), carolsExpectedYield, 1, "carol's balance");

        vm.prank(alice);
        scUsdcYield.closeYieldStream(1);

        _createProfitForVault(0.05e18, scUsdc); // 5%

        assertEq(scUsdcYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertApproxEqAbs(scUsdcYield.previewClaimYield(carol), carolsExpectedYield, 2, "yieldFor carol");
    }

    function test_topUp() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, scEthYield);

        vm.prank(alice);
        scEthYield.openYieldStream(bob, shares, 0);

        _createProfitForVault(0.05e18, scEth); // 5%

        uint256 expectedYield = 0.05 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        scEthYield.claimYield(bob);
        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");

        uint256 sharesBeforeTopUp = scEthYield.receiverShares(bob);

        // make another deposit for the same amount
        uint256 topUpShares = _deposit(scEth, alice, 2 ether);
        _approve(alice, topUpShares, scEth, scEthYield);

        vm.prank(alice);
        scEthYield.topUpYieldStream(topUpShares, 1);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(scEthYield.receiverShares(bob), sharesBeforeTopUp + topUpShares, "receiverShares");

        uint256 profitPct = 0.1e18; // 10%

        expectedYield = scEth.convertToAssets(sharesBeforeTopUp + topUpShares).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth); // 10%

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yieldFor bob");
    }

    function test_openYieldStream_fromTwoAccountsToSameReceiver() public {
        uint256 alicesDepositAmount = 1 ether;
        uint256 alicesShares = _deposit(scEth, alice, alicesDepositAmount);
        _approve(alice, alicesShares, scEth, scEthYield);
        vm.prank(alice);
        scEthYield.openYieldStream(carol, alicesShares, 0);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _deposit(scEth, bob, bobsDepositAmount);
        _approve(bob, bobsShares, scEth, scEthYield);
        vm.prank(bob);
        scEthYield.openYieldStream(carol, bobsShares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), alicesShares + bobsShares, "totalShares");
        assertEq(scEthYield.receiverShares(carol), alicesShares + bobsShares, "receiverShares");
        assertApproxEqAbs(scEthYield.receiverPrincipal(carol, 1), alicesDepositAmount, 1, "alice - receiverPrincipal");
        assertApproxEqAbs(scEthYield.receiverPrincipal(carol, 2), bobsDepositAmount, 1, "bob - receiverPrincipal");

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesDepositAmount + bobsDepositAmount).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth);

        assertEq(scEthYield.previewClaimYield(alice), 0, "yieldFor alice");
        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertApproxEqAbs(scEthYield.previewClaimYield(carol), expectedYield, 1, "yieldFor carol");

        vm.prank(carol);
        scEthYield.claimYield(carol);

        assertEq(scEthYield.previewClaimYield(carol), 0, "yieldFor carol");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's balance");
    }

    function test_closeYieldStream() public {
        uint256 depositAmount = 1 ether;
        uint256 shares = _deposit(scEth, alice, depositAmount);
        _approve(alice, shares, scEth, scEthYield);

        vm.prank(alice);
        scEthYield.openYieldStream(bob, shares, 0);

        assertEq(scEth.balanceOf(address(scEthYield)), shares, "totalShares");
        assertEq(scEthYield.receiverShares(bob), shares, "receiverShares");
        assertEq(scEthYield.receiverPrincipal(bob, 1), scEth.convertToAssets(shares), "receiverPrincipal");

        _createProfitForVault(0.05e18, scEth); // 5%

        vm.prank(alice);
        scEthYield.closeYieldStream(1);

        uint256 expectedShares = scEth.convertToShares(depositAmount);
        assertApproxEqAbs(scEth.balanceOf(alice), expectedShares, 1, "alice's shares");

        uint256 expectedYield = 0.05 ether;
        assertApproxEqAbs(scEthYield.receiverShares(bob), scEth.convertToShares(expectedYield), 1, "receiverShares");
        assertApproxEqAbs(scEthYield.receiverPrincipal(bob, 1), 0, 1, "receiverPrincipal");
        assertApproxEqAbs(scEthYield.receiverTotalPrincipal(bob), 0, 1, "receiverTotalPrincipal");

        _createProfitForVault(0.1e18, scEth); // 10%
        expectedYield = 0.055 ether;

        assertApproxEqAbs(scEthYield.previewClaimYield(bob), expectedYield, 1, "yieldFor bob");

        vm.prank(bob);
        scEthYield.claimYield(bob);

        assertEq(scEthYield.previewClaimYield(bob), 0, "yieldFor bob");
        assertEq(weth.balanceOf(bob), expectedYield, "bob's balance");
    }

    function test_closeYieldStream_fromTwoAccountsToSameReceiver() public {
        uint256 alicesDepositAmount = 1 ether;
        uint256 alicesShares = _deposit(scEth, alice, alicesDepositAmount);
        _approve(alice, alicesShares, scEth, scEthYield);
        vm.prank(alice);
        scEthYield.openYieldStream(carol, alicesShares, 0);

        uint256 bobsDepositAmount = 2 ether;
        uint256 bobsShares = _deposit(scEth, bob, bobsDepositAmount);
        _approve(bob, bobsShares, scEth, scEthYield);
        vm.prank(bob);
        scEthYield.openYieldStream(carol, bobsShares, 0);

        uint256 profitPct = 0.05e18; // 5%
        uint256 expectedYield = (alicesDepositAmount + bobsDepositAmount).mulWadDown(profitPct);

        _createProfitForVault(int256(profitPct), scEth);

        vm.prank(alice);
        scEthYield.closeYieldStream(1);

        vm.prank(carol);
        scEthYield.claimYield(carol);

        assertEq(scEthYield.previewClaimYield(carol), 0, "yieldFor carol");
        assertApproxEqAbs(weth.balanceOf(carol), expectedYield, 1, "carol's balance");

        expectedYield = bobsDepositAmount.mulWadDown(profitPct);
        _createProfitForVault(int256(profitPct), scEth);

        assertApproxEqAbs(scEthYield.previewClaimYield(carol), expectedYield, 1, "yieldFor carol");
    }

    /// *** helpers *** ///

    function _deposit(IERC4626 _vault, address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        IERC20 asset = IERC20(_vault.asset());

        deal(address(asset), _from, _amount);
        asset.approve(address(_vault), _amount);
        shares = _vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _approve(address _from, uint256 _shares, IERC4626 _vault, YieldStreaming _streaming) internal {
        vm.prank(_from);
        _vault.approve(address(_streaming), _shares);
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
