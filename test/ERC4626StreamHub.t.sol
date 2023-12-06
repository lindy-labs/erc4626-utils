// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/interfaces/IERC20Metadata.sol";
import {ERC4626Mock} from "openzeppelin-contracts/mocks/ERC4626Mock.sol";
import {ERC20Mock} from "openzeppelin-contracts/mocks/ERC20Mock.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";

import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract ERC4626StreamHubTests is Test {
    using FixedPointMathLib for uint256;

    event OpenYieldStream(
        address indexed streamer,
        address indexed receiver,
        uint256 shares,
        uint256 principal
    );
    event ClaimYield(
        address indexed receiver,
        address indexed claimedTo,
        uint256 yield
    );
    event CloseYieldStream(
        address indexed streamer,
        address indexed receiver,
        uint256 shares
    );

    ERC4626StreamHub public streamHub;
    IERC4626 public vault;
    IERC20Metadata public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new ERC20Mock("ERC20Mock", "ERC20Mock", address(this), 0);
        vault = new ERC4626Mock(asset, "ERC4626Mock", "ERC4626Mock");
        streamHub = new ERC4626StreamHub(vault);

        // make initial deposit to vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    // *** #openYieldStream ***

    function test_openYieldStream_toSelf() public {
        uint256 amount = 10e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.CannotOpenStreamToSelf.selector);
        streamHub.openYieldStream(alice, shares);
    }

    function test_openYieldStream_failsIfNotEnoughShares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert("ERC20: insufficient allowance");
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
        streamHub.openYieldStream(bob, shares);

        assertEq(
            vault.balanceOf(address(streamHub)),
            streamHubShares + shares,
            "streamHub shares"
        );
        assertEq(streamHub.receiverShares(bob), shares, "shares of");
        assertEq(streamHub.receiverTotalPrincipal(bob), amount, "principal");
        assertEq(streamHub.receiverPrincipal(bob, alice), amount, "deposited");
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

        assertEq(
            streamHub.receiverShares(bob),
            shares / 2,
            "receiver shares bob"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(bob),
            amount / 2,
            "principal bob"
        );
        assertEq(
            streamHub.receiverPrincipal(bob, alice),
            amount / 2,
            "receiver principal  bob"
        );

        assertEq(
            streamHub.receiverShares(carol),
            shares / 4,
            "receiver shares carol"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(carol),
            amount / 4,
            "principal carol"
        );
        assertEq(
            streamHub.receiverPrincipal(carol, alice),
            amount / 4,
            "receiver principal  carol"
        );
    }

    function test_openYieldStream_topsUpExistingStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(
            streamHub.receiverShares(bob),
            shares / 2,
            "receiver shares bob"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(bob),
            amount / 2,
            "principal bob"
        );
        assertEq(
            streamHub.receiverPrincipal(bob, alice),
            amount / 2,
            "receiver principal  bob"
        );

        // top up stream
        streamHub.openYieldStream(bob, shares / 2);

        assertEq(streamHub.receiverShares(bob), shares, "receiver shares bob");
        assertEq(
            streamHub.receiverTotalPrincipal(bob),
            amount,
            "principal bob"
        );
        assertEq(
            streamHub.receiverPrincipal(bob, alice),
            amount,
            "receiver principal  bob"
        );
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
        assertEq(
            streamHub.yieldFor(bob),
            (amount * 2).mulWadUp(0.75e18),
            "yield"
        );
    }

    // *** #openYieldStreamBatch ***

    function test_openYieldStreamBatch_createsStreamsForAllReceivers() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = (shares * 3) / 4;
        allocations[1] = shares / 4;

        vm.startPrank(alice);
        streamHub.openYieldStreamBatch(receivers, allocations);

        assertEq(
            streamHub.receiverShares(bob),
            (shares * 3) / 4,
            "receiver shares bob"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(bob),
            (amount * 3) / 4,
            "principal bob"
        );
        assertEq(
            streamHub.receiverPrincipal(bob, alice),
            (amount * 3) / 4,
            "receiver principal  bob"
        );

        assertEq(
            streamHub.receiverShares(carol),
            shares / 4,
            "receiver shares carol"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(carol),
            amount / 4,
            "principal carol"
        );
        assertEq(
            streamHub.receiverPrincipal(carol, alice),
            amount / 4,
            "receiver principal  carol"
        );
    }

    function test_openYieldStreamBatch_failsIfReceiversAndAllocationLengthsDontMatch()
        public
    {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = shares;

        vm.startPrank(alice);
        vm.expectRevert(ERC4626StreamHub.InputParamsLengthMismatch.selector);
        streamHub.openYieldStreamBatch(receivers, allocations);
    }

    function test_openYieldStreamBatch_failsIfAllocationIsGreaterThanSharesBalance()
        public
    {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = shares;
        allocations[1] = 1; // 1 more than available

        vm.startPrank(alice);
        vm.expectRevert("ERC20: insufficient allowance");
        streamHub.openYieldStreamBatch(receivers, allocations);
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
        assertEq(
            vault.balanceOf(alice),
            vault.convertToShares(amount),
            "alice's shares"
        );
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

        // claim yield
        vm.prank(bob);
        streamHub.claimYield(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(bob), amount / 2, 1, "bob's assets");
    }

    function test_claimYield_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _approveStreamHub(alice, shares);

        vm.prank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = streamHub.yieldFor(bob);

        vm.expectEmit(true, true, true, true);
        emit ClaimYield(bob, bob, yield);

        vm.prank(bob);
        streamHub.claimYield(bob);
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
        streamHub.claimYield(carol);

        assertEq(asset.balanceOf(carol), amount * 3, "carol's assets");
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

        // claim yield
        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(
            vault.balanceOf(alice),
            shares - yieldValueInShares,
            1,
            "alice's shares"
        );
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_closeYieldStream_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        uint256 yield = streamHub.yieldFor(bob);
        uint256 unlockedShares = shares - vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit CloseYieldStream(alice, bob, unlockedShares);

        streamHub.closeYieldStream(bob);
    }

    function test_closeYieldStream_continuesGeneratingFurtherYieldForReceiver()
        public
    {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 bobsYield = streamHub.yieldFor(bob);

        streamHub.closeYieldStream(bob);

        assertApproxEqAbs(
            streamHub.yieldFor(bob),
            bobsYield,
            1,
            "bob's yield changed"
        );
        assertEq(asset.balanceOf(bob), 0, "bob's assets");

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(
            streamHub.yieldFor(bob),
            expectedYield,
            1,
            "bob's yield"
        );
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

        assertEq(
            vault.convertToAssets(shares),
            amount.mulWadUp(0.8e18),
            "shares value"
        );
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

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameStreamer()
        public
    {
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

        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(alice)),
            amount / 2,
            1,
            "alice's principal"
        );
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(streamHub.yieldFor(bob), bobsYield, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(streamHub.yieldFor(carol), carolsYield, "carol's yield");
    }

    function test_closeYieldStream_doesntAffectOtherStreamFromTheAnotherStreamer()
        public
    {
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

        assertEq(
            streamHub.receiverTotalPrincipal(carol),
            alicesDeposit + bobsDeposit,
            "carol's total principal"
        );

        uint256 carolsYield = streamHub.yieldFor(carol);

        vm.prank(alice);
        streamHub.closeYieldStream(carol);

        assertApproxEqAbs(
            streamHub.yieldFor(carol),
            carolsYield,
            1,
            "carol's yield"
        );
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(alice)),
            alicesDeposit,
            2,
            "alice's shares value"
        );
        assertEq(
            streamHub.receiverPrincipal(carol, alice),
            0,
            "alice's principal"
        );
        assertEq(
            streamHub.receiverPrincipal(carol, bob),
            bobsDeposit,
            "bob's principal"
        );
        assertEq(
            streamHub.receiverTotalPrincipal(carol),
            bobsDeposit,
            "carol's total principal"
        );
    }

    function test_closeYieldStreamBatch_closesAllStreams() public {
        uint256 amount = 3e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveStreamHub(alice, shares);

        vm.startPrank(alice);
        streamHub.openYieldStream(bob, shares / 3);
        streamHub.openYieldStream(carol, (shares * 2) / 3);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        streamHub.closeYieldStreamBatch(receivers);

        assertEq(
            vault.balanceOf(alice),
            vault.convertToShares(amount),
            "alice's principal"
        );
        assertEq(streamHub.yieldFor(bob), amount / 3, "bob's yield");
        assertEq(streamHub.yieldFor(carol), (amount * 2) / 3, "carol's yield");
    }

    // *** #multicall ***

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            ERC4626StreamHub.openYieldStream.selector,
            bob,
            (shares * 3) / 4
        );
        data[1] = abi.encodeWithSelector(
            ERC4626StreamHub.openYieldStream.selector,
            carol,
            shares / 4
        );

        vm.startPrank(alice);
        vault.approve(address(streamHub), shares);
        streamHub.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(
            streamHub.receiverShares(bob),
            (shares * 3) / 4,
            "receiver shares bob"
        );
        assertEq(
            streamHub.receiverShares(carol),
            shares / 4,
            "receiver shares carol"
        );
    }

    // *** helpers ***

    function _depositToVault(
        address _from,
        uint256 _amount
    ) internal returns (uint256 shares) {
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
        deal(
            address(asset),
            address(vault),
            vault.totalAssets().mulWadDown(uint256(1e18 + _profit))
        );
    }
}
