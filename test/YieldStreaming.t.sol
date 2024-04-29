// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC721Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "openzeppelin-contracts/interfaces/IERC721Receiver.sol";
import {IERC721} from "openzeppelin-contracts/interfaces/IERC721.sol";
import {IERC721Metadata} from "openzeppelin-contracts/interfaces/IERC721Metadata.sol";
import {IERC165} from "openzeppelin-contracts/interfaces/IERC165.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {TestCommon} from "./common/TestCommon.sol";
import {YieldStreaming} from "src/YieldStreaming.sol";
import "src/common/Errors.sol";

contract YieldStreamingTest is TestCommon {
    using FixedPointMathLib for uint256;

    event Open(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event TopUp(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event Close(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event LossTolerancePercentUpdated(address indexed owner, uint256 oldValue, uint256 newValue);

    YieldStreaming public yieldStreaming;
    MockERC4626 public vault;
    MockERC20 public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("Mock ERC20", "mERC20", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "Mock ERC4626", "mERC4626");
        yieldStreaming = new YieldStreaming(IERC4626(address(vault)));

        // make initial deposit to the vault
        _depositToVault(address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    /// *** #constructor *** ///

    function test_constructor() public {
        assertEq(address(yieldStreaming.vault()), address(vault), "vault");

        assertEq(yieldStreaming.name(), "Yield Streaming - Mock ERC4626", "name");
        assertEq(yieldStreaming.symbol(), "YST-mERC4626", "symbol");

        // nft ids start from 1
        assertEq(yieldStreaming.nextStreamId(), 1, "next stream id");
        assertEq(address(yieldStreaming.asset()), address(asset), "underlying asset");
        // vault is not allowed to transfer assets by default
        assertEq(asset.allowance(address(yieldStreaming), address(vault)), 0, "allowance");
    }

    /// *** #open *** ///

    function test_open_failsFor0Shares() public {
        _depositToVaultAndApprove(alice, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(AmountZero.selector);
        yieldStreaming.open(bob, 0, 0);
    }

    function test_open_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(AddressZero.selector);
        yieldStreaming.open(address(0), shares, 0);
    }

    function test_open_mintsNtfAndTransfersShares() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        vm.startPrank(alice);
        uint256 streamId = yieldStreaming.open(bob, shares, 0);

        assertEq(streamId, 1, "stream id");
        assertEq(yieldStreaming.nextStreamId(), 2, "next stream id");
        assertEq(yieldStreaming.ownerOf(streamId), alice, "owner of token");
        assertEq(yieldStreaming.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(address(yieldStreaming)), shares, "contract's shares");
        assertEq(yieldStreaming.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_open_emitsEvent() public {
        uint256 principal = 4e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        uint256 streamId = yieldStreaming.nextStreamId();

        vm.expectEmit(true, true, true, true);
        emit Open(streamId, alice, bob, shares, principal);

        vm.prank(alice);
        yieldStreaming.open(bob, shares, 0);
    }

    function test_open_toTwoReceivers() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVaultAndApprove(alice, principal);

        vm.startPrank(alice);
        uint256 firstId = yieldStreaming.open(bob, shares / 2, 0);
        uint256 secondId = yieldStreaming.open(carol, shares / 4, 0);

        assertEq(firstId, 1, "first id");
        assertEq(secondId, 2, "second id");
        assertEq(yieldStreaming.nextStreamId(), 3, "next stream id");

        assertEq(vault.balanceOf(alice), shares / 4, "alice's shares");

        assertEq(yieldStreaming.receiverTotalShares(bob), shares / 2, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal / 2, "receiver principal  bob");

        assertEq(yieldStreaming.receiverTotalShares(carol), shares / 4, "receiver shares carol");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), principal / 4, "principal carol");
        assertEq(yieldStreaming.receiverPrincipal(carol, 2), principal / 4, "receiver principal  carol");
    }

    function test_open_failsIfReceiverIsInDebtAndImmediateLossIsAboveLossTolerancePercent() public {
        uint256 alicesPrincipal = 1e18;
        uint256 alicesShares = _depositToVaultAndApprove(alice, alicesPrincipal);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.open(carol, alicesShares, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(yieldStreaming.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsPrincipal);
        _approveYieldStreaming(bob, bobsShares);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.033e18; // 3.3%
        vm.prank(bob);
        vm.expectRevert(YieldStreaming.LossToleranceExceeded.selector);
        yieldStreaming.open(carol, bobsShares, toleratedLossOnOpenPct);
    }

    function test_open_worksIfReceiverIsInDebtAndLossIsBelowLossTolerancePercent() public {
        uint256 alicesPrincipal = 1e18;
        uint256 alicesShares = _depositToVaultAndApprove(alice, alicesPrincipal);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.open(carol, alicesShares, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(yieldStreaming.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsPrincipal);
        _approveYieldStreaming(bob, bobsShares);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.034e18; // 3.4%
        vm.prank(bob);
        uint256 streamId = yieldStreaming.open(carol, bobsShares, toleratedLossOnOpenPct);

        uint256 principalWithLoss = vault.convertToAssets(yieldStreaming.previewClose(2));
        uint256 bobsLossOnOpen = bobsPrincipal - principalWithLoss;

        assertTrue(principalWithLoss < bobsPrincipal, "principal with loss > bobs deposit");
        assertApproxEqRel(principalWithLoss, bobsPrincipal, toleratedLossOnOpenPct, "principal with loss");
        assertTrue(bobsLossOnOpen < bobsPrincipal.mulWadDown(toleratedLossOnOpenPct), "loss tolerance exceeded");

        vm.prank(bob);
        yieldStreaming.close(streamId);

        uint256 bobsPrincipalAfterClose = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobsPrincipalAfterClose, bobsPrincipal - bobsLossOnOpen, 1, "bobs principal after close");
    }

    function test_openUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 principal = 1 ether;
        uint256 shares = _depositToVault(dave, principal);
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
        uint256 streamId = yieldStreaming.openUsingPermit(bob, shares, 0, deadline, v, r, s);

        assertEq(streamId, 1, "stream id");
        assertEq(vault.balanceOf(address(yieldStreaming)), shares, "contract's shares");
        assertEq(yieldStreaming.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    /// *** #openWithAssets *** ///

    function test_openWithAssets_failsFor0Assets() public {
        _approveAssetsAndPreviewDeposit(alice, 1e18);

        // fails to deposit 0 amount to the vault
        vm.expectRevert("ZERO_SHARES");
        vm.prank(alice);
        yieldStreaming.openWithAssets(bob, 0, 0);
    }

    function test_openWithAssets_failsIfReceiverIsAddress0() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        // underflows when trying to transfer assets from address(0)
        vm.expectRevert();
        yieldStreaming.openWithAssets(address(0), principal, 0);
    }

    function test_openWithAssets_mintsNtfAndTransfersShares() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        uint256 shares = yieldStreaming.previewOpenWithAssets(bob, principal, 0);
        assertEq(shares, vault.convertToShares(principal), "preview open with assets");

        vm.prank(alice);
        uint256 streamId = yieldStreaming.openWithAssets(bob, principal, 0);

        assertEq(streamId, 1, "stream id");
        assertEq(yieldStreaming.nextStreamId(), 2, "next stream id");
        assertEq(yieldStreaming.ownerOf(streamId), alice, "owner of token");
        assertEq(yieldStreaming.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(address(yieldStreaming)), shares, "contract's shares");
        assertEq(yieldStreaming.receiverTotalShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    function test_openWithAssets_emitsEvent() public {
        uint256 principal = 1e18;
        uint256 shares = _approveAssetsAndPreviewDeposit(alice, principal);
        uint256 streamId = yieldStreaming.nextStreamId();

        vm.expectEmit(true, true, true, true);
        emit Open(streamId, alice, bob, shares, principal);

        vm.prank(alice);
        yieldStreaming.openWithAssets(bob, principal, 0);
    }

    function test_openWithAssets_toTwoReceivers() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        vm.startPrank(alice);
        uint256 firstId = yieldStreaming.openWithAssets(bob, principal / 2, 0);
        uint256 secondId = yieldStreaming.openWithAssets(carol, principal / 4, 0);

        assertEq(firstId, 1, "first id");
        assertEq(secondId, 2, "second id");
        assertEq(yieldStreaming.nextStreamId(), 3, "next stream id");

        assertEq(asset.balanceOf(alice), principal / 4, "alice's assets");

        assertEq(yieldStreaming.receiverTotalShares(bob), vault.convertToShares(principal / 2), "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal / 2, "receiver principal  bob");

        assertEq(
            yieldStreaming.receiverTotalShares(carol), vault.convertToShares(principal / 4), "receiver shares carol"
        );
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), principal / 4, "principal carol");
        assertEq(yieldStreaming.receiverPrincipal(carol, 2), principal / 4, "receiver principal  carol");
    }

    function test_openWithAssets_failsIfReceiverIsInDebtAndImmediateLossIsAboveLossTolerancePercent() public {
        uint256 principal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, principal);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openWithAssets(carol, principal, 0);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(yieldStreaming.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsPrincipal = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsPrincipal);
        _approveYieldStreaming(bob, bobsShares);

        // debt for carol = 0.1e18
        // alice's principal = 1e18
        // bob's principal = 2e18
        // bob's share of loss = 0.1e18 * 2e18 / (1e18 + 2e18) = 0.066e18
        // bob's loss on open = 2e18 - 0.066e18 = 1.933e18
        // bbo's loss in pct = 1 - 1.933e18 / 2e18 = 1 - 0.9665 = 0.0335 = 3.35%

        // bob opens a stream to carol
        uint256 toleratedLossOnOpenPct = 0.033e18; // 3.3%
        vm.prank(bob);
        vm.expectRevert(YieldStreaming.LossToleranceExceeded.selector);
        yieldStreaming.open(carol, bobsShares, toleratedLossOnOpenPct);
    }

    function test_openWithAssets_worksIfReceiverIsInDebtAndLossIsBelowLossTolerancePercent() public {
        _openYieldStream(alice, carol, 1e18);

        // create 10% loss
        _generateYield(-0.1e18);
        assertEq(yieldStreaming.debtFor(carol), 0.1e18, "debt for carol");

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
        uint256 streamId = yieldStreaming.openWithAssets(carol, bobsPrincipal, toleratedLossOnOpenPct);

        uint256 principalWithLoss = vault.convertToAssets(yieldStreaming.previewClose(2));
        uint256 bobsLossOnOpen = bobsPrincipal - principalWithLoss;

        assertTrue(principalWithLoss < bobsPrincipal, "principal with loss > bobs deposit");
        assertApproxEqRel(principalWithLoss, bobsPrincipal, toleratedLossOnOpenPct, "principal with loss");
        assertTrue(bobsLossOnOpen < bobsPrincipal.mulWadDown(toleratedLossOnOpenPct), "loss tolerance exceeded");

        vm.prank(bob);
        yieldStreaming.close(streamId);

        uint256 bobsPrincipalAfterClose = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobsPrincipalAfterClose, bobsPrincipal - bobsLossOnOpen, 1, "bobs principal after close");
    }

    function test_openWithAssetsUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 principal = 1 ether;
        uint256 nonce = asset.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;
        deal(address(asset), dave, principal);

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC20(asset).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(yieldStreaming), principal, nonce, deadline))
                )
            )
        );

        vm.prank(dave);
        uint256 streamId = yieldStreaming.openWithAssetsUsingPermit(bob, principal, 0, deadline, v, r, s);

        assertEq(streamId, 1, "stream id");
        assertEq(vault.balanceOf(address(yieldStreaming)), vault.convertToShares(principal), "contract's shares");
        assertEq(yieldStreaming.receiverTotalShares(bob), vault.convertToShares(principal), "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), principal, "receiver principal");
    }

    /// *** #topUp *** ///

    function test_topUp_failsIfAmountIs0() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        _depositToVaultAndApprove(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(AmountZero.selector);
        yieldStreaming.topUp(streamId, 0);
    }

    function test_topUp_failsIfStreamDoesntExist() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);
        uint256 invalidTokenId = streamId + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, invalidTokenId));
        yieldStreaming.topUp(invalidTokenId, shares);
    }

    function test_topUp_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        uint256 shares = _depositToVaultAndApprove(alice, 1e18);

        vm.prank(carol);
        vm.expectRevert(YieldStreaming.CallerNotOwner.selector);
        yieldStreaming.topUp(streamId, shares);
    }

    function test_topUp_addsToExistingStream() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _depositToVaultAndApprove(alice, addedPrincipal);

        vm.startPrank(alice);

        // top up stream
        yieldStreaming.topUp(streamId, addedShares);

        uint256 expectedPrincipal = principal + addedPrincipal;
        assertEq(
            yieldStreaming.receiverTotalShares(bob), vault.convertToShares(expectedPrincipal), "receiver shares bob"
        );
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), expectedPrincipal, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), expectedPrincipal, "receiver principal  bob");
    }

    function test_topUp_emitsEvent() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _depositToVaultAndApprove(alice, addedPrincipal);

        vm.expectEmit(true, true, true, true);
        emit TopUp(streamId, alice, bob, addedShares, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUp(streamId, addedShares);
    }

    function test_topUp_doesntAffectYieldAccrued() public {
        uint256 streamId = _openYieldStream(alice, bob, 2e18);

        _generateYield(0.2e18);
        uint256 yield = yieldStreaming.previewClaimYield(bob);

        // all the yield has been accrued
        assertEq(yieldStreaming.previewClaimYield(bob), yield, "yield before top up");

        // top up stream
        uint256 addedShares = _depositToVaultAndApprove(alice, 1e18);

        vm.prank(alice);
        yieldStreaming.topUp(streamId, addedShares);

        // yield should remain the same
        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), yield, 1, "yield after top up");
    }

    function test_topUp_affectsFutureYield() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // double the share price
        _generateYield(1e18);

        assertEq(yieldStreaming.previewClaimYield(bob), principal, "yield before top up");

        // top up
        uint256 addedShares = _depositToVaultAndApprove(alice, 2e18);

        vm.prank(alice);
        yieldStreaming.topUp(streamId, addedShares);

        _generateYield(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        // 1e18 * 2 + 2e18 * 0.5 = 3e18
        assertEq(yieldStreaming.previewClaimYield(bob), 3e18, "yield after top up");
    }

    function test_topUp_worksWhenReceiverIsInDebt() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        _generateYield(-0.5e18);

        uint256 receiverDebt = yieldStreaming.debtFor(bob);

        assertEq(receiverDebt, principal / 2, "receiver debt before top up");

        // top up stream
        uint256 addedShares = _depositToVaultAndApprove(alice, principal);
        vm.prank(alice);
        yieldStreaming.topUp(streamId, addedShares);

        assertEq(yieldStreaming.debtFor(bob), receiverDebt, "receiver debt");
        assertEq(yieldStreaming.receiverTotalShares(bob), shares + addedShares, "receiver shares");
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), principal * 2, "receiver principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal * 2, "receiver total principal");
    }

    function test_topUpUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 principal = 1 ether;
        uint256 streamId = _openYieldStream(dave, bob, principal);

        // top up
        uint256 addedPrincipal = 2 ether;
        uint256 addedShares = _depositToVault(dave, addedPrincipal);

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
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(yieldStreaming), addedShares, nonce, deadline))
                )
            )
        );

        // top up stream
        vm.prank(dave);
        yieldStreaming.topUpUsingPermit(streamId, addedShares, deadline, v, r, s);

        assertEq(
            yieldStreaming.receiverTotalShares(bob), vault.convertToShares(principal) + addedShares, "receiver shares"
        );
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), principal + addedPrincipal, "receiver principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal + addedPrincipal, "receiver total principal");
    }

    /// *** #topUpWithAssets *** ///

    function test_topUpWithAssets_failsIfAmountIs0() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);
        _approveAssetsAndPreviewDeposit(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(AmountZero.selector);
        yieldStreaming.topUpWithAssets(streamId, 0);
    }

    function test_topUpWithAssets_failsIfStreamDoesntExist() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 1e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        uint256 invalidTokenId = streamId + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, invalidTokenId));
        yieldStreaming.topUpWithAssets(invalidTokenId, addedPrincipal);
    }

    function test_topUpWithAssets_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 1e18;
        _approveAssetsAndPreviewDeposit(carol, addedPrincipal);

        vm.prank(carol);
        vm.expectRevert(YieldStreaming.CallerNotOwner.selector);
        yieldStreaming.topUp(streamId, addedPrincipal);
    }

    function test_topUpWithAssets_addsToExistingStream() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, principal);

        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUpWithAssets(streamId, addedPrincipal);

        uint256 expectedTotalPrincipal = principal + addedPrincipal;
        assertEq(
            yieldStreaming.receiverTotalShares(bob),
            vault.convertToShares(expectedTotalPrincipal),
            "receiver shares bob"
        );
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), expectedTotalPrincipal, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), expectedTotalPrincipal, "receiver principal  bob");
    }

    function test_topUpWithAssets_emitsEvent() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.expectEmit(true, true, true, true);
        emit TopUp(streamId, alice, bob, addedShares, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUpWithAssets(streamId, addedPrincipal);
    }

    function test_topUpWithAssets_doesntAffectYieldAccrued() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        _generateYield(0.2e18);
        uint256 yield = yieldStreaming.previewClaimYield(bob);

        // assert the yield is not 0
        assertEq(yield, principal.mulWadDown(0.2e18), "yield before top up");

        // top up stream
        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUpWithAssets(streamId, addedPrincipal);

        // yield should remain the same
        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), yield, 1, "yield after top up");
    }

    function test_topUpWithAssets_affectsFutureYield() public {
        uint256 principal = 1e18;
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // double the share price
        _generateYield(1e18);

        assertEq(yieldStreaming.previewClaimYield(bob), principal, "yield before top up");

        // top up
        uint256 addedPrincipal = 2e18;
        _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUpWithAssets(streamId, addedPrincipal);

        _generateYield(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        // 1e18 * 2 + 2e18 * 0.5 = 3e18
        assertEq(yieldStreaming.previewClaimYield(bob), 3e18, "yield after top up");
    }

    function test_topUpWithAssets_worksWhenReceiverIsInDebt() public {
        uint256 principal = 1e18;
        uint256 shares = vault.convertToShares(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        _generateYield(-0.5e18);

        uint256 receiverDebt = yieldStreaming.debtFor(bob);

        assertEq(receiverDebt, principal / 2, "receiver debt before top up");

        // top up
        uint256 addedPrincipal = 2e18;
        uint256 addedShares = _approveAssetsAndPreviewDeposit(alice, addedPrincipal);

        vm.prank(alice);
        yieldStreaming.topUpWithAssets(streamId, addedPrincipal);

        assertEq(yieldStreaming.debtFor(bob), receiverDebt, "receiver debt after top up");
        assertEq(yieldStreaming.receiverTotalShares(bob), shares + addedShares, "receiver shares");
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), principal + addedPrincipal, "receiver principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), principal + addedPrincipal, "receiver total principal");
    }

    function test_topUpWithAssetsUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 principal = 1 ether;
        uint256 streamId = _openYieldStream(dave, bob, principal);

        // top up
        uint256 addedPrincipal = 2 ether;
        deal(address(asset), dave, addedPrincipal);

        uint256 nonce = asset.nonces(dave);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Sign the permit message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            davesPrivateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    MockERC20(address(asset)).DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(PERMIT_TYPEHASH, dave, address(yieldStreaming), addedPrincipal, nonce, deadline)
                    )
                )
            )
        );

        // top up stream
        vm.prank(dave);
        yieldStreaming.topUpWithAssetsUsingPermit(streamId, addedPrincipal, deadline, v, r, s);

        uint256 expectedTotalPrincipal = principal + addedPrincipal;
        assertEq(
            yieldStreaming.receiverTotalShares(bob), vault.convertToShares(expectedTotalPrincipal), "receiver shares"
        );
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), expectedTotalPrincipal, "receiver principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), expectedTotalPrincipal, "receiver total principal");
    }

    /// *** #previewClaimYield *** ///

    function test_previewClaimYield_returns0IfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returns0IfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        uint256 totalAssets = vault.totalAssets();

        // create a 20% loss
        _generateYield(-0.2e18);

        assertApproxEqAbs(vault.totalAssets(), totalAssets.mulWadDown(0.8e18), 1, "vault no losses");

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returnsGeneratedYield() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), principal / 2, "bob's yield");
    }

    function test_previewClaimYield_returnsGeneratedYieldAfterStreamIsClosed() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yieldFor = yieldStreaming.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.prank(alice);
        yieldStreaming.close(1);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(vault.balanceOf(alice), vault.convertToShares(principal), "alice's shares");
    }

    function test_previewClaimYield_returns0AfterClaimAndCloseStream() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yieldFor = yieldStreaming.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, principal / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        vm.stopPrank();

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
        assertApproxEqAbs(asset.balanceOf(bob), principal / 2, 1, "bob's assets");
        assertEq(vault.balanceOf(alice), 0, "alice's shares");

        vm.prank(alice);
        yieldStreaming.close(1);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
    }

    /// *** #claimYield *** ///

    function test_claimYield_toSelf() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(bob), principal / 2, 1, "bob's assets");
    }

    function test_claimYield_toAnotherAccount() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 previewClaim = yieldStreaming.previewClaimYield(bob);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertApproxEqAbs(claimed, previewClaim, 1, "claimed");

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertApproxEqAbs(asset.balanceOf(carol), claimed, 1, "carol's assets");
    }

    function test_claimYield_emitsEvent() public {
        _openYieldStream(alice, bob, 3e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 sharesRedeemed = vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit ClaimYield(bob, carol, sharesRedeemed, yield);

        vm.prank(bob);
        yieldStreaming.claimYield(carol);
    }

    function test_claimYield_revertsToAddressIs0() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(address(0));
    }

    function test_claimYield_revertsIfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_claimsFromAllOpenedStreams() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 100% profit to vault
        _generateYield(1e18);

        assertEq(yieldStreaming.previewClaimYield(carol), alicesPrincipal + bobsPrincipal, "carol's yield");

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertEq(claimed, alicesPrincipal + bobsPrincipal, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYield_worksIfOneOfStreamsIsClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 100% profit to vault
        _generateYield(1e18);

        assertEq(yieldStreaming.previewClaimYield(carol), alicesPrincipal + bobsPrincipal, "carol's expected yield");

        vm.prank(bob);
        yieldStreaming.close(2);

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertEq(claimed, alicesPrincipal + bobsPrincipal, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(vault.balanceOf(carol), 0, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYield_worksIfAllStreamsAreClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        assertEq(
            yieldStreaming.previewClaimYield(carol), (alicesPrincipal + bobsPrincipal) / 2, "carol's expected yield"
        );

        vm.prank(bob);
        yieldStreaming.close(2);
        vm.prank(alice);
        yieldStreaming.close(1);

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertApproxEqAbs(claimed, (alicesPrincipal + bobsPrincipal) / 2, 1, "claimed");
        assertEq(asset.balanceOf(carol), claimed, "carol's assets");
        assertEq(vault.balanceOf(carol), 0, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    /// *** #claimYieldInShares *** ///

    function test_claimYieldInShares_toSelf() public {
        uint256 principal = 2e18;
        _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares(principal / 2);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYieldInShares(bob);

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
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

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

        uint256 expectedYieldInShares = yieldStreaming.previewClaimYieldInShares(bob);

        vm.expectEmit(true, true, true, true);
        emit ClaimYieldInShares(bob, carol, expectedYieldInShares);

        vm.prank(bob);
        yieldStreaming.claimYieldInShares(carol);
    }

    function test_claimYieldInShares_revertsToAddressIs0() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(address(0));
    }

    function test_claimYieldInShares_revertsIfNoYield() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(bob);
    }

    function test_claimYieldInShares_revertsIfVaultMadeLosses() public {
        _openYieldStream(alice, bob, 1e18);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
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

        assertApproxEqAbs(yieldStreaming.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's yield");

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
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
        assertApproxEqAbs(
            yieldStreaming.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's expected yield"
        );

        vm.prank(bob);
        yieldStreaming.close(2);

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

        assertEq(claimed, expectedYieldInShares, "claimed");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    function test_claimYieldInShares_worksIfAllStreamsAreClosed() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);
        uint256 bobsPrincipal = 3e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 expectedYieldInShares = vault.convertToShares((alicesPrincipal + bobsPrincipal) / 2);
        assertApproxEqAbs(
            yieldStreaming.previewClaimYieldInShares(carol), expectedYieldInShares, 1, "carol's expected yield"
        );

        vm.prank(bob);
        yieldStreaming.close(2);
        vm.prank(alice);
        yieldStreaming.close(1);

        vm.prank(carol);
        uint256 claimed = yieldStreaming.claimYieldInShares(carol);

        assertApproxEqAbs(claimed, expectedYieldInShares, 1, "claimed");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(vault.balanceOf(carol), claimed, "carol's shares");
        assertEq(yieldStreaming.previewClaimYield(carol), 0, "carols's yield");
    }

    /// *** #close *** ///

    function test_close_failsIfCallerIsNotOwner() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 bobsShares = _depositToVault(bob, 1e18);
        _approveYieldStreaming(bob, bobsShares);

        vm.startPrank(bob);
        vm.expectRevert(YieldStreaming.CallerNotOwner.selector);
        yieldStreaming.close(streamId);
    }

    function test_close_failsIfTokenIdIsInvalid() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        uint256 invalidId = streamId + 1;

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, invalidId));
        yieldStreaming.close(invalidId);
    }

    function test_close_burnsNftAndReturnsPrincipal() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        assertEq(yieldStreaming.balanceOf(alice), 1, "alice's nfts before");

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        assertEq(yieldStreaming.getPrincipal(streamId), principal, "principal");

        vm.prank(alice);
        uint256 sharesReturned = yieldStreaming.close(streamId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, streamId));
        yieldStreaming.ownerOf(streamId);
        assertEq(yieldStreaming.balanceOf(alice), 0, "alice's nfts after");
        assertEq(yieldStreaming.receiverPrincipal(bob, streamId), 0, "receiver principal");

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
        emit Close(1, alice, bob, shares, principal);

        vm.prank(alice);
        yieldStreaming.close(1);
    }

    function test_close_continuesGeneratingYieldForReceiverUntilClaimed() public {
        _openYieldStream(alice, bob, 1e18);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);

        vm.prank(alice);
        yieldStreaming.close(1);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), bobsYield, 1, "bob's yield after close");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after close");

        // add 50% profit to vault again
        _generateYield(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), expectedYield, 1, "bob's yield after profit");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after profit");

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertApproxEqAbs(asset.balanceOf(bob), expectedYield, 1, "bob's assets after claim");

        // add 50% profit to vault again
        _generateYield(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield after new profit");
    }

    function test_close_worksIfVaultMadeLosses() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        _openYieldStream(alice, bob, principal);

        // create a 20% loss
        _generateYield(-0.2e18);

        vm.prank(alice);
        yieldStreaming.close(1);

        assertEq(vault.convertToAssets(shares), principal.mulWadUp(0.8e18), "shares value");
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), 0, "receiver principal");
        assertEq(yieldStreaming.receiverTotalShares(bob), 0, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), 0, "receiver total principal");
    }

    function test_close_failsIfStreamIsAlreadyClosed() public {
        uint256 streamId = _openYieldStream(alice, bob, 1e18);

        // works
        vm.startPrank(alice);
        yieldStreaming.close(streamId);

        // fails
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, streamId));
        yieldStreaming.close(streamId);
    }

    function test_close_doesntAffectOtherStreamsFromTheSameStreamer() public {
        uint256 principal = 1e18;
        _openYieldStream(alice, bob, principal);
        _openYieldStream(alice, carol, principal);

        // create a 20% profit
        _generateYield(0.2e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);
        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");
        assertEq(vault.balanceOf(alice), 0, "alice's shares != 0");

        vm.prank(alice);
        yieldStreaming.close(1);

        assertApproxEqAbs(vault.balanceOf(alice), vault.convertToShares(principal), 1, "alice's principal");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), bobsYield, 1, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(yieldStreaming.previewClaimYield(carol), carolsYield, "carol's yield");
    }

    function test_close_doesntAffectStreamsFromAnotherStreamer() public {
        uint256 alicesPrincipal = 1e18;
        _openYieldStream(alice, carol, alicesPrincipal);

        uint256 bobsPrincipal = 2e18;
        _openYieldStream(bob, carol, bobsPrincipal);

        // create a 20% profit
        _generateYield(0.2e18);

        assertEq(
            yieldStreaming.receiverTotalPrincipal(carol), alicesPrincipal + bobsPrincipal, "carol's total principal"
        );

        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        vm.prank(alice);
        yieldStreaming.close(1);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(carol), carolsYield, 1, "carol's yield");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), alicesPrincipal, 2, "alice's shares value");
        assertEq(yieldStreaming.receiverPrincipal(carol, 1), 0, "alice's principal");
        assertEq(yieldStreaming.receiverPrincipal(carol, 2), bobsPrincipal, "bob's principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), bobsPrincipal, "carol's total principal");
    }

    /// *** #previewClose *** ///

    function test_previewClose_returns0IfTokenDoesntExist() public {
        assertEq(yieldStreaming.previewClose(1), 0);
    }

    function test_previewClose_returnsSharesToBeReturned() public {
        uint256 principal = 1e18;
        uint256 shares = vault.previewDeposit(principal);
        uint256 streamId = _openYieldStream(alice, bob, principal);

        // add 50% profit to vault
        _generateYield(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);

        assertApproxEqAbs(yieldStreaming.previewClose(streamId), shares - yieldValueInShares, 1, "shares returned");
    }

    /// *** #multicall *** ///

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(YieldStreaming.open.selector, bob, (shares * 3) / 4, 0);
        data[1] = abi.encodeWithSelector(YieldStreaming.open.selector, carol, shares / 4, 0);

        vm.startPrank(alice);
        vault.approve(address(yieldStreaming), shares);
        yieldStreaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(yieldStreaming.receiverTotalShares(bob), (shares * 3) / 4, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalShares(carol), shares / 4, "receiver shares carol");
    }

    /// *** #transfer *** ///

    function test_transfer() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVault(alice, principal);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.open(bob, shares, 0);

        _generateYield(0.5e18);

        yieldStreaming.transferFrom(alice, carol, 1);
        vm.stopPrank();

        assertEq(yieldStreaming.balanceOf(alice), 0, "alice's nfts");
        assertEq(yieldStreaming.balanceOf(carol), 1, "carol's nfts");
        assertEq(yieldStreaming.ownerOf(1), carol, "owner");
        assertEq(yieldStreaming.previewClaimYield(bob), 1e18 / 2, "bob's yield");

        vm.prank(carol);
        yieldStreaming.close(1);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(carol)), principal, 1, "carol's assets");
        assertEq(yieldStreaming.balanceOf(carol), 0, "carol's nfts");
        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), 1e18 / 2, 1, "bob's yield");
    }

    /// *** #tokenUri *** ///

    function test_tokenUri_returnsEmptyString() public {
        _openYieldStream(alice, bob, 1e18);

        assertEq(yieldStreaming.tokenURI(1), "", "token uri not empty");
    }

    /// *** #supportsInterface *** ///

    function test_supportsInterface() public {
        assertTrue(yieldStreaming.supportsInterface(type(IERC721).interfaceId), "IERC721");
        assertTrue(yieldStreaming.supportsInterface(type(IERC721Metadata).interfaceId), "IERC721Metadata");
        assertTrue(yieldStreaming.supportsInterface(type(IERC165).interfaceId), "IERC165");

        assertTrue(!yieldStreaming.supportsInterface(type(IERC721Receiver).interfaceId), "IERC721Receiver");
    }

    /// *** fuzzing *** ///

    function testFuzz_open_claim_close_stream(uint256 _principal) public {
        _principal = bound(_principal, 10000, 1000 ether);
        uint256 shares = _depositToVault(alice, _principal);
        _approveYieldStreaming(alice, shares);
        vm.startPrank(alice);

        // open 10 streams
        uint256 sharesToOpen = shares / 10;
        address[] memory receivers = new address[](10);
        uint256[] memory streamIds = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            // generate random receiver address
            receivers[i] = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp + i, block.prevrandao)))));
            streamIds[i] = yieldStreaming.open(receivers[i], sharesToOpen, 0);
        }

        vm.stopPrank();

        _generateYield(0.5e18);

        uint256 expectedYield = _principal.mulDivDown(0.5e18, 10e18);

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
            yieldStreaming.close(streamIds[i]);
        }

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), _principal, 0.005e18, "alice's principal");
        assertEq(vault.balanceOf(address(yieldStreaming)), 0, "contract's shares");
    }

    /// *** helpers *** ///

    function _depositToVaultAndApprove(address _from, uint256 _amount) internal returns (uint256 shares) {
        shares = _depositToVault(_from, _amount);
        _approveYieldStreaming(_from, shares);
    }

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        shares = _depositToVault(IERC4626(address(vault)), _from, _amount);
    }

    function _approveYieldStreaming(address _from, uint256 _shares) internal {
        _approve(IERC4626(address(vault)), address(yieldStreaming), _from, _shares);
    }

    function _approveAssetsAndPreviewDeposit(address _owner, uint256 _amount) private returns (uint256 shares) {
        deal(address(asset), _owner, _amount);

        vm.prank(_owner);
        asset.approve(address(yieldStreaming), _amount);

        shares = vault.previewDeposit(_amount);
    }

    function _generateYield(int256 _yield) internal {
        _generateYield(IERC4626(address(vault)), _yield);
    }

    function _openYieldStream(address _from, address _to, uint256 _amount) internal returns (uint256 streamId) {
        uint256 shares = _depositToVault(_from, _amount);
        _approveYieldStreaming(_from, shares);

        vm.prank(_from);
        streamId = yieldStreaming.open(_to, shares, 0);
    }
}
