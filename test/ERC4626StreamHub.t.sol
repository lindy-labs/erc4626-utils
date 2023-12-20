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

contract ERC4626StreamHubTests is Test {
    using FixedPointMathLib for uint256;

    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);

    ERC4626StreamHub public streamHub;
    MockERC4626 public vault;
    MockERC20 public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        streamHub = new ERC4626StreamHub(IERC4626(address(vault)));

        // make initial deposit to vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    // *** constructor ***

    function test_constructor_failsForAddress0() public {
        vm.expectRevert(ERC4626StreamHub.AddressZero.selector);
        new ERC4626StreamHub(IERC4626(address(0)));
    }

    // *** #openYieldStream ***

    function test_openYieldStream_failsOpeningStreamToSelf() public {
        uint256 amount = 10e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.CannotOpenStreamToSelf.selector);
        streamHub.openYieldStream(alice, shares);
    }

    function test_openYieldStream_failsIfTransferExceedsAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.TransferExceedsAllowance.selector);
        streamHub.openYieldStream(bob, shares + 1);
    }

    function test_openYieldStream_failsFor0Shares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.ZeroShares.selector);
        streamHub.openYieldStream(bob, 0);
    }

    function test_openYieldStream_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.AddressZero.selector);
        streamHub.openYieldStream(address(0), shares);
    }

    function test_openYieldStream_transfersSharesToStreamHub() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        uint256 streamHubShares = vault.balanceOf(address(streamHub));
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        uint256 assets = streamHub.openYieldStream(bob, shares);

        assertEq(assets, amount, "assets");
        assertEq(vault.balanceOf(address(streamHub)), streamHubShares + shares, "streamHub shares");
        assertEq(streamHub.receiverShares(bob), shares, "receiver shares");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(streamHub.receiverPrincipal(bob, alice), amount, "receiver principal");
    }

    function test_openYieldStream_emitsEvent() public {
        uint256 amount = 4e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit OpenYieldStream(alice, bob, shares, amount);

        streamHub.openYieldStream(bob, shares);
    }

    function test_openYieldStream_toTwoAccountsAtTheSameTime() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);
        streamHub.openYieldStream(carol, shares / 4);

        assertEq(vault.balanceOf(alice), shares / 4, "alice's shares");

        assertEq(streamHub.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(streamHub.receiverPrincipal(bob, alice), amount / 2, "receiver principal  bob");

        assertEq(streamHub.receiverShares(carol), shares / 4, "receiver shares carol");
        assertEq(streamHub.receiverTotalPrincipal(carol), amount / 4, "principal carol");
        assertEq(streamHub.receiverPrincipal(carol, alice), amount / 4, "receiver principal  carol");
    }

    function test_openYieldStream_topsUpExistingStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(streamHub.receiverPrincipal(bob, alice), amount / 2, "receiver principal  bob");

        // top up stream
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.receiverShares(bob), shares, "receiver shares bob");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount, "principal bob");
        assertEq(streamHub.receiverPrincipal(bob, alice), amount, "receiver principal  bob");
    }

    function test_openYieldStream_topUpDoesntChangeYieldAccrued() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.2e18);
        uint256 yield = streamHub.yieldFor(bob);

        assertEq(streamHub.yieldFor(bob), yield, "yield before top up");

        // top up stream
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.yieldFor(bob), yield, "yield after top up");
    }

    function test_openYieldStream_topUpAffectsFutureYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        // double the share price
        _createProfitForVault(1e18);

        // top up stream with the remaining shares
        streamHub.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        assertEq(streamHub.yieldFor(bob), (amount * 2).mulWadUp(0.75e18), "yield");
    }

    function test_openYieldStream_topUpWorksWhenClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        _createProfitForVault(-0.5e18);

        uint256 claimerDebt = streamHub.debtFor(bob);

        // top up stream with the remaining shares
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.debtFor(bob), claimerDebt, "claimer debt");
        assertEq(streamHub.receiverShares(bob), shares, "receiver shares");
    }

    function test_openYieldStream_failsIfClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveStreamHub(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);

        // create 10% loss
        _createProfitForVault(-0.1e18);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveStreamHub(bob, bobsShares);

        // bob opens a stream to carol
        vm.prank(bob);
        vm.expectRevert(ERC4626StreamHub.LossToleranceExceeded.selector);
        streamHub.openYieldStream(carol, bobsShares);
    }

    function test_openYieldStream_worksIfClaimerIsInDebtAndLossIsBelowLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveStreamHub(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);

        // create 2% loss
        _createProfitForVault(-0.02e18);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveStreamHub(bob, bobsShares);

        // bob opens a stream to carol
        vm.prank(bob);
        streamHub.openYieldStream(carol, bobsShares);

        uint256 principalWithLoss = vault.convertToAssets(streamHub.previewCloseYieldStream(carol, bob));

        assertTrue(principalWithLoss < bobsDeposit, "principal with loss > bobs deposit");
        assertApproxEqRel(bobsDeposit, principalWithLoss, streamHub.lossTolerancePercent(), "principal with loss");
    }

    function test_openYieldStreamUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 amount = 1 ether;
        uint256 shares = _depositToVault(dave, amount);
        uint256 nonce = vault.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC4626(address(vault)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(streamHub), shares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        streamHub.openYieldStreamUsingPermit(bob, shares, deadline, v, r, s);

        assertEq(vault.balanceOf(address(streamHub)), shares, "streamHub shares");
        assertEq(streamHub.receiverShares(bob), shares, "receiver shares");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(streamHub.receiverPrincipal(bob, dave), amount, "receiver principal");
    }

    // *** #yieldFor ***

    function test_yieldFor_returns0IfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(bob), 0, "yield");
    }

    function test_yieldFor_returns0IfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // no share price increase => no yield
        assertEq(streamHub.yieldFor(bob), 0, "yield");
    }

    function test_yieldFor_returnsGeneratedYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor2 = streamHub.yieldFor(bob);

        assertEq(yieldFor2, amount / 2, "bob's yield");
    }

    function test_yieldFor_returnsGeneratedYieldIfStreamIsClosed() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor = streamHub.yieldFor(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        streamHub.closeYieldStream(bob);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(vault.balanceOf(alice), vault.convertToShares(amount), "alice's shares");
    }

    function test_yieldFor_returns0AfterClaimAndCloseStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor = streamHub.yieldFor(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.stopPrank();

        vm.prank(bob);
        streamHub.claimYield(bob);

        assertEq(streamHub.yieldFor(bob), 0, "bob's yield");
        assertApproxEqAbs(asset.balanceOf(bob), amount / 2, 1, "bob's assets");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");

        vm.prank(alice);
        streamHub.closeYieldStream(bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        assertEq(streamHub.yieldFor(bob), 0, "bob's yield");
    }

    // *** #claimYield ***

    function test_claimYield_toClaimerAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.prank(bob);
        streamHub.claimYield(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(bob), amount / 2, 1, "bob's assets");
    }

    function test_claimYield_toAnotherAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.prank(bob);
        uint256 claimed = streamHub.claimYield(carol);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(carol), claimed, 1, "carol's assets");
    }

    function test_claimYield_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(bob);
        uint256 sharesRedeemed = vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit ClaimYield(bob, carol, sharesRedeemed, yield);

        vm.prank(bob);
        streamHub.claimYield(carol);
    }

    function test_claimYield_revertsToAddressIs0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        assertEq(streamHub.yieldFor(bob), 0, "bob's yield != 0");

        vm.expectRevert(ERC4626StreamHub.AddressZero.selector);
        vm.prank(bob);
        streamHub.claimYield(address(0));
    }

    function test_claimYield_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        assertEq(streamHub.yieldFor(bob), 0, "bob's yield != 0");

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        vm.prank(bob);
        streamHub.claimYield(bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(ERC4626StreamHub.NoYieldToClaim.selector);
        vm.prank(bob);
        streamHub.claimYield(bob);
    }

    function test_claimYield_claimsFromAllOpenedStreams() public {
        uint256 amount = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount);
        _approveStreamHub(alice, alicesShares);
        uint256 bobsShares = _depositToVault(bob, amount * 2);
        _approveStreamHub(bob, bobsShares);

        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);
        vm.prank(bob);
        streamHub.openYieldStream(carol, bobsShares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = bob;
        address[] memory tos = new address[](2);
        tos[0] = carol;
        tos[1] = carol;

        assertEq(streamHub.yieldFor(carol), amount * 3, "carol's yield");

        vm.prank(carol);
        uint256 claimed = streamHub.claimYield(carol);

        assertEq(claimed, amount * 3, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(streamHub.yieldFor(carol), 0, "carols's yield");
    }

    // *** #closeYieldStream ***

    function test_closeYieldStream_restoresSenderBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        uint256 sharesReturned = streamHub.closeYieldStream(bob);

        assertApproxEqAbs(sharesReturned, shares - yieldValueInShares, 1, "shares returned");
        assertEq(vault.balanceOf(alice), sharesReturned, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_closeYieldStream_emitsEvent() public {
        uint256 principal = 2e18;
        uint256 shares = _depositToVault(alice, principal);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        uint256 yield = streamHub.yieldFor(bob);
        uint256 unlockedShares = shares - vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit CloseYieldStream(alice, bob, unlockedShares, principal);

        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_continuesGeneratingFurtherYieldForReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 bobsYield = streamHub.yieldFor(bob);

        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(streamHub.yieldFor(bob), bobsYield, 1, "bob's yield changed");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(streamHub.yieldFor(bob), expectedYield, 1, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_closeYieldStream_worksIfVaultMadeLosses() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        streamHub.closeYieldStream(bob);

        assertEq(vault.convertToAssets(shares), amount.mulWadUp(0.8e18), "shares value");
        assertEq(streamHub.yieldFor(bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
    }

    function test_closeYieldStream_failsIfStreamIsAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // works
        streamHub.closeYieldStream(bob);

        // fails
        vm.expectRevert(ERC4626StreamHub.StreamDoesNotExist.selector);
        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameStreamer() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);
        streamHub.openYieldStream(carol, shares / 2);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        uint256 bobsYield = streamHub.yieldFor(bob);
        uint256 carolsYield = streamHub.yieldFor(carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");
        assertEq(vault.balanceOf(alice), 0, "alice's shares != 0");

        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), amount / 2, 1, "alice's principal");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(streamHub.yieldFor(bob), bobsYield, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(streamHub.yieldFor(carol), carolsYield, "carol's yield");
    }

    function test_closeYieldStream_doesntAffectOtherStreamFromTheAnotherStreamer() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveStreamHub(alice, alicesShares);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveStreamHub(bob, bobsShares);

        // alice opens a stream to carol
        vm.prank(alice);
        streamHub.openYieldStream(carol, alicesShares);

        // bob opens a stream to carol
        vm.prank(bob);
        streamHub.openYieldStream(carol, bobsShares);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        assertEq(streamHub.receiverTotalPrincipal(carol), alicesDeposit + bobsDeposit, "carol's total principal");

        uint256 carolsYield = streamHub.yieldFor(carol);

        vm.prank(alice);
        streamHub.closeYieldStream(carol);

        assertApproxEqAbs(streamHub.yieldFor(carol), carolsYield, 1, "carol's yield");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), alicesDeposit, 2, "alice's shares value");
        assertEq(streamHub.receiverPrincipal(carol, alice), 0, "alice's principal");
        assertEq(streamHub.receiverPrincipal(carol, bob), bobsDeposit, "bob's principal");
        assertEq(streamHub.receiverTotalPrincipal(carol), bobsDeposit, "carol's total principal");
    }

    // *** #multicall ***

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, bob, (shares * 3) / 4);
        data[1] = abi.encodeWithSelector(ERC4626StreamHub.openYieldStream.selector, carol, shares / 4);

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(streamHub.receiverShares(bob), (shares * 3) / 4, "receiver shares bob");
        assertEq(streamHub.receiverShares(carol), shares / 4, "receiver shares carol");
    }

    function testFuzz_open_claim_close_stream(uint256 amount) public {
        amount = bound(amount, 10000, 1000 ether);
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);
        vm.startPrank(alice);

        // open 10 streams
        uint256 sharesToOpen = shares / 10;
        address[] memory receivers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            // generate random receiver address
            receivers[i] = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp + i, block.difficulty)))));
            streamHub.openYieldStream(receivers[i], sharesToOpen);
        }

        vm.stopPrank();

        _createProfitForVault(0.5e18);

        uint256 expectedYield = amount.mulDivDown(0.5e18, 10e18);

        // claim yield
        for (uint256 i = 0; i < 10; i++) {
            assertEq(streamHub.yieldFor(receivers[i]), expectedYield, "yield");

            vm.prank(receivers[i]);
            streamHub.claimYield(receivers[i]);

            assertApproxEqAbs(asset.balanceOf(receivers[i]), expectedYield, 3, "assets");
            assertEq(streamHub.yieldFor(receivers[i]), 0, "yield");
        }

        // close streams
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            streamHub.closeYieldStream(receivers[i]);
        }

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), amount, 0.005e18, "alice's pricipal");
        assertEq(vault.balanceOf(address(streamHub)), 0, "streamHub's shares");
    }

    // *** helpers ***

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        deal(address(asset), _from, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _approveStreamHub(address _from, uint256 _shares) internal {
        vm.prank(_from);
        vault.approve(address(streamHub), _shares);
    }

    function _createProfitForVault(int256 _profit) internal {
        deal(address(asset), address(vault), vault.totalAssets().mulWadDown(uint256(1e18 + _profit)));
    }
}
