// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/interfaces/IERC721Receiver.sol";
import {IERC721} from "openzeppelin-contracts/interfaces/IERC721.sol";
import {IERC721Metadata} from "openzeppelin-contracts/interfaces/IERC721Metadata.sol";
import {IERC165} from "openzeppelin-contracts/interfaces/IERC165.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

import {TestCommon} from "./common/TestCommon.sol";
import {YieldStreams} from "src/YieldStreams.sol";
import "src/common/CommonErrors.sol";

contract YieldStreamsTest is TestCommon {
    using FixedPointMathLib for uint256;

    event StreamOpened(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event StreamToppedUp(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event YieldClaimed(
        address indexed receiver, address indexed claimedTo, uint256 assetsClaimed, uint256 sharesClaimed
    );
    event StreamClosed(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event LossTolerancePercentUpdated(address indexed owner, uint256 oldValue, uint256 newValue);

    YieldStreams public ys;
    MockERC4626 public vault;
    MockERC20 public asset;

    function setUp() public {
        asset = new MockERC20("Mock ERC20", "mERC20", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "Mock ERC4626", "mERC4626");
        ys = new YieldStreams(IERC4626(address(vault)));

        // make initial deposit to the vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    /*
     * --------------------
     *    #constructor
     * --------------------
     */

    function test_constructor() public {
        assertEq(address(ys.vault()), address(vault), "vault");

        assertEq(ys.name(), "Yield Stream - Mock ERC4626", "name");
        assertEq(ys.symbol(), "YS-mERC4626", "symbol");

        // nft ids start from 1
        assertEq(ys.nextStreamId(), 1, "next stream id");
        assertEq(address(ys.asset()), address(asset), "underlying asset");
        assertEq(asset.allowance(address(ys), address(vault)), type(uint256).max, "asset allowance");
    }

    /*
     * --------------------
     *       #open
     * --------------------
     */

    function test_open_failsFor0Shares() public {
        _depositToVaultAndApprove(alice, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(CommonErrors.AmountZero.selector);
        ys.open(alice, bob, 0, 0);
    }

    function test_open_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(CommonErrors.AddressZero.selector);
        ys.open(alice, address(0), shares, 0);
    }

    function test_open_failsIfOwnerIsZeroAddress() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(CommonErrors.AddressZero.selector);
        ys.open(address(0), bob, shares, 0);
    }

    function test_open_mintsNtfAndTransfersShares() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        vm.startPrank(alice);
        uint256 streamId = ys.open(alice, bob, shares, 0);

        assertEq(streamId, 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");
        assertEq(ys.ownerOf(streamId), alice, "owner of token");
        assertEq(ys.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_open_mintsNftToProvidedOwner() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        vm.startPrank(alice);
        uint256 streamId = ys.open(bob, carol, shares, 0);

        assertEq(ys.ownerOf(streamId), bob, "owner of token");
        assertEq(ys.balanceOf(bob), 1, "nft balance of bob");
        assertEq(ys.balanceOf(alice), 0, "nft balance of bob");

        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(carol), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(carol), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(carol, 1), principal, "receiver principal");
    }

    function test_open_emitsEvent() public {
        uint256 principal = 4e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        uint256 streamId = ys.nextStreamId();

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(streamId, alice, bob, shares, principal);

        vm.prank(alice);
        ys.open(alice, bob, shares, 0);
    }

    function test_open_toTwoReceivers() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        vm.startPrank(alice);
        uint256 firstId = ys.open(alice, bob, shares / 2, 0);
        uint256 secondId = ys.open(alice, carol, shares / 4, 0);

        assertEq(firstId, 1, "first id");
        assertEq(secondId, 2, "second id");
        assertEq(ys.nextStreamId(), 3, "next stream id");

        assertEq(vault.balanceOf(alice), shares / 4, "alice's shares");

        assertEq(ys.receiverTotalShares(bob), shares / 2, "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), principal / 2, "principal bob");
        assertEq(ys.receiverPrincipal(bob, 1), principal / 2, "receiver principal  bob");

        assertEq(ys.receiverTotalShares(carol), shares / 4, "receiver shares carol");
        assertEq(ys.receiverTotalPrincipal(carol), principal / 4, "principal carol");
        assertEq(ys.receiverPrincipal(carol, 2), principal / 4, "receiver principal  carol");
    }

    function test_open_failsIfReceiverIsInDebtAndImmediateLossIsAboveLossTolerancePercent() public {
        uint256 alicesPrincipal = 1e18;
        uint256 alicesShares = _depositToVaultAndApprove(alice, alicesPrincipal);

        // alice opens a stream to carol
        vm.prank(alice);
        ys.open(alice, carol, alicesShares, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(ys.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVaultAndApprove(bob, bobsPrincipal);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.033e18; // 3.3%
        vm.prank(bob);
        vm.expectRevert(YieldStreams.LossToleranceExceeded.selector);
        ys.open(bob, carol, bobsShares, toleratedLossOnOpenPct);
    }

    function test_open_worksIfReceiverIsInDebtAndLossIsBelowLossTolerancePercent() public {
        uint256 alicesPrincipal = 1e18;
        uint256 alicesShares = _depositToVaultAndApprove(alice, alicesPrincipal);

        // alice opens a stream to carol
        vm.prank(alice);
        ys.open(alice, carol, alicesShares, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(ys.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVaultAndApprove(bob, bobsPrincipal);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.034e18; // 3.4%
        vm.prank(bob);
        uint256 streamId = ys.open(bob, carol, bobsShares, toleratedLossOnOpenPct);

        uint256 principalWithLoss = vault.convertToAssets(ys.previewClose(2));
        uint256 bobsLossOnOpen = bobsPrincipal - principalWithLoss;

        assertTrue(principalWithLoss < bobsPrincipal, "principal with loss > bobs deposit");
        assertApproxEqRel(principalWithLoss, bobsPrincipal, toleratedLossOnOpenPct, "principal with loss");
        assertTrue(bobsLossOnOpen < bobsPrincipal.mulWadDown(toleratedLossOnOpenPct), "loss tolerance exceeded");

        vm.prank(bob);
        ys.close(streamId);

        uint256 bobsPrincipalAfterClose = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobsPrincipalAfterClose, bobsPrincipal - bobsLossOnOpen, 1, "bobs principal after close");
    }

    /*
     * --------------------
     *   #openUsingPermit
     * --------------------
     */

    function test_openUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(dave, principal);
        uint256 deadline = block.timestamp + 1 days;

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(vault), address(ys), shares, deadline);

        vm.prank(dave);
        uint256 streamId = ys.openUsingPermit(dave, bob, shares, 0, deadline, v, r, s);

        assertEq(streamId, 1, "stream id");
        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_openUsingPermit_mintsNftToProvidedOwner() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(dave, principal);
        uint256 deadline = block.timestamp + 1 days;

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(vault), address(ys), shares, deadline);

        vm.prank(dave);
        uint256 streamId = ys.openUsingPermit(bob, carol, shares, 0, deadline, v, r, s);

        assertEq(ys.ownerOf(streamId), bob, "owner of token");
        assertEq(ys.balanceOf(bob), 1, "nft balance of bob");
        assertEq(ys.balanceOf(dave), 0, "nft balance of dave");

        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(carol), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(carol), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(carol, 1), principal, "receiver principal");
    }

    /*
     * --------------------
     *    #openMultiple
     * --------------------
     */

    function test_openMultiple_failsIfSharesIs0() public {
        _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 0;

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        ys.openMultiple(alice, 0, receivers, allocations, 0);
    }

    function test_openMultiple_failsIfOwnerIsZeroAddress() public {
        _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        ys.openMultiple(address(0), 1e18, receivers, allocations, 0);
    }

    function test_openMultiple_failsIfArrayLengthsDontMatch() public {
        _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 0.5e18;

        vm.expectRevert(abi.encodeWithSelector(YieldStreams.InputArraysLengthMismatch.selector, 2, 1));
        vm.prank(alice);
        ys.openMultiple(alice, 1 ether, receivers, allocations, 0);
    }

    function test_openMultiple_failsIfArrayLengthIsZero() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](0);
        uint256[] memory allocations = new uint256[](0);

        vm.expectRevert(YieldStreams.InputArrayEmpty.selector);
        vm.prank(alice);
        uint256[] memory streamIds = ys.openMultiple(alice, 1 ether, receivers, allocations, 0);

        assertEq(streamIds.length, 0, "stream ids length");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
    }

    function test_openMultiple_failsIfReceiverIsZeroAddress() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = address(0);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.1e18;
        allocations[1] = 0.9e18;

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        ys.openMultiple(alice, shares, receivers, allocations, 0);
    }

    function test_openMultiple_failsIfAllocationIs0() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.1e18;
        allocations[1] = 0;

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        ys.openMultiple(alice, shares, receivers, allocations, 0);
    }

    function test_openMultiple_worksOpeningSingleStream() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.prank(alice);
        uint256[] memory streamIds = ys.openMultiple(alice, shares, receivers, allocations, 0);

        assertEq(streamIds.length, 1, "stream ids length");
        assertEq(streamIds[0], 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");

        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token");
        assertEq(ys.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_openMultiple_transfersOnlySharesAllocatedToStreams() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.prank(alice);
        ys.openMultiple(alice, shares, receivers, allocations, 0);

        assertEq(vault.balanceOf(alice), shares.mulWadDown(0.2e18), "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares.mulWadDown(0.8e18), "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares.mulWadDown(allocations[0]), "receiver shares bob");
        assertEq(ys.receiverTotalShares(carol), shares.mulWadDown(allocations[1]), "receiver shares carol");
    }

    function test_openMultiple_mintsNftsWithCorrectOwner() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.prank(alice);
        ys.openMultiple(bob, shares, receivers, allocations, 0);

        assertEq(ys.ownerOf(1), bob, "owner of token 1");
        assertEq(ys.ownerOf(2), bob, "owner of token 2");
    }

    function test_openMultiple_emitsEventForEachStream() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(1, alice, bob, shares.mulWadDown(0.3e18), 0.3e18);
        emit StreamOpened(2, alice, carol, shares.mulWadDown(0.5e18), 0.5e18);

        vm.prank(alice);
        ys.openMultiple(alice, shares, receivers, allocations, 0);
    }

    function test_openMultiple_createsMultipleStreamsWithCorrectReceiversAndAllocations() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        // open 3 streams
        address[] memory receivers = new address[](3);
        receivers[0] = bob;
        receivers[1] = carol;
        receivers[2] = alice;

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 0.5e18;
        allocations[1] = 0.25e18;
        allocations[2] = 0.15e18;

        vm.startPrank(alice);
        uint256[] memory streamIds = ys.openMultiple(alice, shares, receivers, allocations, 0);

        assertEq(ys.nextStreamId(), 4, "next stream id");
        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token 0");
        assertEq(ys.ownerOf(streamIds[1]), alice, "owner of token 1");
        assertEq(ys.ownerOf(streamIds[2]), alice, "owner of token 2");
        assertEq(ys.balanceOf(alice), 3, "nft balance of alice");

        assertEq(vault.balanceOf(alice), shares.mulWadDown(0.1e18), "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares.mulWadDown(0.9e18), "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares.mulWadDown(0.5e18), "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), principal.mulWadDown(0.5e18), "principal bob");
        assertEq(ys.receiverPrincipal(bob, streamIds[0]), principal.mulWadDown(0.5e18), "receiver principal  bob");

        assertEq(ys.receiverTotalShares(carol), shares.mulWadDown(0.25e18), "receiver shares carol");
        assertEq(ys.receiverTotalPrincipal(carol), principal.mulWadDown(0.25e18), "principal carol");
        assertEq(ys.receiverPrincipal(carol, streamIds[1]), principal.mulWadDown(0.25e18), "receiver principal  carol");

        assertEq(ys.receiverTotalShares(alice), shares.mulWadDown(allocations[2]), "receiver shares alice");
        assertEq(ys.receiverTotalPrincipal(alice), principal.mulWadDown(allocations[2]), "principal alice");
        assertEq(
            ys.receiverPrincipal(alice, streamIds[2]), principal.mulWadDown(allocations[2]), "receiver principal  alice"
        );
    }

    function test_openMultiple_failsIfImmediateLossIsAboveLossTolerance() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // create 10% loss
        _generateYield(-0.1e18);

        uint256 shares = _depositToVaultAndApprove(carol, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        // debt for bob = 0.1e18
        // alice's principal = 1e18
        // carol's principal = 1e18
        // carol's share of loss = 0.1e18 * 1e18 / (1e18 + 1e18) = 0.05e18
        // carol's loss in pct = 1 - 0.95e18 / 1e18 = 0.05 = 5%

        uint256 toleratedLossOnOpenPct = 0.0499e18; // 4.99%
        vm.prank(carol);
        vm.expectRevert(YieldStreams.LossToleranceExceeded.selector);
        ys.openMultiple(alice, shares, receivers, allocations, toleratedLossOnOpenPct);
    }

    function test_openMultiple_worksIfImmediateLossIsBelowLossTolerance() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // create 10% loss
        _generateYield(-0.1e18);

        uint256 shares = _depositToVaultAndApprove(carol, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        // debt for bob = 0.1e18
        // alice's principal = 1e18
        // carol's principal = 1e18
        // carol's share of loss = 0.1e18 * 1e18 / (1e18 + 1e18) = 0.05e18
        // carol's loss in pct = 1 - 0.95e18 / 1e18 = 0.05 = 5%

        uint256 toleratedLossOnOpenPct = 0.0501e18; // 5.01%
        vm.prank(carol);
        ys.openMultiple(alice, shares, receivers, allocations, toleratedLossOnOpenPct);

        assertApproxEqAbs(ys.receiverTotalPrincipal(bob), 2 * principal, 1, "principal bob");
    }

    function test_openMultiple_failsIfTotalAllocationExceeds100Percent() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.5e18;
        allocations[1] = 0.6e18;

        // should fail on underflow in erc20
        vm.expectRevert();
        vm.prank(alice);
        ys.openMultiple(alice, shares, receivers, allocations, 0);
    }

    /*
     * --------------------
     *  #openMultipleUsingPermit
     * --------------------
     */

    function test_openMultipleUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(dave, principal);
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(vault), address(ys), shares, deadline);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.prank(dave);
        uint256[] memory streamIds =
            ys.openMultipleUsingPermit(dave, shares, receivers, allocations, 0, deadline, v, r, s);

        assertEq(streamIds.length, 1, "stream ids length");
        assertEq(streamIds[0], 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");

        assertEq(ys.ownerOf(streamIds[0]), dave, "owner of token");
        assertEq(ys.balanceOf(dave), 1, "nft balance of dave");

        assertEq(vault.balanceOf(dave), 0, "dave's shares");
        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_openMultipleUsingPermit_mintsNtfsWithCorrectOwner() public {
        uint256 shares = _depositToVault(dave, 1 ether);
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(vault), address(ys), shares, deadline);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.prank(dave);
        uint256[] memory streamIds =
            ys.openMultipleUsingPermit(alice, shares, receivers, allocations, 0, deadline, v, r, s);

        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token 0");
        assertEq(ys.ownerOf(streamIds[1]), alice, "owner of token 1");
    }

    /*
     * --------------------
     *   #depositAndOpen
     * --------------------
     */

    function test_depositAndOpen_failsFor0Assets() public {
        _approveAssetsAndPreviewDeposit(alice, 1e18);

        // fails to deposit 0 amount to the vault
        vm.expectRevert("ZERO_SHARES");
        vm.prank(alice);
        ys.depositAndOpen(alice, bob, 0, 0);
    }

    function test_depositAndOpen_failsIfReceiverIsZeroAddress() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        ys.depositAndOpen(alice, address(0), principal, 0);
    }

    function test_depositAndOpen_failsIfOwnerIsZeroAddress() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        ys.depositAndOpen(address(0), bob, principal, 0);
    }

    function test_depositAndOpen_mintsNtfAndTransfersShares() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        uint256 shares = ys.previewDepositAndOpen(bob, principal, 0);
        assertEq(shares, vault.convertToShares(principal), "preview open with assets");

        vm.prank(alice);
        uint256 streamId = ys.depositAndOpen(alice, bob, principal, 0);

        assertEq(streamId, 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");
        assertEq(ys.ownerOf(streamId), alice, "owner of token");
        assertEq(ys.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_depositAndOpen_mintsNftToProvidedOwner() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        uint256 shares = ys.previewDepositAndOpen(carol, principal, 0);
        assertEq(shares, vault.convertToShares(principal), "preview open with assets");

        vm.prank(alice);
        uint256 streamId = ys.depositAndOpen(bob, carol, principal, 0);

        assertEq(ys.ownerOf(streamId), bob, "owner of token");
        assertEq(ys.balanceOf(bob), 1, "nft balance of bob");
        assertEq(ys.balanceOf(alice), 0, "nft balance of bob");

        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");
        assertEq(ys.receiverTotalShares(carol), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(carol), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(carol, 1), principal, "receiver principal");
    }

    function test_depositAndOpen_emitsEvent() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);
        uint256 streamId = ys.nextStreamId();

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(streamId, alice, bob, shares, principal);

        vm.prank(alice);
        ys.depositAndOpen(alice, bob, principal, 0);
    }

    function test_depositAndOpen_toTwoReceivers() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        vm.startPrank(alice);
        uint256 firstId = ys.depositAndOpen(alice, bob, principal / 2, 0);
        uint256 secondId = ys.depositAndOpen(alice, carol, principal / 4, 0);

        assertEq(firstId, 1, "first id");
        assertEq(secondId, 2, "second id");
        assertEq(ys.nextStreamId(), 3, "next stream id");

        assertEq(asset.balanceOf(alice), principal / 4, "alice's assets");

        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(principal / 2), "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), principal / 2, "principal bob");
        assertEq(ys.receiverPrincipal(bob, 1), principal / 2, "receiver principal  bob");

        assertEq(ys.receiverTotalShares(carol), vault.convertToShares(principal / 4), "receiver shares carol");
        assertEq(ys.receiverTotalPrincipal(carol), principal / 4, "principal carol");
        assertEq(ys.receiverPrincipal(carol, 2), principal / 4, "receiver principal  carol");
    }

    function test_depositAndOpen_failsIfReceiverIsInDebtAndImmediateLossIsAboveLossTolerancePercent() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        // alice opens a stream to carol
        vm.prank(alice);
        ys.depositAndOpen(alice, carol, principal, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(ys.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsPrincipal);
        _approveYieldStreamsContract(bob, bobsShares);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.033e18; // 3.3%
        vm.prank(bob);
        vm.expectRevert(YieldStreams.LossToleranceExceeded.selector);
        ys.open(bob, carol, bobsShares, toleratedLossOnOpenPct);
    }

    function test_depositAndOpen_worksIfReceiverIsInDebtAndLossIsBelowLossTolerancePercent() public {
        _openYieldStream(alice, carol, 1e18);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(ys.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(bob, bobsPrincipal);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.034e18; // 3.4%
        vm.prank(bob);
        uint256 streamId = ys.depositAndOpen(bob, carol, bobsPrincipal, toleratedLossOnOpenPct);

        uint256 principalWithLoss = vault.convertToAssets(ys.previewClose(2));
        uint256 bobsLossOnOpen = bobsPrincipal - principalWithLoss;

        assertTrue(principalWithLoss < bobsPrincipal, "principal with loss > bobs deposit");
        assertApproxEqRel(principalWithLoss, bobsPrincipal, toleratedLossOnOpenPct, "principal with loss");
        assertTrue(bobsLossOnOpen < bobsPrincipal.mulWadDown(toleratedLossOnOpenPct), "loss tolerance exceeded");

        vm.prank(bob);
        ys.close(streamId);

        uint256 bobsPrincipalAfterClose = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobsPrincipalAfterClose, bobsPrincipal - bobsLossOnOpen, 1, "bobs principal after close");
    }

    /*
     * --------------------
     *  #depositAndOpenUsingPermit
     * --------------------
     */

    function test_depositAndOpenUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, principal);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(asset), address(ys), principal, deadline);

        vm.prank(dave);
        uint256 streamId = ys.depositAndOpenUsingPermit(dave, bob, principal, 0, deadline, v, r, s);

        assertEq(streamId, 1, "stream id");
        assertEq(vault.balanceOf(address(ys)), vault.convertToShares(principal), "contract's shares");
        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(principal), "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_depositAndOpenUsingPermit_mintsNftToProvidedOwner() public {
        uint256 principal = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, principal);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(asset), address(ys), principal, deadline);

        vm.prank(dave);
        uint256 streamId = ys.depositAndOpenUsingPermit(bob, carol, principal, 0, deadline, v, r, s);

        assertEq(ys.ownerOf(streamId), bob, "owner of token");
        assertEq(ys.balanceOf(bob), 1, "nft balance of bob");
        assertEq(ys.balanceOf(dave), 0, "nft balance of dave");

        assertEq(vault.balanceOf(address(ys)), vault.convertToShares(principal), "contract's shares");
        assertEq(ys.receiverTotalShares(carol), vault.convertToShares(principal), "receiver shares");
        assertEq(ys.receiverTotalPrincipal(carol), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(carol, 1), principal, "receiver principal");
    }

    /*
     * --------------------
     *  #depositAndOpenMultiple
     * --------------------
     */

    function test_depositAndOpenMultiple_failsIfAmountIs0() public {
        _approveAssetsAndPreviewDeposit(alice, 1e18);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, 0, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_failsIfArrayLengthsDontMatch() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 0.5e18;

        vm.expectRevert(abi.encodeWithSelector(YieldStreams.InputArraysLengthMismatch.selector, 2, 1));
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_failsIfArrayLengthIsZero() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](0);
        uint256[] memory allocations = new uint256[](0);

        vm.expectRevert(YieldStreams.InputArrayEmpty.selector);
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_failsIfReceiverIs0() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = address(0);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.1e18;
        allocations[1] = 0.9e18;

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_failsIfAllocationIs0() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.1e18;
        allocations[1] = 0;

        vm.expectRevert(CommonErrors.AmountZero.selector);
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_worksOpeningSingleStream() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.prank(alice);
        uint256[] memory streamIds = ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);

        assertEq(streamIds.length, 1, "stream ids length");
        assertEq(streamIds[0], 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");

        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token");
        assertEq(ys.balanceOf(alice), 1, "nft balance of alice");

        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares, "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_depositAndOpenMultiple_transfersUnallocatedSharesBackToCaller() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);

        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(vault.balanceOf(alice), shares.mulWadDown(0.2e18), "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares.mulWadDown(0.8e18), "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares.mulWadDown(allocations[0]), "receiver shares bob");
        assertEq(ys.receiverTotalShares(carol), shares.mulWadDown(allocations[1]), "receiver shares carol");
    }

    function test_depositAndOpenMultiple_emitsEventForEachStream() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.expectEmit(true, true, true, true);
        emit StreamOpened(1, alice, bob, shares.mulWadDown(0.3e18), 0.3e18);
        emit StreamOpened(2, alice, carol, shares.mulWadDown(0.5e18), 0.5e18);

        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    function test_depositAndOpenMultiple_createsMultipleStreamsWithCorrectReceiversAndAllocations() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);

        // open 3 streams
        address[] memory receivers = new address[](3);
        receivers[0] = bob;
        receivers[1] = carol;
        receivers[2] = alice;

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 0.5e18;
        allocations[1] = 0.25e18;
        allocations[2] = 0.15e18;

        vm.prank(alice);
        uint256[] memory streamIds = ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);

        assertEq(ys.nextStreamId(), 4, "next stream id");
        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token 0");
        assertEq(ys.ownerOf(streamIds[1]), alice, "owner of token 1");
        assertEq(ys.ownerOf(streamIds[2]), alice, "owner of token 2");
        assertEq(ys.balanceOf(alice), 3, "nft balance of alice");

        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(vault.balanceOf(alice), shares.mulWadDown(0.1e18), "alice's shares");
        assertEq(vault.balanceOf(address(ys)), shares.mulWadDown(0.9e18), "contract's shares");

        assertEq(ys.receiverTotalShares(bob), shares.mulWadDown(0.5e18), "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), principal.mulWadDown(0.5e18), "principal bob");
        assertEq(ys.receiverPrincipal(bob, streamIds[0]), principal.mulWadDown(0.5e18), "receiver principal  bob");

        assertEq(ys.receiverTotalShares(carol), shares.mulWadDown(0.25e18), "receiver shares carol");
        assertEq(ys.receiverTotalPrincipal(carol), principal.mulWadDown(0.25e18), "principal carol");
        assertEq(
            ys.receiverPrincipal(carol, streamIds[1]), principal.mulDivDown(0.25e18, 1e18), "receiver principal  carol"
        );

        assertEq(ys.receiverTotalShares(alice), shares.mulWadDown(allocations[2]), "receiver shares alice");
        assertEq(ys.receiverTotalPrincipal(alice), principal.mulWadDown(allocations[2]), "principal alice");
        assertEq(
            ys.receiverPrincipal(alice, streamIds[2]), principal.mulWadDown(allocations[2]), "receiver principal  alice"
        );
    }

    function test_depositAndOpenMultiple_failsIfImmediateLossIsAboveLossTolerance() public {
        _openYieldStream(alice, bob, 1e18);

        // create 10% loss
        _generateYield(-0.1e18);

        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(carol, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        // debt for bob = 0.1e18
        // alice's principal = 1e18
        // carol's principal = 1e18
        // carol's share of loss = 0.1e18 * 1e18 / (1e18 + 1e18) = 0.05e18
        // carol's loss in pct = 1 - 0.95e18 / 1e18 = 0.05 = 5%

        uint256 toleratedLossOnOpenPct = 0.0499e18; // 4.99%
        vm.prank(carol);
        vm.expectRevert(YieldStreams.LossToleranceExceeded.selector);
        ys.depositAndOpenMultiple(carol, principal, receivers, allocations, toleratedLossOnOpenPct);
    }

    function test_depositAndOpenMultiple_worksIfImmediateLossIsBelowLossTolerance() public {
        _openYieldStream(alice, bob, 1e18);

        // create 10% loss
        _generateYield(-0.1e18);

        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(carol, principal);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        // debt for bob = 0.1e18
        // alice's principal = 1e18
        // carol's principal = 1e18
        // carol's share of loss = 0.1e18 * 1e18 / (1e18 + 1e18) = 0.05e18
        // carol's loss in pct = 1 - 0.95e18 / 1e18 = 0.05 = 5%

        uint256 toleratedLossOnOpenPct = 0.0501e18; // 5.01%
        vm.prank(carol);
        ys.depositAndOpenMultiple(carol, principal, receivers, allocations, toleratedLossOnOpenPct);

        assertApproxEqAbs(ys.receiverTotalPrincipal(bob), 2 * principal, 1, "principal bob");
    }

    function test_depositAndOpenMupltiple_failsIfTotalAllocationExceeds100Percent() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.5e18;
        allocations[1] = 0.6e18;

        // should fail on underflow
        vm.expectRevert();
        vm.prank(alice);
        ys.depositAndOpenMultiple(alice, principal, receivers, allocations, 0);
    }

    /*
     * --------------------
     *  #depositAndOpenMultipleUsingPermit
     * --------------------
     */

    function test_depositAndOpenMultipleUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, principal);

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(asset), address(ys), principal, deadline);

        address[] memory receivers = new address[](1);
        receivers[0] = bob;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1e18;

        vm.prank(dave);
        uint256[] memory streamIds =
            ys.depositAndOpenMultipleUsingPermit(dave, principal, receivers, allocations, 0, deadline, v, r, s);

        assertEq(streamIds.length, 1, "stream ids length");
        assertEq(streamIds[0], 1, "stream id");
        assertEq(ys.nextStreamId(), 2, "next stream id");

        assertEq(ys.ownerOf(streamIds[0]), dave, "owner of token");
        assertEq(ys.balanceOf(dave), 1, "nft balance of dave");

        assertEq(asset.balanceOf(dave), 0, "dave's assets");
        assertEq(vault.balanceOf(address(ys)), vault.convertToShares(principal), "contract's shares");
        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(principal), "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(ys.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_depositAndOpenMultipleUsingPermit_mintsNftToProvidedOwner() public {
        uint256 principal = 1 ether;
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, principal);

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(davesPrivateKey, address(asset), address(ys), principal, deadline);

        address[] memory receivers = new address[](2);
        receivers[0] = bob;
        receivers[1] = carol;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0.3e18;
        allocations[1] = 0.5e18;

        vm.prank(dave);
        uint256[] memory streamIds =
            ys.depositAndOpenMultipleUsingPermit(alice, principal, receivers, allocations, 0, deadline, v, r, s);

        assertEq(ys.ownerOf(streamIds[0]), alice, "owner of token 0");
        assertEq(ys.ownerOf(streamIds[1]), alice, "owner of token 1");
    }

    /*
     * --------------------
     *       #topUp
     * --------------------
     */

    function test_topUp_failsIfAmountIs0() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        _depositToVaultAndApprove(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(CommonErrors.AmountZero.selector);
        ys.topUp(streamId, 0);
    }

    function test_topUp_failsIfStreamDoesntExist() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);
        uint256 invalidTokenId = streamId + 1;

        vm.prank(alice);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        ys.topUp(invalidTokenId, shares);
    }

    function test_topUp_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        vm.prank(carol);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        ys.topUp(streamId, shares);
    }

    function test_topUp_addsToExistingStream() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _depositToVaultAndApprove(alice, addedPrincipal);

        vm.startPrank(alice);

        // top up stream
        ys.topUp(streamId, addedShares);

        uint256 expectedPrincipal = principal + addedPrincipal;
        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(expectedPrincipal), "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), expectedPrincipal, "principal bob");
        assertEq(ys.receiverPrincipal(bob, streamId), expectedPrincipal, "receiver principal  bob");
    }

    function test_topUp_emitsEvent() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _depositToVaultAndApprove(alice, addedPrincipal);

        vm.expectEmit(true, true, true, true);
        emit StreamToppedUp(streamId, alice, bob, addedShares, addedPrincipal);

        vm.prank(alice);
        ys.topUp(streamId, addedShares);
    }

    function test_topUp_doesntAffectYieldAccrued() public {
        uint256 streamId = _openYieldStream(alice, bob, 2e18);

        _generateYield(0.2e18);
        uint256 yield = ys.previewClaimYield(bob);

        // all the yield has been accrued
        assertEq(ys.previewClaimYield(bob), yield, "yield before top up");

        // top up stream
        uint256 addedShares = _depositToVaultAndApprove(alice, 1e18);

        vm.prank(alice);
        ys.topUp(streamId, addedShares);

        // yield should remain the same
        assertApproxEqAbs(ys.previewClaimYield(bob), yield, 1, "yield after top up");
    }

    function test_topUp_affectsFutureYield() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // double the share price
        _generateYield(1e18);

        assertEq(ys.previewClaimYield(bob), principal, "yield before top up");

        // top up
        uint256 addedShares = _depositToVaultAndApprove(alice, 2e18);

        vm.prank(alice);
        ys.topUp(streamId, addedShares);

        _generateYield(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        // 1e18 * 2 + 2e18 * 0.5 = 3e18
        assertEq(ys.previewClaimYield(bob), 3e18, "yield after top up");
    }

    function test_topUp_worksWhenReceiverIsInDebt() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        _generateYield(-0.5e18);

        uint256 receiverDebt = ys.debtFor(bob);

        assertEq(receiverDebt, principal / 2, "receiver debt before top up");

        // top up stream
        uint256 addedShares = _depositToVaultAndApprove(alice, principal);
        vm.prank(alice);
        ys.topUp(streamId, addedShares);

        assertEq(ys.debtFor(bob), receiverDebt, "receiver debt");
        assertEq(ys.receiverTotalShares(bob), shares + addedShares, "receiver shares");
        assertEq(ys.receiverPrincipal(bob, streamId), principal * 2, "receiver principal");
        assertEq(ys.receiverTotalPrincipal(bob), principal * 2, "receiver total principal");
    }

    function test_topUpUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 streamId = _openYieldStream(dave, bob, principal);

        // top up
        uint256 addedPrincipal = 2 ether;
        uint256 addedShares = _depositToVault(dave, addedPrincipal);

        uint256 nonce = vault.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC4626(address(vault)).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(ys), addedShares, nonce, deadline))
                )
            )
        );

        // top up stream
        vm.prank(dave);
        ys.topUpUsingPermit(streamId, addedShares, deadline, v, r, s);

        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(principal) + addedShares, "receiver shares");
        assertEq(ys.receiverPrincipal(bob, streamId), principal + addedPrincipal, "receiver principal");
        assertEq(ys.receiverTotalPrincipal(bob), principal + addedPrincipal, "receiver total principal");
    }

    /*
     * --------------------
     *   #depositAndTopUp
     * --------------------
     */

    function test_depositAndTopUp_failsIfAmountIs0() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        _approveAssetsAndPreviewDeposit(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(CommonErrors.AmountZero.selector);
        ys.depositAndTopUp(streamId, 0);
    }

    function test_depositAndTopUp_failsIfStreamDoesntExist() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        uint256 invalidTokenId = streamId + 1;

        vm.prank(alice);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        ys.depositAndTopUp(invalidTokenId, addedPrincipal);
    }

    function test_depositAndTopUp_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 1e18;
        _approveAssetsAndPreviewDeposit(carol, addedPrincipal);

        vm.prank(carol);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        ys.topUp(streamId, addedPrincipal);
    }

    function test_depositAndTopUp_addsToExistingStream() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, principal);

        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        ys.depositAndTopUp(streamId, addedPrincipal);

        uint256 expectedTotalPrincipal = principal + addedPrincipal;
        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(expectedTotalPrincipal), "receiver shares bob");
        assertEq(ys.receiverTotalPrincipal(bob), expectedTotalPrincipal, "principal bob");
        assertEq(ys.receiverPrincipal(bob, streamId), expectedTotalPrincipal, "receiver principal  bob");
    }

    function test_depositAndTopUp_emitsEvent() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.expectEmit(true, true, true, true);
        emit StreamToppedUp(streamId, alice, bob, addedShares, addedPrincipal);

        vm.prank(alice);
        ys.depositAndTopUp(streamId, addedPrincipal);
    }

    function test_depositAndTopUp_doesntAffectYieldAccrued() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        _generateYield(0.2e18);
        uint256 yield = ys.previewClaimYield(bob);

        // assert the yield is not 0
        assertEq(yield, principal.mulWadDown(0.2e18), "yield before top up");

        // top up stream
        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        ys.depositAndTopUp(streamId, addedPrincipal);

        // yield should remain the same
        assertApproxEqAbs(ys.previewClaimYield(bob), yield, 1, "yield after top up");
    }

    function test_depositAndTopUp_affectsFutureYield() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // double the share price
        _generateYield(1e18);

        assertEq(ys.previewClaimYield(bob), principal, "yield before top up");

        // top up
        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        ys.depositAndTopUp(streamId, addedPrincipal);

        _generateYield(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        // 1e18 * 2 + 2e18 * 0.5 = 3e18
        assertEq(ys.previewClaimYield(bob), 3e18, "yield after top up");
    }

    function test_depositAndTopUp_worksWhenReceiverIsInDebt() public {
        uint256 principal = 1e18;
        uint256 shares = vault.convertToShares(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        _generateYield(-0.5e18);

        uint256 receiverDebt = ys.debtFor(bob);

        assertEq(receiverDebt, principal / 2, "receiver debt before top up");

        // top up
        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        ys.depositAndTopUp(streamId, addedPrincipal);

        assertEq(ys.debtFor(bob), receiverDebt, "receiver debt after top up");
        assertEq(ys.receiverTotalShares(bob), shares + addedShares, "receiver shares");
        assertEq(ys.receiverPrincipal(bob, streamId), principal + addedPrincipal, "receiver principal");
        assertEq(ys.receiverTotalPrincipal(bob), principal + addedPrincipal, "receiver total principal");
    }

    function test_depositAndTopUpUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 streamId = _openYieldStream(dave, bob, principal);

        // top up
        uint256 addedPrincipal = 2 ether;
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, addedPrincipal);

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(asset), address(ys), addedPrincipal, deadline);

        // top up stream
        vm.prank(dave);
        ys.depositAndTopUpUsingPermit(streamId, addedPrincipal, deadline, v, r, s);

        uint256 expectedTotalPrincipal = principal + addedPrincipal;
        assertEq(ys.receiverTotalShares(bob), vault.convertToShares(expectedTotalPrincipal), "receiver shares");
        assertEq(ys.receiverPrincipal(bob, streamId), expectedTotalPrincipal, "receiver principal");
        assertEq(ys.receiverTotalPrincipal(bob), expectedTotalPrincipal, "receiver total principal");
    }

    /*
     * --------------------
     *  #previewClaimYield
     * --------------------
     */

    function test_previewClaimYield_returns0IfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        // no share price increase => no yield
        assertEq(ys.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returns0IfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        uint256 totalAssets = vault.totalAssets();

        // create a 20% loss
        _generateYield(-0.2e18);

        assertApproxEqAbs(vault.totalAssets(), totalAssets.mulWadDown(0.8e18), 1, "vault no losses");

        // no share price increase => no yield
        assertEq(ys.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returnsGeneratedYield() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(ys.previewClaimYield(bob), principal / 2, "bob's yield");
    }

    function test_previewClaimYield_returnsGeneratedYieldAfterStreamIsClosed() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yieldFor = ys.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.prank(alice);
        ys.close(1);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(vault.balanceOf(alice), vault.convertToShares(principal), "alice's shares");
    }

    function test_previewClaimYield_returns0AfterClaimAndCloseStream() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yieldFor = ys.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.stopPrank();

        vm.prank(bob);
        ys.claimYield(bob);

        assertEq(ys.previewClaimYield(bob), 0, "bob's yield");
        assertApproxEqAbs(asset.balanceOf(bob), principal / 2, 1, "bob's assets");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");

        vm.prank(alice);
        ys.close(1);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(ys.previewClaimYield(bob), 0, "bob's yield");
    }

    /*
     * --------------------
     *    #claimYield
     * --------------------
     */

    function test_claimYield_toSelf() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.prank(bob);
        ys.claimYield(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(bob), principal / 2, 1, "bob's assets");
    }

    function test_claimYield_toAnotherAccount() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 previewClaim = ys.previewClaimYield(bob);

        vm.prank(bob);
        uint256 claimed = ys.claimYield(carol);

        assertApproxEqAbs(claimed, previewClaim, 1, "claimed");

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertApproxEqAbs(asset.balanceOf(carol), claimed, 1, "carol's assets");
    }

    function test_claimYield_emitsEvent() public {
        _openYieldStream(alice, bob, 3e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = ys.previewClaimYield(bob);

        vm.expectEmit(true, true, true, true);
        emit YieldClaimed(bob, carol, yield, 0);

        vm.prank(bob);
        ys.claimYield(carol);
    }

    function test_claimYield_revertsToAddressIs0() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(bob);
        ys.claimYield(address(0));
    }

    function test_claimYield_revertsIfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(ys.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreams.NoYieldToClaim.selector);
        vm.prank(bob);
        ys.claimYield(bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.expectRevert(YieldStreams.NoYieldToClaim.selector);
        vm.prank(bob);
        ys.claimYield(bob);
    }

    function test_claimYield_claimsFromAllOpenedStreams() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 100% profit to vault
        _generateYield(1e18);

        assertEq(ys.previewClaimYield(carol), alicesPrincipal + bobsPrincipal, "carol's yield");

        vm.prank(carol);
        uint256 claimed = ys.claimYield(carol);

        assertEq(claimed, alicesPrincipal + bobsPrincipal, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYield_worksIfOneOfStreamsIsClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 100% profit to vault
        _generateYield(1e18);

        assertEq(ys.previewClaimYield(carol), alicesPrincipal + bobsPrincipal, "carol's expected yield");

        vm.prank(bob);
        ys.close(2);

        vm.prank(carol);
        uint256 claimed = ys.claimYield(carol);

        assertEq(claimed, alicesPrincipal + bobsPrincipal, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(vault.balanceOf(carol), 0, "carol's shares");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYield_worksIfAllStreamsAreClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(ys.previewClaimYield(carol), (alicesPrincipal + bobsPrincipal) / 2, "carol's expected yield");

        vm.prank(bob);
        ys.close(2);
        vm.prank(alice);
        ys.close(1);

        vm.prank(carol);
        uint256 claimed = ys.claimYield(carol);

        assertApproxEqAbs(claimed, (alicesPrincipal + bobsPrincipal) / 2, 1, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(vault.balanceOf(carol), 0, "carol's shares");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
    }

    /*
     * --------------------
     *  #claimYieldInShares
     * --------------------
     */

    function test_claimYieldInShares_toSelf() public {
        uint256 principal = 2e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares(principal / 2);

        vm.prank(bob);
        uint256 claimed = ys.claimYieldInShares(bob);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "bob's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(bob), claimed, "claimed yield in shares");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");
    }

    function test_claimYieldInShares_toAnotherAccount() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares(principal / 2);

        vm.prank(bob);
        uint256 claimed = ys.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed yield in shares");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(vault.balanceOf(bob), 0, "bob's shares");
        assertApproxEqAbs(vault.balanceOf(carol), claimed, 1, "carol's shares");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
    }

    function test_claimYieldInShares_emitsEvent() public {
        uint256 principal = 3e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = ys.previewClaimYieldInShares(bob);

        vm.expectEmit(true, true, true, true);
        emit YieldClaimed(bob, carol, 0, expectedYieldInShares);

        vm.prank(bob);
        ys.claimYieldInShares(carol);
    }

    function test_claimYieldInShares_revertsToAddressIs0() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.expectRevert(CommonErrors.AddressZero.selector);
        vm.prank(bob);
        ys.claimYieldInShares(address(0));
    }

    function test_claimYieldInShares_revertsIfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(ys.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreams.NoYieldToClaim.selector);
        vm.prank(bob);
        ys.claimYieldInShares(bob);
    }

    function test_claimYieldInShares_revertsIfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.expectRevert(YieldStreams.NoYieldToClaim.selector);
        vm.prank(bob);
        ys.claimYield(bob);
    }

    function test_claimYieldInShares_claimsFromAllOpenedStreams() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);
        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYield = alicesPrincipal / 2 + bobsPrincipal / 2;
        uint256 expectedYieldInShares = vault.convertToShares(expectedYield);

        assertApproxEqAbs(ys.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's yield");

        vm.prank(carol);
        uint256 claimed = ys.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
    }

    function test_claimYieldInShares_worksIfOneOfStreamsIsClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);
        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 100% profit to vault
        _generateYield(1e18);

        uint256 expectedYieldInShares = vault.convertToShares(alicesPrincipal + bobsPrincipal);
        assertApproxEqAbs(ys.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's expected yield");

        vm.prank(bob);
        ys.close(2);

        vm.prank(carol);
        uint256 claimed = ys.claimYieldInShares(carol);

        assertEq(claimed, expectedYieldInShares, "claimed");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYieldInShares_worksIfAllStreamsAreClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);
        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares((alicesPrincipal + bobsPrincipal) / 2);
        assertApproxEqAbs(ys.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's expected yield");

        vm.prank(bob);
        ys.close(2);
        vm.prank(alice);
        ys.close(1);

        vm.prank(carol);
        uint256 claimed = ys.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(ys.previewClaimYield(carol), 0, "carols's yield");
    }

    /*
     * --------------------
     *       #close
     * --------------------
     */

    function test_close_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 bobsShares = _depositToVault(bob, 1e18);
        _approveYieldStreamsContract(bob, bobsShares);

        vm.startPrank(bob);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        ys.close(streamId);
    }

    function test_close_failsIfTokenIdIsInvalid() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 invalidId = streamId + 1;

        vm.startPrank(alice);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        ys.close(invalidId);
    }

    function test_close_burnsNftAndReturnsPrincipal() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        assertEq(ys.balanceOf(alice), 1, "alice's nfts before");

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = ys.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        assertEq(ys.getPrincipal(streamId), principal, "principal");

        vm.prank(alice);
        uint256 sharesReturned = ys.close(streamId);

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        ys.ownerOf(streamId);
        assertEq(ys.balanceOf(alice), 0, "alice's nfts after");
        assertEq(ys.receiverPrincipal(bob, streamId), 0, "receiver principal");

        assertApproxEqAbs(sharesReturned, shares - yieldValueInShares, 1, "shares returned");
        assertEq(vault.balanceOf(alice), sharesReturned, "alice's shares");
        assertApproxEqAbs(vault.convertToAssets(sharesReturned), principal, 1, "alices principal");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_close_emitsEvent() public {
        uint256 principal = 2e18;
        _openYieldStream(alice, bob, principal);

        // add 100% profit to vault
        _generateYield(1e18);

        uint256 shares = vault.convertToShares(principal);

        vm.expectEmit(true, true, true, true);
        emit StreamClosed(1, alice, bob, shares, principal);

        vm.prank(alice);
        ys.close(1);
    }

    function test_close_continuesGeneratingYieldForReceiverUntilClaimed() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 bobsYield = ys.previewClaimYield(bob);

        vm.prank(alice);
        ys.close(1);

        assertApproxEqAbs(ys.previewClaimYield(bob), bobsYield, 1, "bob's yield after close");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after close");

        // add 50% profit to vault again
        _generateYield(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(ys.previewClaimYield(bob), expectedYield, 1, "bob's yield after profit");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after profit");

        vm.prank(bob);
        ys.claimYield(bob);

        assertApproxEqAbs(asset.balanceOf(bob), expectedYield, 1, "bob's assets after claim");

        // add 50% profit to vault again
        _generateYield(0.5e18);

        assertEq(ys.previewClaimYield(bob), 0, "bob's yield after new profit");
    }

    function test_close_worksIfVaultMadeLosses() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        _openYieldStream(alice, bob, principal);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.prank(alice);
        ys.close(1);

        assertEq(vault.convertToAssets(shares), principal.mulWadUp(0.8e18), "shares value");
        assertEq(ys.previewClaimYield(bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(ys.receiverPrincipal(bob, 1), 0, "receiver principal");
        assertEq(ys.receiverTotalShares(bob), 0, "receiver shares");
        assertEq(ys.receiverTotalPrincipal(bob), 0, "receiver total principal");
    }

    function test_close_failsIfStreamIsAlreadyClosed() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // works
        vm.startPrank(alice);
        ys.close(streamId);

        // fails
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        ys.close(streamId);
    }

    function test_close_doesntAffectOtherStreamsFromTheSameStreamer() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);
        _openYieldStream(alice, carol, principal);

        // create a 20% profit
        _generateYield(0.2e18);

        uint256 bobsYield = ys.previewClaimYield(bob);
        uint256 carolsYield = ys.previewClaimYield(carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");
        assertEq(vault.balanceOf(alice), 0, "alice's shares != 0");

        vm.prank(alice);
        ys.close(1);

        assertApproxEqAbs(vault.balanceOf(alice), vault.convertToShares(principal), 1, "alice's principal");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertApproxEqAbs(ys.previewClaimYield(bob), bobsYield, 1, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(ys.previewClaimYield(carol), carolsYield, "carol's yield");
    }

    function test_close_doesntAffectStreamsFromAnotherStreamer() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 2e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // create a 20% profit
        _generateYield(0.2e18);

        assertEq(ys.receiverTotalPrincipal(carol), alicesPrincipal + bobsPrincipal, "carol's total principal");

        uint256 carolsYield = ys.previewClaimYield(carol);

        vm.prank(alice);
        ys.close(1);

        assertApproxEqAbs(ys.previewClaimYield(carol), carolsYield, 1, "carol's yield");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), alicesPrincipal, 2, "alice's shares value");
        assertEq(ys.receiverPrincipal(carol, 1), 0, "alice's principal");
        assertEq(ys.receiverPrincipal(carol, 2), bobsPrincipal, "bob's principal");
        assertEq(ys.receiverTotalPrincipal(carol), bobsPrincipal, "carol's total principal");
    }

    /*
     * --------------------
     *    #previewClose
     * --------------------
     */

    function test_previewClose_returns0IfTokenDoesntExist() public {
        assertEq(ys.previewClose(1), 0);
    }

    function test_previewClose_returnsSharesToBeReturned() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = ys.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        assertApproxEqAbs(ys.previewClose(streamId), shares - yieldValueInShares, 1, "shares returned");
    }

    /*
     * --------------------
     *     #multicall
     * --------------------
     */

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(YieldStreams.open, (alice, bob, (shares * 3) / 4, 0));
        data[1] = abi.encodeCall(YieldStreams.open, (alice, carol, shares / 4, 0));

        vm.startPrank(alice);
        vault.approve(address(ys), shares);
        ys.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(ys.receiverTotalShares(bob), (shares * 3) / 4, "receiver shares bob");
        assertEq(ys.receiverTotalShares(carol), shares / 4, "receiver shares carol");
    }

    /*
     * --------------------
     *      #transfer
     * --------------------
     */

    function test_transfer() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVault(alice, principal);
        _approveYieldStreamsContract(alice, shares);

        vm.startPrank(alice);
        ys.open(alice, bob, shares, 0);

        _generateYield(0.5e18);

        ys.transferFrom(alice, carol, 1);
        vm.stopPrank();

        assertEq(ys.balanceOf(alice), 0, "alice's nfts");
        assertEq(ys.balanceOf(carol), 1, "carol's nfts");
        assertEq(ys.ownerOf(1), carol, "owner");
        assertEq(ys.previewClaimYield(bob), 1e18 / 2, "bob's yield");

        vm.prank(carol);
        ys.close(1);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(carol)), principal, 1, "carol's assets");
        assertEq(ys.balanceOf(carol), 0, "carol's nfts");
        assertApproxEqAbs(ys.previewClaimYield(bob), 1e18 / 2, 1, "bob's yield");
    }

    /*
     * --------------------
     *      #tokenUri
     * --------------------
     */

    function test_tokenUri_returnsEmptyString() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(ys.tokenURI(1), "", "token uri not empty");
    }

    /*
     * --------------------
     *  #supportsInterface
     * --------------------
     */

    function test_supportsInterface() public {
        assertTrue(ys.supportsInterface(type(IERC721).interfaceId), "IERC721");
        assertTrue(ys.supportsInterface(type(IERC721Metadata).interfaceId), "IERC721Metadata");
        assertTrue(ys.supportsInterface(type(IERC165).interfaceId), "IERC165");

        assertTrue(!ys.supportsInterface(type(IERC721Receiver).interfaceId), "IERC721Receiver");
    }

    /*
     * --------------------
     *      FUZZING
     * --------------------
     */

    function testFuzz_open_claim_close_stream(uint256 _principal) public {
        _principal = bound(_principal, 10000, 1000 ether);
        uint256 shares = _depositToVault(alice, _principal);
        _approveYieldStreamsContract(alice, shares);
        vm.startPrank(alice);

        // open 10 streams
        uint256 sharesToOpen = shares / 10;
        address[] memory receivers = new address[](10);
        uint256[] memory streamIds = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            // generate random receiver address
            receivers[i] = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp + i, block.prevrandao)))));
            streamIds[i] = ys.open(alice, receivers[i], sharesToOpen, 0);
        }

        vm.stopPrank();

        _generateYield(0.5e18);

        uint256 expectedYield = _principal.mulDivDown(0.5e18, 10e18);

        // claim yield
        for (uint256 i = 0; i < 10; i++) {
            assertEq(ys.previewClaimYield(receivers[i]), expectedYield, "yield");

            vm.prank(receivers[i]);
            ys.claimYield(receivers[i]);

            assertApproxEqAbs(asset.balanceOf(receivers[i]), expectedYield, 3, "assets");
            assertEq(ys.previewClaimYield(receivers[i]), 0, "yield");
        }

        // close streams
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            ys.close(streamIds[i]);
        }

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), _principal, 0.005e18, "alice's principal");
        assertEq(vault.balanceOf(address(ys)), 0, "contract's shares");
    }

    /*
     * --------------------
     *     helper funcs
     * --------------------
     */

    function _depositToVaultAndApprove(address _from, uint256 _amount) internal returns (uint256 shares) {
        shares = _depositToVault(_from, _amount);
        _approveYieldStreamsContract(_from, shares);
    }

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        shares = _depositToVault(IERC4626(address(vault)), _from, _amount);
    }

    function _approveYieldStreamsContract(address _from, uint256 _shares) internal {
        _approve(IERC4626(address(vault)), _from, address(ys), _shares);
    }

    function _approveAssetsAndPreviewDeposit(address _owner, uint256 _amount) private returns (uint256 shares) {
        _dealAndApprove(IERC20(address(asset)), _owner, address(ys), _amount);

        shares = vault.previewDeposit(_amount);
    }

    function _generateYield(int256 _yield) internal {
        _generateYield(IERC4626(address(vault)), _yield);
    }

    function _openYieldStream(address _from, address _to, uint256 _amount) internal returns (uint256 streamId) {
        uint256 shares = _depositToVault(_from, _amount);
        _approveYieldStreamsContract(_from, shares);

        vm.prank(_from);
        streamId = ys.open(_from, _to, shares, 0);
    }
}
