// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldStreaming} from "../src/YieldStreaming.sol";
import "../src/common/Errors.sol";

contract YieldStreamingTests is Test {
    using FixedPointMathLib for uint256;

    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event LossTolerancePercentUpdated(address indexed owner, uint256 oldValue, uint256 newValue);

    YieldStreaming public yieldStreaming;
    MockERC4626 public vault;
    MockERC20 public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        yieldStreaming = new YieldStreaming(IERC4626(address(vault)));

        // make initial deposit to vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    // *** constructor *** ///

    function test_constructor_failsIfVaultIsAddress0() public {
        vm.expectRevert(AddressZero.selector);
        new YieldStreaming(IERC4626(address(0)));
    }

    // *** #openYieldStream ***

    function test_openYieldStream_failsOpeningStreamToSelf() public {
        uint256 amount = 10e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(CannotOpenStreamToSelf.selector);
        yieldStreaming.openYieldStream(alice, shares);
    }

    function test_openYieldStream_failsIfTransferExceedsAllowance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(TransferExceedsAllowance.selector);
        yieldStreaming.openYieldStream(bob, shares + 1);
    }

    function test_openYieldStream_failsFor0Shares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(AmountZero.selector);
        yieldStreaming.openYieldStream(bob, 0);
    }

    function test_openYieldStream_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(AddressZero.selector);
        yieldStreaming.openYieldStream(address(0), shares);
    }

    function test_openYieldStream_transfersSharesToStreamHub() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        uint256 streamHubShares = vault.balanceOf(address(yieldStreaming));
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        uint256 assets = yieldStreaming.openYieldStream(bob, shares);

        assertEq(assets, amount, "assets");
        assertEq(vault.balanceOf(address(yieldStreaming)), streamHubShares + shares, "streamHub shares");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, alice), amount, "receiver principal");
    }

    function test_openYieldStream_emitsEvent() public {
        uint256 amount = 4e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit OpenYieldStream(alice, bob, shares, amount);

        yieldStreaming.openYieldStream(bob, shares);
    }

    function test_openYieldStream_toTwoAccountsAtTheSameTime() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);
        yieldStreaming.openYieldStream(carol, shares / 4);

        assertEq(vault.balanceOf(alice), shares / 4, "alice's shares");

        assertEq(yieldStreaming.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, alice), amount / 2, "receiver principal  bob");

        assertEq(yieldStreaming.receiverShares(carol), shares / 4, "receiver shares carol");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), amount / 4, "principal carol");
        assertEq(yieldStreaming.receiverPrincipal(carol, alice), amount / 4, "receiver principal  carol");
    }

    function test_openYieldStream_topsUpExistingStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);

        assertEq(yieldStreaming.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, alice), amount / 2, "receiver principal  bob");

        // top up stream
        yieldStreaming.openYieldStream(bob, shares / 2);

        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, alice), amount, "receiver principal  bob");
    }

    function test_openYieldStream_topUpDoesntChangeYieldAccrued() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.2e18);
        uint256 yield = yieldStreaming.previewClaimYield(bob);

        assertEq(yieldStreaming.previewClaimYield(bob), yield, "yield before top up");

        // top up stream
        yieldStreaming.openYieldStream(bob, shares / 2);

        assertEq(yieldStreaming.previewClaimYield(bob), yield, "yield after top up");
    }

    function test_openYieldStream_topUpAffectsFutureYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);

        // double the share price
        _createProfitForVault(1e18);

        // top up stream with the remaining shares
        yieldStreaming.openYieldStream(bob, shares / 2);

        _createProfitForVault(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        assertEq(yieldStreaming.previewClaimYield(bob), (amount * 2).mulWadUp(0.75e18), "yield");
    }

    function test_openYieldStream_topUpWorksWhenClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);

        _createProfitForVault(-0.5e18);

        uint256 claimerDebt = yieldStreaming.debtFor(bob);

        // top up stream with the remaining shares
        yieldStreaming.openYieldStream(bob, shares / 2);

        assertEq(yieldStreaming.debtFor(bob), claimerDebt, "claimer debt");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
    }

    function test_openYieldStream_failsIfClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveStreamHub(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares);

        // create 10% loss
        _createProfitForVault(-0.1e18);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveStreamHub(bob, bobsShares);

        // bob opens a stream to carol
        vm.prank(bob);
        vm.expectRevert(YieldStreaming.LossToleranceExceeded.selector);
        yieldStreaming.openYieldStream(carol, bobsShares);
    }

    function test_openYieldStream_worksIfClaimerIsInDebtAndLossIsBelowLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveStreamHub(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares);

        // create 2% loss
        _createProfitForVault(-0.02e18);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveStreamHub(bob, bobsShares);

        // bob opens a stream to carol
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares);

        uint256 principalWithLoss = vault.convertToAssets(yieldStreaming.previewCloseYieldStream(carol, bob));

        assertTrue(principalWithLoss < bobsDeposit, "principal with loss > bobs deposit");
        assertApproxEqRel(bobsDeposit, principalWithLoss, yieldStreaming.lossTolerancePercent(), "principal with loss");
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
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(yieldStreaming), shares, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        yieldStreaming.openYieldStreamUsingPermit(bob, shares, deadline, v, r, s);

        assertEq(vault.balanceOf(address(yieldStreaming)), shares, "streamHub shares");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, dave), amount, "receiver principal");
    }

    // *** #previewClaimYield *** ///

    function test_previewClaimYield_returns0IfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returns0IfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returnsGeneratedYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 previewClaimYield2 = yieldStreaming.previewClaimYield(bob);

        assertEq(previewClaimYield2, amount / 2, "bob's yield");
    }

    function test_previewClaimYield_returnsGeneratedYieldIfStreamIsClosed() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor = yieldStreaming.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        yieldStreaming.closeYieldStream(bob);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(vault.balanceOf(alice), vault.convertToShares(amount), "alice's shares");
    }

    function test_previewClaimYield_returns0AfterClaimAndCloseStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor = yieldStreaming.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.stopPrank();

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
        assertApproxEqAbs(asset.balanceOf(bob), amount / 2, 1, "bob's assets");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");

        vm.prank(alice);
        yieldStreaming.closeYieldStream(bob);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
    }

    // *** #claimYield *** ///

    function test_claimYield_toClaimerAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(bob), amount / 2, 1, "bob's assets");
    }

    function test_claimYield_toAnotherAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(carol), claimed, 1, "carol's assets");
    }

    function test_claimYield_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 sharesRedeemed = vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit ClaimYield(bob, carol, sharesRedeemed, yield);

        vm.prank(bob);
        yieldStreaming.claimYield(carol);
    }

    function test_claimYield_revertsToAddressIs0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(address(0));
    }

    function test_claimYield_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_claimsFromAllOpenedStreams() public {
        uint256 amount1 = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount1);
        _approveStreamHub(alice, alicesShares);
        uint256 amount2 = 3e18;
        uint256 bobsShares = _depositToVault(bob, amount2);
        _approveStreamHub(bob, bobsShares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares);
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        assertEq(yieldStreaming.previewClaimYield(carol), amount1 + amount2, "carol's yield");

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertEq(claimed, amount1 + amount2, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    // *** #claimYieldInShares *** ///

    function test_claimYieldInShares_toClaimerAccount() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYieldInShares(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(bob), shares / 2, "bob's shares");
        assertEq(vault.balanceOf(bob), claimed, "claimed yield in shares");
    }

    function test_claimYieldInShares_toAnotherAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares(amount / 2);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(vault.balanceOf(bob), 0, "bob's shares");
        assertApproxEqAbs(vault.balanceOf(carol), claimed, 1, "carol's shares");
        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed yield in shares");
    }

    function test_claimYieldInShares_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYieldInShares(bob);

        vm.expectEmit(true, true, true, true);
        emit ClaimYieldInShares(bob, carol, yield);

        vm.prank(bob);
        yieldStreaming.claimYieldInShares(carol);
    }

    function test_claimYieldInShares_revertsToAddressIs0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(address(0));
    }

    function test_claimYieldInShares_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(bob);
    }

    function test_claimYieldInShares_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYieldInShares_claimsFromAllOpenedStreams() public {
        uint256 amount1 = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount1);
        _approveStreamHub(alice, alicesShares);
        uint256 amount2 = 3e18;
        uint256 bobsShares = _depositToVault(bob, amount2);
        _approveStreamHub(bob, bobsShares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares);
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 expectedYield = amount1 / 2 + amount2 / 2;
        uint256 expectedYieldInShares = vault.convertToShares(expectedYield);

        assertApproxEqAbs(yieldStreaming.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's yield");

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
    }

    // *** #closeYieldStream *** ///

    function test_closeYieldStream_restoresSenderBalance() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        uint256 sharesReturned = yieldStreaming.closeYieldStream(bob);

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
        yieldStreaming.openYieldStream(bob, shares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 unlockedShares = shares - vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit CloseYieldStream(alice, bob, unlockedShares, principal);

        yieldStreaming.closeYieldStream(bob);
    }

    function test_closeYieldStream_continuesGeneratingFurtherYieldForReceiver() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);

        yieldStreaming.closeYieldStream(bob);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), bobsYield, 1, "bob's yield changed");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), expectedYield, 1, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_closeYieldStream_worksIfVaultMadeLosses() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        yieldStreaming.closeYieldStream(bob);

        assertEq(vault.convertToAssets(shares), amount.mulWadUp(0.8e18), "shares value");
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
    }

    function test_closeYieldStream_failsIfStreamIsAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares);

        // works
        yieldStreaming.closeYieldStream(bob);

        // fails
        vm.expectRevert(StreamDoesNotExist.selector);
        yieldStreaming.closeYieldStream(bob);
    }

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameStreamer() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2);
        yieldStreaming.openYieldStream(carol, shares / 2);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);
        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");
        assertEq(vault.balanceOf(alice), 0, "alice's shares != 0");

        yieldStreaming.closeYieldStream(bob);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), amount / 2, 1, "alice's principal");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(yieldStreaming.previewClaimYield(bob), bobsYield, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(yieldStreaming.previewClaimYield(carol), carolsYield, "carol's yield");
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
        yieldStreaming.openYieldStream(carol, alicesShares);

        // bob opens a stream to carol
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        assertEq(yieldStreaming.receiverTotalPrincipal(carol), alicesDeposit + bobsDeposit, "carol's total principal");

        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        vm.prank(alice);
        yieldStreaming.closeYieldStream(carol);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(carol), carolsYield, 1, "carol's yield");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), alicesDeposit, 2, "alice's shares value");
        assertEq(yieldStreaming.receiverPrincipal(carol, alice), 0, "alice's principal");
        assertEq(yieldStreaming.receiverPrincipal(carol, bob), bobsDeposit, "bob's principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), bobsDeposit, "carol's total principal");
    }

    // *** #multicall *** ///

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(YieldStreaming.openYieldStream.selector, bob, (shares * 3) / 4);
        data[1] = abi.encodeWithSelector(YieldStreaming.openYieldStream.selector, carol, shares / 4);

        vm.startPrank(alice);
        vault.approve(address(yieldStreaming), shares);
        yieldStreaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(yieldStreaming.receiverShares(bob), (shares * 3) / 4, "receiver shares bob");
        assertEq(yieldStreaming.receiverShares(carol), shares / 4, "receiver shares carol");
    }

    /// *** fuzzing *** ///

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
            receivers[i] = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp + i, block.prevrandao)))));
            yieldStreaming.openYieldStream(receivers[i], sharesToOpen);
        }

        vm.stopPrank();

        _createProfitForVault(0.5e18);

        uint256 expectedYield = amount.mulDivDown(0.5e18, 10e18);

        // claim yield
        for (uint256 i = 0; i < 10; i++) {
            assertEq(yieldStreaming.previewClaimYield(receivers[i]), expectedYield, "yield");

            vm.prank(receivers[i]);
            yieldStreaming.claimYield(receivers[i]);

            assertApproxEqAbs(asset.balanceOf(receivers[i]), expectedYield, 3, "assets");
            assertEq(yieldStreaming.previewClaimYield(receivers[i]), 0, "yield");
        }

        // close streams
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            yieldStreaming.closeYieldStream(receivers[i]);
        }

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), amount, 0.005e18, "alice's pricipal");
        assertEq(vault.balanceOf(address(yieldStreaming)), 0, "streamHub's shares");
    }

    // *** helpers *** ///

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        deal(address(asset), _from, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _approveStreamHub(address _from, uint256 _shares) internal {
        vm.prank(_from);
        vault.approve(address(yieldStreaming), _shares);
    }

    function _createProfitForVault(int256 _profit) internal {
        deal(address(asset), address(vault), vault.totalAssets().mulWadDown(uint256(1e18 + _profit)));
    }
}
