// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC721Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldStreaming} from "../src/YieldStreaming.sol";
import "../src/common/Errors.sol";

contract YieldStreamingTests is Test {
    using FixedPointMathLib for uint256;

    event OpenYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event TopUpYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event CloseYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
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

    // *** #openYieldStream ***

    function test_openYieldStream_failsOpeningStreamToSelf() public {
        uint256 amount = 10e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(CannotOpenStreamToSelf.selector);
        yieldStreaming.openYieldStream(alice, shares, 0);
    }

    function test_openYieldStream_failsFor0Shares() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(AmountZero.selector);
        yieldStreaming.openYieldStream(bob, 0, 0);
    }

    function test_openYieldStream_failsIfReceiverIsAddress0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        vm.expectRevert(AddressZero.selector);
        yieldStreaming.openYieldStream(address(0), shares, 0);
    }

    function test_openYieldStream_mintsNtfAndTransfersShares() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        uint256 streamHubShares = vault.balanceOf(address(yieldStreaming));
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        assertEq(tokenId, 1, "token id");
        assertEq(yieldStreaming.nextTokenId(), 2, "next token id");
        assertEq(yieldStreaming.ownerOf(tokenId), alice, "owner of token");
        assertEq(yieldStreaming.balanceOf(alice), 1, "nft balance of alice");

        assertEq(vault.balanceOf(address(yieldStreaming)), streamHubShares + shares, "streamHub shares");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), amount, "receiver principal");
    }

    function test_openYieldStream_emitsEvent() public {
        uint256 amount = 4e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        uint256 tokenId = yieldStreaming.nextTokenId();

        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit OpenYieldStream(tokenId, alice, bob, shares, amount);

        yieldStreaming.openYieldStream(bob, shares, 0);
    }

    function test_openYieldStream_toTwoAccountsAtTheSameTime() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 firstId = yieldStreaming.openYieldStream(bob, shares / 2, 0);
        uint256 secondId = yieldStreaming.openYieldStream(carol, shares / 4, 0);

        assertEq(firstId, 1, "first id");
        assertEq(secondId, 2, "second id");
        assertEq(yieldStreaming.nextTokenId(), 3, "next token id");

        assertEq(vault.balanceOf(alice), shares / 4, "alice's shares");

        assertEq(yieldStreaming.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), amount / 2, "receiver principal  bob");

        assertEq(yieldStreaming.receiverShares(carol), shares / 4, "receiver shares carol");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), amount / 4, "principal carol");
        assertEq(yieldStreaming.receiverPrincipal(carol, 2), amount / 4, "receiver principal  carol");
    }

    function test_openYieldStream_failsIfClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveYieldStreaming(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares, 0);

        // create 10% loss
        _createProfitForVault(-0.1e18);
        assertEq(yieldStreaming.debtFor(carol), 0.1e18, "debt for carol");

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
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
        yieldStreaming.openYieldStream(carol, bobsShares, toleratedLossOnOpenPct);
    }

    function test_openYieldStream_worksIfClaimerIsInDebtAndLossIsBelowLossTolerancePercent() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveYieldStreaming(alice, alicesShares);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares, 0);

        // create 10% loss
        _createProfitForVault(-0.1e18);
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
        yieldStreaming.openYieldStream(carol, bobsShares, toleratedLossOnOpenPct);

        uint256 principalWithLoss = vault.convertToAssets(yieldStreaming.previewCloseYieldStream(2));
        uint256 bobsLossOnOpen = bobsPrincipal - principalWithLoss;

        assertTrue(principalWithLoss < bobsPrincipal, "principal with loss > bobs deposit");
        assertApproxEqRel(principalWithLoss, bobsPrincipal, toleratedLossOnOpenPct, "principal with loss");
        assertTrue(bobsLossOnOpen < bobsPrincipal.mulWadDown(toleratedLossOnOpenPct), "loss tolerance exceeded");

        vm.prank(bob);
        yieldStreaming.closeYieldStream(2);

        uint256 bobsPrincipalAfterClose = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobsPrincipalAfterClose, bobsPrincipal - bobsLossOnOpen, 1, "bobs principal after close");
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
        uint256 tokenId = yieldStreaming.openYieldStreamUsingPermit(bob, shares, 0, deadline, v, r, s);

        assertEq(tokenId, 1, "token id");
        assertEq(vault.balanceOf(address(yieldStreaming)), shares, "streamHub shares");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), amount, "receiver principal");
    }

    // *** #topUpYieldStream *** ///

    function test_topUpYieldStream_failsIfAmountIs0() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        vm.expectRevert(AmountZero.selector);
        yieldStreaming.topUpYieldStream(0, tokenId);
    }

    function test_topUpYieldStream_failsIfStreamDoesntExist() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        uint256 invalidTokenId = 2;

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, invalidTokenId));
        yieldStreaming.topUpYieldStream(1, invalidTokenId);
    }

    function test_topUpYieldStream_failsIfCallerIsNotOwner() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        shares = _depositToVault(bob, 1e18);
        _approveYieldStreaming(bob, shares);

        vm.startPrank(bob);
        vm.expectRevert(YieldStreaming.CallerNotOwner.selector);
        yieldStreaming.topUpYieldStream(1, tokenId);
    }

    function test_topUpYieldStream_addsToExistingStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares / 2, 0);

        assertEq(yieldStreaming.receiverShares(bob), shares / 2, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount / 2, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, tokenId), amount / 2, "receiver principal  bob");

        // top up stream
        yieldStreaming.topUpYieldStream(shares / 2, tokenId);

        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares bob");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "principal bob");
        assertEq(yieldStreaming.receiverPrincipal(bob, tokenId), amount, "receiver principal  bob");
    }

    function test_topUpYieldStream_emitsEvent() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares / 2, 0);

        vm.expectEmit(true, true, true, true);
        emit TopUpYieldStream(tokenId, alice, bob, shares / 2, amount / 2);

        yieldStreaming.topUpYieldStream(shares / 2, tokenId);
    }

    function test_topUpYieldStream_doesntAffectYieldAccrued() public {
        uint256 shares = _depositToVault(alice, 2e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2, 0);

        _createProfitForVault(0.2e18);
        uint256 yield = yieldStreaming.previewClaimYield(bob);

        assertEq(yieldStreaming.previewClaimYield(bob), yield, "yield before top up");

        // top up stream
        yieldStreaming.openYieldStream(bob, shares / 2, 0);

        assertEq(yieldStreaming.previewClaimYield(bob), yield, "yield after top up");
    }

    function test_topUpYieldStream_affectsFutureYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares / 2, 0);

        // double the share price
        _createProfitForVault(1e18);

        assertEq(yieldStreaming.previewClaimYield(bob), amount / 2, "yield before top up");

        // top up stream with the remaining shares
        yieldStreaming.topUpYieldStream(shares / 2, tokenId);

        _createProfitForVault(0.5e18);

        // share price increased by 200% in total from the initial deposit
        // expected yield is 75% of that whole gain
        assertEq(yieldStreaming.previewClaimYield(bob), (amount * 2).mulWadUp(0.75e18), "yield after top up");
    }

    function test_topUpYieldStream_worksWhenClaimerIsInDebtAndLossIsAboveLossTolerancePercent() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2, 0);

        _createProfitForVault(-0.5e18);

        uint256 claimerDebt = yieldStreaming.debtFor(bob);

        // top up stream with the remaining shares
        yieldStreaming.topUpYieldStream(shares / 2, 1);

        assertEq(yieldStreaming.debtFor(bob), claimerDebt, "claimer debt");
        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
    }

    function test_topUpYieldStreamUsingPermit() public {
        uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
        address dave = vm.addr(davesPrivateKey);

        uint256 amount = 1 ether;
        uint256 shares = _depositToVault(dave, amount);

        _approveYieldStreaming(dave, shares / 2);

        vm.prank(dave);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares / 2, 0);

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
                    keccak256(abi.encode(PERMIT_TYPEHASH, dave, address(yieldStreaming), shares / 2, nonce, deadline))
                )
            )
        );

        // top up stream
        vm.prank(dave);
        yieldStreaming.topUpYieldStreamUsingPermit(shares / 2, tokenId, deadline, v, r, s);

        assertEq(yieldStreaming.receiverShares(bob), shares, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), amount, "receiver total principal");
        assertEq(yieldStreaming.receiverPrincipal(bob, tokenId), amount, "receiver principal");
    }

    // *** #previewClaimYield *** ///

    function test_previewClaimYield_returns0IfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returns0IfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        // no share price increase => no yield
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "yield");
    }

    function test_previewClaimYield_returnsGeneratedYield() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 previewClaimYield2 = yieldStreaming.previewClaimYield(bob);

        assertEq(previewClaimYield2, amount / 2, "bob's yield");
    }

    function test_previewClaimYield_returnsGeneratedYieldIfStreamIsClosed() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yieldFor = yieldStreaming.previewClaimYield(bob);
        uint256 alicesBalance = vault.balanceOf(alice);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(alicesBalance, 0, "alice's shares");

        yieldStreaming.closeYieldStream(1);

        assertEq(yieldFor, amount / 2, "bob's yield");
        assertEq(vault.balanceOf(alice), vault.convertToShares(amount), "alice's shares");
    }

    function test_previewClaimYield_returns0AfterClaimAndCloseStream() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        // depositor opens a stream to himself
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        yieldStreaming.closeYieldStream(1);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
    }

    // *** #claimYield *** ///

    function test_claimYield_toClaimerAccount() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.prank(bob);
        uint256 claimed = yieldStreaming.claimYield(carol);

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertApproxEqAbs(asset.balanceOf(carol), claimed, 1, "carol's assets");
    }

    function test_claimYield_emitsEvent() public {
        uint256 shares = _depositToVault(alice, 3e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(address(0));
    }

    function test_claimYield_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYield_claimsFromAllOpenedStreams() public {
        uint256 amount1 = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount1);
        _approveYieldStreaming(alice, alicesShares);
        uint256 amount2 = 3e18;
        uint256 bobsShares = _depositToVault(bob, amount2);
        _approveYieldStreaming(bob, bobsShares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares, 0);
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

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
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        vm.expectRevert(AddressZero.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(address(0));
    }

    function test_claimYieldInShares_revertsIfNoYield() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield != 0");

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYieldInShares(bob);
    }

    function test_claimYieldInShares_revertsIfVaultMadeLosses() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        vm.expectRevert(YieldStreaming.NoYieldToClaim.selector);
        vm.prank(bob);
        yieldStreaming.claimYield(bob);
    }

    function test_claimYieldInShares_claimsFromAllOpenedStreams() public {
        uint256 amount1 = 1e18;
        uint256 alicesShares = _depositToVault(alice, amount1);
        _approveYieldStreaming(alice, alicesShares);
        uint256 amount2 = 3e18;
        uint256 bobsShares = _depositToVault(bob, amount2);
        _approveYieldStreaming(bob, bobsShares);

        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares, 0);
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares, 0);

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

    function test_closeYieldStream_failsIfCallerIsNotOwner() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        shares = _depositToVault(bob, 1e18);
        _approveYieldStreaming(bob, shares);

        vm.startPrank(bob);

        vm.expectRevert(YieldStreaming.CallerNotOwner.selector);
        yieldStreaming.closeYieldStream(tokenId);
    }

    function test_closeYieldStream_burnsNftAndReturnsPrincipal() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        assertEq(yieldStreaming.balanceOf(alice), 1, "alice's nfts before");

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 yieldValueInShares = vault.convertToShares(yield);
        uint256 principal = yieldStreaming.getPrincipal(tokenId);

        uint256 sharesReturned = yieldStreaming.closeYieldStream(tokenId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        yieldStreaming.ownerOf(tokenId);
        assertEq(yieldStreaming.balanceOf(alice), 0, "alice's nfts after");
        assertEq(yieldStreaming.receiverPrincipal(bob, tokenId), 0, "receiver principal");

        assertApproxEqAbs(sharesReturned, shares - yieldValueInShares, 1, "shares returned");
        assertEq(vault.balanceOf(alice), sharesReturned, "alice's shares");
        assertApproxEqAbs(vault.convertToAssets(sharesReturned), principal, 1, "alices principal");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
    }

    function test_closeYieldStream_emitsEvent() public {
        uint256 principal = 2e18;
        uint256 shares = _depositToVault(alice, principal);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        // add 100% profit to vault
        _createProfitForVault(1e18);

        uint256 yield = yieldStreaming.previewClaimYield(bob);
        uint256 unlockedShares = shares - vault.convertToShares(yield);

        vm.expectEmit(true, true, true, true);
        emit CloseYieldStream(tokenId, alice, bob, unlockedShares, principal);

        yieldStreaming.closeYieldStream(1);
    }

    function test_closeYieldStream_continuesGeneratingYieldForReceiverUntilClaimed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // add 50% profit to vault
        _createProfitForVault(0.5e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);

        yieldStreaming.closeYieldStream(1);
        vm.stopPrank();

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), bobsYield, 1, "bob's yield after close");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after close");

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        uint256 expectedYield = bobsYield + bobsYield.mulWadUp(0.5e18);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), expectedYield, 1, "bob's yield after profit");
        assertEq(asset.balanceOf(bob), 0, "bob's assets after profit");

        vm.prank(bob);
        yieldStreaming.claimYield(bob);

        assertApproxEqAbs(asset.balanceOf(bob), expectedYield, 1, "bob's assets after claim");

        // add 50% profit to vault again
        _createProfitForVault(0.5e18);

        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield after new profit");
    }

    function test_closeYieldStream_worksIfVaultMadeLosses() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        // create a 20% loss
        _createProfitForVault(-0.2e18);

        yieldStreaming.closeYieldStream(1);

        assertEq(vault.convertToAssets(shares), amount.mulWadUp(0.8e18), "shares value");
        assertEq(yieldStreaming.previewClaimYield(bob), 0, "bob's yield");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(vault.balanceOf(alice), shares, "alice's shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets");
        assertEq(yieldStreaming.receiverPrincipal(bob, 1), 0, "receiver principal");
        assertEq(yieldStreaming.receiverShares(bob), 0, "receiver shares");
        assertEq(yieldStreaming.receiverTotalPrincipal(bob), 0, "receiver total principal");
    }

    function test_closeYieldStream_failsIfStreamIsAlreadyClosed() public {
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        uint256 tokenId = yieldStreaming.openYieldStream(bob, shares, 0);

        // works
        yieldStreaming.closeYieldStream(tokenId);

        // fails
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        yieldStreaming.closeYieldStream(tokenId);
    }

    function test_closeYieldStream_doesntAffectOtherStreamsFromTheSameStreamer() public {
        uint256 amount = 1e18;
        uint256 shares = _depositToVault(alice, 1e18);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares / 2, 0);
        yieldStreaming.openYieldStream(carol, shares / 2, 0);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        uint256 bobsYield = yieldStreaming.previewClaimYield(bob);
        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        assertTrue(bobsYield > 0, "bob's yield = 0");
        assertTrue(carolsYield > 0, "carol's yield = 0");
        assertEq(vault.balanceOf(alice), 0, "alice's shares != 0");

        yieldStreaming.closeYieldStream(1);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), amount / 2, 1, "alice's principal");
        assertEq(asset.balanceOf(bob), 0, "bob's assets");
        assertEq(yieldStreaming.previewClaimYield(bob), bobsYield, "bob's yield");
        assertEq(asset.balanceOf(carol), 0, "carol's assets");
        assertEq(yieldStreaming.previewClaimYield(carol), carolsYield, "carol's yield");
    }

    function test_closeYieldStream_doesntAffectOtherStreamFromTheAnotherStreamer() public {
        uint256 alicesDeposit = 1e18;
        uint256 alicesShares = _depositToVault(alice, alicesDeposit);
        _approveYieldStreaming(alice, alicesShares);

        uint256 bobsDeposit = 2e18;
        uint256 bobsShares = _depositToVault(bob, bobsDeposit);
        _approveYieldStreaming(bob, bobsShares);

        // alice opens a stream to carol
        vm.prank(alice);
        yieldStreaming.openYieldStream(carol, alicesShares, 0);

        // bob opens a stream to carol
        vm.prank(bob);
        yieldStreaming.openYieldStream(carol, bobsShares, 0);

        // create a 20% profit
        _createProfitForVault(0.2e18);

        assertEq(yieldStreaming.receiverTotalPrincipal(carol), alicesDeposit + bobsDeposit, "carol's total principal");

        uint256 carolsYield = yieldStreaming.previewClaimYield(carol);

        vm.prank(alice);
        yieldStreaming.closeYieldStream(1);

        assertApproxEqAbs(yieldStreaming.previewClaimYield(carol), carolsYield, 1, "carol's yield");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), alicesDeposit, 2, "alice's shares value");
        assertEq(yieldStreaming.receiverPrincipal(carol, 1), 0, "alice's principal");
        assertEq(yieldStreaming.receiverPrincipal(carol, 2), bobsDeposit, "bob's principal");
        assertEq(yieldStreaming.receiverTotalPrincipal(carol), bobsDeposit, "carol's total principal");
    }

    function test_previewCloseYieldStream_returns0IfTokenDoesntExist() public {
        assertEq(yieldStreaming.previewCloseYieldStream(1), 0);
    }

    // *** #multicall *** ///

    function test_multicall_OpenMultipleYieldStreams() public {
        uint256 shares = _depositToVault(alice, 1e18);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(YieldStreaming.openYieldStream.selector, bob, (shares * 3) / 4, 0);
        data[1] = abi.encodeWithSelector(YieldStreaming.openYieldStream.selector, carol, shares / 4, 0);

        vm.startPrank(alice);
        vault.approve(address(yieldStreaming), shares);
        yieldStreaming.multicall(data);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's shares");
        assertEq(yieldStreaming.receiverShares(bob), (shares * 3) / 4, "receiver shares bob");
        assertEq(yieldStreaming.receiverShares(carol), shares / 4, "receiver shares carol");
    }

    // *** #transfer *** ///

    function test_transfer() public {
        uint256 principal = 1e18;
        uint256 shares = _depositToVault(alice, principal);
        _approveYieldStreaming(alice, shares);

        vm.startPrank(alice);
        yieldStreaming.openYieldStream(bob, shares, 0);

        _createProfitForVault(0.5e18);

        yieldStreaming.transferFrom(alice, carol, 1);
        vm.stopPrank();

        assertEq(yieldStreaming.balanceOf(alice), 0, "alice's nfts");
        assertEq(yieldStreaming.balanceOf(carol), 1, "carol's nfts");
        assertEq(yieldStreaming.ownerOf(1), carol, "owner");
        assertEq(yieldStreaming.previewClaimYield(bob), 1e18 / 2, "bob's yield");

        vm.prank(carol);
        yieldStreaming.closeYieldStream(1);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(carol)), principal, 1, "carol's assets");
        assertEq(yieldStreaming.balanceOf(carol), 0, "carol's nfts");
        assertApproxEqAbs(yieldStreaming.previewClaimYield(bob), 1e18 / 2, 1, "bob's yield");
    }

    /// *** fuzzing *** ///

    function testFuzz_open_claim_close_stream(uint256 amount) public {
        amount = bound(amount, 10000, 1000 ether);
        uint256 shares = _depositToVault(alice, amount);
        _approveYieldStreaming(alice, shares);
        vm.startPrank(alice);

        // open 10 streams
        uint256 sharesToOpen = shares / 10;
        address[] memory receivers = new address[](10);
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            // generate random receiver address
            receivers[i] = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp + i, block.prevrandao)))));
            tokenIds[i] = yieldStreaming.openYieldStream(receivers[i], sharesToOpen, 0);
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
            yieldStreaming.closeYieldStream(tokenIds[i]);
        }

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), amount, 0.005e18, "alice's principal");
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

    function _approveYieldStreaming(address _from, uint256 _shares) internal {
        vm.prank(_from);
        vault.approve(address(yieldStreaming), _shares);
    }

    function _openYieldStream(address _from, address _to, uint256 _amount) internal returns (uint256 tokenId) {
        uint256 shares = _depositToVault(_from, _amount);
        _approveYieldStreaming(_from, shares);

        vm.prank(_from);
        return yieldStreaming.openYieldStream(_to, shares, 0);
    }

    function _createProfitForVault(int256 _profit) internal {
        deal(address(asset), address(vault), vault.totalAssets().mulWadDown(uint256(1e18 + _profit)));
    }
}
