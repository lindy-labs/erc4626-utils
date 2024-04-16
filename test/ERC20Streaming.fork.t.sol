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

import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract ERC20StreamingTest is Test {
    using FixedPointMathLib for uint256;

    ERC20Streaming public scEthStreaming;
    ERC20Streaming public scUsdcStreaming;
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

        scEthStreaming = new ERC20Streaming(scEth);

        // TODO: add test for USDC
        scUsdcStreaming = new ERC20Streaming(scUsdc);
    }

    function test_openStream_claimTokens() public {
        uint256 duration = 2 days;
        uint256 shares = _deposit(scEth, alice, 1 ether);
        _approve(alice, shares, scEth, scEthStreaming);

        vm.prank(alice);
        scEthStreaming.openStream(bob, shares, duration);

        assertEq(scEth.balanceOf(address(scEthStreaming)), shares, "contract shares");

        _createProfitForVault(0.05e18, scEth); // 5%

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
        uint256 shares = _deposit(scEth, alice, 1 ether);
        _approve(alice, shares, scEth, scEthStreaming);

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
        uint256 shares1 = _deposit(scEth, alice, 1 ether);
        uint256 duration1 = 2 days;
        uint256 shares2 = _deposit(scEth, bob, 2 ether);
        uint256 duration2 = 4 days;
        _approve(alice, shares1, scEth, scEthStreaming);
        _approve(bob, shares2, scEth, scEthStreaming);

        vm.prank(alice);
        scEthStreaming.openStream(carol, shares1, duration1);
        vm.prank(bob);
        scEthStreaming.openStream(carol, shares2, duration2);

        vm.warp(block.timestamp + 1 days);

        uint256 shares3 = _deposit(scEth, carol, 3 ether);
        uint256 duration3 = 6 days;
        _approve(carol, shares3, scEth, scEthStreaming);

        vm.prank(carol);
        scEthStreaming.openStream(alice, shares3, duration3);

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(carol);
        scEthStreaming.claim(alice, carol);
        scEthStreaming.claim(bob, carol);
        vm.stopPrank();

        assertEq(scEth.balanceOf(alice), 0, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(scEth.balanceOf(carol), shares1 + shares2 / 2, 0.00001e18, "carol's shares");

        vm.prank(alice);
        scEthStreaming.claim(carol, alice);

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(carol);
        scEthStreaming.claim(bob, carol);
        scEthStreaming.closeStream(alice);
        vm.stopPrank();

        assertApproxEqRel(scEth.balanceOf(alice), shares3 / 2, 0.00001e18, "alice's shares");
        assertEq(scEth.balanceOf(bob), 0, "bob's shares");
        assertApproxEqRel(scEth.balanceOf(carol), shares1 + shares2 + shares3 / 2, 0.00001e18, "carol's shares");
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

    function _approve(address _from, uint256 _shares, IERC4626 _vault, ERC20Streaming _streaming) internal {
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
