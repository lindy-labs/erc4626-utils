// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import "src/common/CommonErrors.sol";
import {YieldDCABase} from "src/YieldDCABase.sol";
import {YieldDCAControlled} from "src/YieldDCAControlled.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {SwapperMock, MaliciousSwapper} from "./mock/SwapperMock.sol";
import {NFTHolderMock} from "./mock/NFTHolderMock.sol";
import {TestCommon} from "./common/TestCommon.sol";

contract YieldDCATest is TestCommon {
    using FixedPointMathLib for uint256;

    event PositionOpened(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionIncreased(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionReduced(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionClosed(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal,
        uint256 dcaBalance
    );
    event DCABalanceClaimed(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 amount,
        address to
    );

    event EpochDurationUpdated(address indexed admin, uint32 oldDuration, uint32 newDuration);
    event MinYieldPerEpochUpdated(address indexed admin, uint64 oldMinYield, uint64 newMinYield);
    event SwapperUpdated(address indexed admin, address oldSwapper, address newSwapper);
    event DiscrepancyToleranceUpdated(address indexed admin, uint64 oldTolerance, uint64 newTolerance);
    event TokenCIDUpdated(address indexed caller, address indexed owner, uint256 indexed tokenId, string cid);

    event DCAExecuted(
        address indexed keeper,
        uint32 epoch,
        uint256 yieldSpent,
        uint256 dcaBought,
        uint128 dcaPrice,
        uint128 sharePrice
    );

    uint32 public constant DEFAULT_DCA_INTERVAL = 2 weeks;
    uint64 public constant DEFAULT_MIN_YIELD_PERCENT = 0.001e18; // 0.1%

    YieldDCAControlled yieldDca;
    MockERC20 asset;
    MockERC4626 vault;
    MockERC20 dcaToken;

    SwapperMock swapper;

    function setUp() public {
        asset = new MockERC20("Mock ERC20", "mERC20", 18);
        vault = new MockERC4626(asset, "Mock ERC4626", "mERC4626");
        dcaToken = new MockERC20("Mock DCA", "mDCA", 18);
        swapper = new SwapperMock();

        dcaToken.mint(address(swapper), type(uint128).max);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );

        // make initial deposit to the vault
        _depositToVault(IERC4626(address(vault)), address(this), 1e18);
        // double the vault funds so 1 share = 2 underlying asset
        deal(address(asset), address(vault), 2e18);
    }

    /*
     * --------------------
     *    #constructor
     * --------------------
     */

    function test_constructor_initialState() public {
        assertEq(address(yieldDca.dcaToken()), address(dcaToken), "dca token");
        assertEq(address(yieldDca.vault()), address(vault), "vault");
        assertEq(address(yieldDca.swapper()), address(swapper), "swapper");

        assertEq(yieldDca.currentEpoch(), 1, "current epoch");
        assertEq(yieldDca.currentEpochTimestamp(), block.timestamp, "current epoch timestamp");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
        assertEq(yieldDca.discrepancyTolerance(), 0.05e18, "default discrepancy tolerance");

        assertTrue(yieldDca.hasRole(yieldDca.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertTrue(yieldDca.hasRole(yieldDca.KEEPER_ROLE(), keeper), "keeper role");

        assertEq(asset.allowance(address(yieldDca), address(swapper)), type(uint256).max, "swapper allowance");
        assertEq(asset.allowance(address(yieldDca), address(vault)), type(uint256).max, "vault allowance");
    }

    function test_constructor_revertsIfDcaTokenZeroAddress() public {
        vm.expectRevert(YieldDCABase.DCATokenAddressZero.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(0)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );
    }

    function test_constructor_revertsIfVaultZeroAddress() public {
        vm.expectRevert(YieldDCABase.VaultAddressZero.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(0)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );
    }

    function test_constructor_revertsIfSwapperZeroAddress() public {
        vm.expectRevert(YieldDCAControlled.SwapperAddressZero.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            ISwapper(address(0)),
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );
    }

    function test_constructor_revertsIfMinYieldPercentOutOfBounds() public {
        uint64 aboveMax = yieldDca.MIN_YIELD_PER_EPOCH_UPPER_BOUND() + 1;

        vm.expectRevert(YieldDCABase.MinYieldPerEpochOutOfBounds.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            aboveMax,
            admin,
            keeper
        );
    }

    function test_constructor_revertsIfDCATokenSameAsVaultAsset() public {
        vm.expectRevert(YieldDCABase.DCATokenSameAsVaultAsset.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(asset)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );
    }

    function test_constructor_revertsIfKeeperIsZeroAddress() public {
        vm.expectRevert(YieldDCABase.KeeperAddressZero.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            address(0)
        );
    }

    function test_constructor_revertsIfAdminIsZeroAddress() public {
        vm.expectRevert(YieldDCABase.AdminAddressZero.selector);
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            address(0),
            keeper
        );
    }

    function test_constructor_setsNameAndSymbol() public {
        assertEq(yieldDca.name(), "Yield DCA - Mock ERC4626 / Mock DCA", "name");
        assertEq(yieldDca.symbol(), "yDCA-mERC4626/mDCA", "symbol");
    }

    /*
     * --------------------
     *  #supportsInterface
     * --------------------
     */

    function test_supportsInterface() public {
        assertTrue(yieldDca.supportsInterface(type(IERC721).interfaceId), "supports IERC721");

        assertTrue(!yieldDca.supportsInterface(type(IERC721Receiver).interfaceId), "shouldn't support IERC721Receiver");
    }

    /*
     * --------------------
     *     #setSwapper
     * --------------------
     */

    function test_setSwapper_failsIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setSwapper(ISwapper(address(0)));
    }

    function test_setSwapper_updatesSwapper() public {
        address newSwapper = address(0x03);

        vm.prank(admin);
        yieldDca.setSwapper(ISwapper(newSwapper));

        assertEq(address(yieldDca.swapper()), newSwapper);
        uint256 oldAllowance = asset.allowance(address(yieldDca), address(swapper));
        assertEq(oldAllowance, 0, "old allowance");
        uint256 newAllowance = asset.allowance(address(yieldDca), newSwapper);
        assertEq(newAllowance, type(uint256).max, "new allowance");
    }

    function test_setSwapper_emitsEvent() public {
        address newSwapper = address(0x03);
        address oldSwapper = address(yieldDca.swapper());

        vm.expectEmit(true, true, true, true);
        emit SwapperUpdated(admin, oldSwapper, newSwapper);

        vm.prank(admin);
        yieldDca.setSwapper(ISwapper(newSwapper));
    }

    function test_setSwapper_failsIfNewSwapperIsZeroAddress() public {
        vm.expectRevert(YieldDCAControlled.SwapperAddressZero.selector);
        vm.prank(admin);
        yieldDca.setSwapper(ISwapper(address(0)));
    }

    function test_setSwapper_newSwapperWorks() public {
        _openPositionWithPrincipal(alice, 1 ether);

        // generate 50% yield
        _generateYield(0.5e18);

        // change the swapper
        SwapperMock newSwapper = new SwapperMock();
        dcaToken.mint(address(newSwapper), 10000 ether);

        vm.prank(admin);
        yieldDca.setSwapper(newSwapper);

        // dca - buy 1 DCA tokens for 0.5 yield
        newSwapper.setExchangeRate(2e18);
        _shiftTime(yieldDca.epochDuration());

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");

        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), 1e18, 5, "dca token balance");
    }

    /*
     * --------------------
     *  #setEpochDuration
     * --------------------
     */

    function test_setEpochDuration_failsIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setEpochDuration(1 weeks);
    }

    function test_setEpochDuration_updatesEpochDuration() public {
        uint32 newDuration = 1 weeks;
        assertTrue(yieldDca.epochDuration() != newDuration, "old and new duration should be different");

        vm.prank(admin);
        yieldDca.setEpochDuration(newDuration);

        assertEq(yieldDca.epochDuration(), newDuration);
    }

    function test_setEpochDuration_emitsEvent() public {
        uint32 newDuration = 3 weeks;
        uint32 oldDuration = yieldDca.epochDuration();

        assertTrue(oldDuration != newDuration, "old and new duration should be different");

        vm.expectEmit(true, true, true, true);
        emit EpochDurationUpdated(admin, oldDuration, newDuration);

        vm.prank(admin);
        yieldDca.setEpochDuration(newDuration);
    }

    function test_setEpochDuration_failsIfBelowLowerBound() public {
        uint32 invalidDuration = yieldDca.EPOCH_DURATION_LOWER_BOUND() - 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCABase.EpochDurationOutOfBounds.selector);
        yieldDca.setEpochDuration(invalidDuration);
    }

    function test_setEpochDuration_failsIfAboveUpperBound() public {
        uint32 invalidDuration = yieldDca.EPOCH_DURATION_UPPER_BOUND() + 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCABase.EpochDurationOutOfBounds.selector);
        yieldDca.setEpochDuration(invalidDuration);
    }

    /*
     * --------------------
     *  #setMinYieldPerEpoch
     * --------------------
     */

    function test_setMinYieldPerEpoch_failsIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setMinYieldPerEpoch(1e18);
    }

    function test_setMinYieldPerEpoch_updatesMinYieldPerEpoch() public {
        uint64 newYield = 0.005e18;

        vm.prank(admin);
        yieldDca.setMinYieldPerEpoch(newYield);

        assertEq(yieldDca.minYieldPerEpoch(), newYield);
    }

    function test_setMinYieldPerEpoch_failsIfAboveUpperBound() public {
        uint64 aboveMax = yieldDca.MIN_YIELD_PER_EPOCH_UPPER_BOUND() + 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCABase.MinYieldPerEpochOutOfBounds.selector);
        yieldDca.setMinYieldPerEpoch(aboveMax);
    }

    function test_setMinYieldPerEpoch_emitsEvent() public {
        uint64 newYield = 0.01e18;
        uint64 oldYield = yieldDca.minYieldPerEpoch();

        vm.expectEmit(true, true, true, true);
        emit MinYieldPerEpochUpdated(admin, oldYield, newYield);

        vm.prank(admin);
        yieldDca.setMinYieldPerEpoch(newYield);
    }

    /*
     * --------------------
     *  #setDiscrepancyTolerance
     * --------------------
     */

    function test_setDiscrepancyTolerance_failsIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setDiscrepancyTolerance(1e18);
    }

    function test_setDiscrepancyTolerance_updatesDiscrepancyTolerance() public {
        uint64 newTolerance = 0.005e18;

        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(newTolerance);

        assertEq(yieldDca.discrepancyTolerance(), newTolerance);
    }

    function test_setDiscrepancyTolerance_failsIfAboveUpperBound() public {
        uint64 aboveMax = yieldDca.DISCREPANCY_TOLERANCE_UPPER_BOUND() + 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCABase.DiscrepancyToleranceOutOfBounds.selector);
        yieldDca.setDiscrepancyTolerance(aboveMax);
    }

    function test_setDiscrepancyTolerance_emitsEvent() public {
        uint64 newTolerance = 0.01e18;
        uint64 oldTolerance = yieldDca.discrepancyTolerance();

        vm.expectEmit(true, true, true, true);
        emit DiscrepancyToleranceUpdated(admin, oldTolerance, newTolerance);

        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(newTolerance);
    }

    /*
     * --------------------
     *    #openPosition
     * --------------------
     */

    function test_openPosition_failsIfAmountIsZero() public {
        _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(CommonErrors.ZeroAmount.selector);
        yieldDca.openPosition(alice, 0);
    }

    function test_openPosition_failsIfProvidedOwnerIsZeroAddress() public {
        _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        yieldDca.openPosition(address(0), 1 ether);
    }

    function test_openPosition_transfersSharesAndMintsPositionNft() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, principal);

        vm.prank(alice);
        uint256 positionId = yieldDca.openPosition(alice, shares);

        assertEq(positionId, 1, "token id");
        assertEq(yieldDca.ownerOf(positionId), alice, "owner");
        assertEq(yieldDca.balanceOf(alice), 1, "nft balance of");

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(balance, shares, "alice's contract balance");
        assertEq(dcaBalance, 0, "alice's contract dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "contract's total principal");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_openPosition_correctlyMintsNftsForDifferentUsers() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        uint256 positionId = yieldDca.openPosition(alice, shares);

        assertEq(positionId, 1, "alice's token id");
        assertEq(yieldDca.ownerOf(positionId), alice, "owner of alice's token");
        (uint256 sharesBalance,) = yieldDca.balancesOf(positionId);
        assertEq(shares, sharesBalance, "alice's contract balance");

        uint256 bobPrincipal = 2 ether;
        uint256 bobShares = _depositToVaultAndApproveYieldDca(bob, bobPrincipal);

        vm.prank(bob);
        positionId = yieldDca.openPosition(bob, bobShares);

        assertEq(positionId, 2, "bob's token id");
        assertEq(yieldDca.ownerOf(positionId), bob, "owner of bob's token");
        (sharesBalance,) = yieldDca.balancesOf(positionId);
        assertEq(bobShares, sharesBalance, "bob's contract balance");
    }

    function test_openPosition_oneUserCanOpenMultiplePositions() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        uint256 positionId = yieldDca.openPosition(alice, shares);

        assertEq(positionId, 1, "token id");
        assertEq(yieldDca.ownerOf(positionId), alice, "owner");

        uint256 secondShares = _depositToVaultAndApproveYieldDca(alice, 2 ether);

        vm.prank(alice);
        positionId = yieldDca.openPosition(alice, secondShares);

        assertEq(positionId, 2, "2nd token id");
        assertEq(yieldDca.ownerOf(positionId), alice, "2nd owner");
    }

    function test_openPosition_mintsNftToProvidedOwner() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        uint256 positionId = yieldDca.openPosition(bob, shares);

        assertEq(positionId, 1, "token id");
        assertEq(yieldDca.ownerOf(positionId), bob, "owner");
    }

    function test_openPosition_failsIfOwnerIsContractAndDoesNotImplementIERC721Receiver() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1 ether);

        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        vm.prank(alice);
        yieldDca.openPosition(address(this), shares);
    }

    function test_openPosition_worksIfOwnerIsContractAndImplementsIERC721Receiver() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1 ether);
        address nftHolder = address(new NFTHolderMock());

        vm.prank(alice);
        yieldDca.openPosition(nftHolder, shares);

        assertTrue(yieldDca.ownerOf(1) == nftHolder, "nft holder should be the owner");
    }

    function test_openPosition_emitsEvent() public {
        // open one position just to increment the position id counter
        _openPositionWithPrincipal(alice, 2 ether);

        uint256 principal = 1 ether;
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, principal);

        uint256 nextPositionId = yieldDca.nextPositionId();
        assertEq(nextPositionId, 2, "next position id");

        vm.expectEmit(true, true, true, true);
        emit PositionOpened(alice, bob, nextPositionId, yieldDca.currentEpoch(), shares, principal);

        vm.prank(alice);
        yieldDca.openPosition(bob, shares);

        assertEq(yieldDca.balanceOf(alice), 1, "alice's position count");
        assertEq(yieldDca.balanceOf(bob), 1, "bob's position count");
    }

    /*
     * --------------------
     *  #openPositionUsingPermit
     * --------------------
     */

    function test_openPositionUsingPermit() public {
        uint256 shares = _depositToVault(dave, 1 ether);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(vault), address(yieldDca), shares, deadline);

        vm.prank(dave);
        uint256 positionId = yieldDca.openPositionUsingPermit(dave, shares, deadline, v, r, s);

        assertEq(positionId, 1, "position id");
        assertEq(yieldDca.nextPositionId(), 2, "next position id");

        assertEq(yieldDca.ownerOf(positionId), dave, "nft owner");
        assertEq(yieldDca.balanceOf(dave), 1, "dave's nft balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, shares, "balance");
        assertEq(dcaBalance, 0, "dca balance");

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");
    }

    function test_openPositionUsingPermit_mintsNftToProvidedOwner() public {
        uint256 shares = _depositToVault(dave, 1 ether);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(vault), address(yieldDca), shares, deadline);

        vm.prank(dave);
        uint256 positionId = yieldDca.openPositionUsingPermit(bob, shares, deadline, v, r, s);

        assertEq(positionId, 1, "position id");
        assertEq(yieldDca.ownerOf(positionId), bob, "owner");
    }

    /*
     * --------------------
     *  #depositAndOpenPosition
     * --------------------
     */

    function test_depositAndOpenPosition_failsIfAmountZero() public {
        _assetDealAndApproveYieldDca(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(CommonErrors.ZeroAmount.selector);
        yieldDca.depositAndOpenPosition(alice, 0);
    }

    function test_depositAndOpenPosition_depositsAssetsAndMintsPositionNft() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.previewDeposit(principal);
        _assetDealAndApproveYieldDca(alice, principal);

        vm.prank(alice);
        uint256 positionId = yieldDca.depositAndOpenPosition(alice, principal);

        assertEq(positionId, 1, "token id");
        assertEq(yieldDca.ownerOf(positionId), alice, "owner");
        assertEq(yieldDca.balanceOf(alice), 1, "nft balance of");

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(balance, shares, "alice's contract balance");
        assertEq(dcaBalance, 0, "alice's contract dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "contract's total principal");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_depositAndOpenPosition_emitsEvent() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.previewDeposit(principal);
        _assetDealAndApproveYieldDca(alice, principal);

        vm.expectEmit(true, true, true, true);
        emit PositionOpened(alice, alice, yieldDca.nextPositionId(), yieldDca.currentEpoch(), shares, principal);

        vm.prank(alice);
        yieldDca.depositAndOpenPosition(alice, principal);
    }

    function test_depositAndOpenPosition_mintsNftToProvidedOwner() public {
        uint256 principal = 1 ether;
        _assetDealAndApproveYieldDca(alice, principal);

        vm.prank(alice);
        uint256 positionId = yieldDca.depositAndOpenPosition(bob, principal);

        assertEq(positionId, 1, "token id");
        assertEq(yieldDca.ownerOf(positionId), bob, "owner");
    }

    /*
     * --------------------
     *  #depositAndOpenPositionUsingPermit
     * --------------------
     */

    function test_depositAndOpenPositionUsingPermit() public {
        uint256 principal = 1 ether;
        deal(address(asset), dave, principal);
        uint256 shares = vault.previewDeposit(principal);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(asset), address(yieldDca), principal, deadline);

        vm.prank(dave);
        uint256 positionId = yieldDca.depositAndOpenPositionUsingPermit(dave, principal, deadline, v, r, s);

        assertEq(positionId, 1, "position id");
        assertEq(yieldDca.nextPositionId(), 2, "next position id");

        assertEq(yieldDca.ownerOf(positionId), dave, "nft owner");
        assertEq(yieldDca.balanceOf(dave), 1, "dave's nft balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, shares, "balance");
        assertEq(dcaBalance, 0, "dca balance");

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");
        assertEq(yieldDca.totalPrincipal(), principal, "total principal");
    }

    function test_depositAndOpenPositionUsingPermit_mintsNftToProvidedOwner() public {
        uint256 principal = 1 ether;
        deal(address(asset), dave, principal);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(asset), address(yieldDca), principal, deadline);

        vm.prank(dave);
        uint256 positionId = yieldDca.depositAndOpenPositionUsingPermit(bob, principal, deadline, v, r, s);

        assertEq(positionId, 1, "position id");
        assertEq(yieldDca.ownerOf(positionId), bob, "owner");
    }

    /*
     * --------------------
     *  #increasePosition
     * --------------------
     */

    function test_increasePosition_failsIfNotOwnerOrApproved() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        vm.prank(bob);
        yieldDca.increasePosition(positionId, shares);
    }

    function test_increasePosition_failsIfAmountIsZero() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(CommonErrors.ZeroAmount.selector);
        vm.prank(alice);
        yieldDca.increasePosition(positionId, 0);
    }

    function test_increasePosition_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        uint256 topUpAmount = 2 ether;
        uint256 topUpShares = _depositToVaultAndApproveYieldDca(alice, topUpAmount);

        vm.prank(alice);
        yieldDca.approve(dave, positionId);

        vm.prank(dave);
        yieldDca.increasePosition(positionId, topUpShares);

        assertEq(vault.balanceOf(alice), 0, "alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares + topUpShares, "contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, shares + topUpShares, "alice's position balance");
        assertEq(dcaBalance, 0, "alice's position dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + topUpAmount, "total principal deposited");
    }

    function test_increasePosition_worksMultipleTimesInSameEpoch() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.convertToShares(principal);
        uint256 totalShares = shares;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // top up with same amount
        uint256 firstTopUp = 1 ether;
        shares = _depositToVaultAndApproveYieldDca(alice, firstTopUp);
        totalShares += shares;

        vm.prank(alice);
        yieldDca.increasePosition(positionId, shares);

        assertEq(vault.balanceOf(alice), 0, "1st: alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares * 2, "1st: contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp), "1st: alice's balance");
        assertEq(dcaBalance, 0, "1st: alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + firstTopUp, "1st: total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "1st: dca token balance");

        // topUp with different amount
        uint256 secondTopUp = 2 ether;
        shares = _depositToVaultAndApproveYieldDca(alice, secondTopUp);
        totalShares += shares;

        vm.prank(alice);
        yieldDca.increasePosition(positionId, shares);

        assertEq(vault.balanceOf(alice), 0, "2nd: alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), totalShares, "2nd: contract's vault balance");

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp + secondTopUp), "2nd: alice's balance");
        assertEq(dcaBalance, 0, "2nd: alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + firstTopUp + secondTopUp, "2nd: total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "2nd: dca token balance");
    }

    function test_increasePosition_worksMultipleTimesInDifferentEpochs() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // add 100% yield
        _generateYield(1e18);
        _executeDcaAtExchangeRate(1e18);

        uint256 expectedDcaAmount = 1 ether;

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal), "alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "alice's dca balance");

        uint256 firstTopUp = 3 ether;
        _increasePosition(alice, firstTopUp, positionId);

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp), "1st: alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "1st: alice's dca balance");

        _generateYield(0.5e18);
        _executeDcaAtExchangeRate(1e18);

        expectedDcaAmount += 2 ether;

        uint256 secondTopUp = 2 ether;
        _increasePosition(alice, secondTopUp, positionId);

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertApproxEqAbs(
            balance, vault.convertToShares(principal + firstTopUp + secondTopUp), 1, "2nd: alice's balance"
        );
        assertEq(dcaBalance, expectedDcaAmount, "2nd: alice's dca balance");
    }

    function test_increasePosition_emitsEvent() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(1e18);

        uint256 topUpAmount = 2 ether;
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, topUpAmount);

        vm.prank(alice);
        yieldDca.approve(bob, positionId);

        vm.expectEmit(true, true, true, true);
        emit PositionIncreased(bob, alice, positionId, yieldDca.currentEpoch(), shares, topUpAmount);

        vm.prank(bob);
        yieldDca.increasePosition(positionId, shares);
    }

    /*
     * --------------------
     *  #increasePositionUsingPermit
     * --------------------
     */

    function test_increasePositionUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 totalShares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(dave, principal);

        // top up with same amount
        uint256 shares = _depositToVault(dave, principal);
        totalShares += shares;
        assertEq(vault.balanceOf(dave), shares, "initial shares balance");

        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(vault), address(yieldDca), shares, deadline);

        vm.prank(dave);
        yieldDca.increasePositionUsingPermit(positionId, shares, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares * 2, "contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal * 2), "position balance");
        assertEq(dcaBalance, 0, "position dca balance");
        assertEq(yieldDca.totalPrincipal(), principal * 2, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance");
    }

    function test_increasePositionUsingPermit_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.previewDeposit(principal);
        uint256 positionId = _openPositionWithPrincipal(dave, principal);

        // top up with same amount
        uint256 topUpShares = _depositToVault(dave, principal);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(vault), address(yieldDca), topUpShares, deadline);

        vm.prank(dave);
        yieldDca.approve(alice, positionId);

        vm.prank(alice);
        yieldDca.increasePositionUsingPermit(positionId, topUpShares, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares + topUpShares, "contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, shares + topUpShares, "position balance");
        assertEq(dcaBalance, 0, "position dca balance");
        assertEq(yieldDca.totalPrincipal(), principal * 2, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance");
    }

    /*
     * --------------------
     *  #depositAndIncreasePosition
     * --------------------
     */

    function test_depositAndIncreasePosition_failsIfNotOwnerOrApproved() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _assetDealAndApproveYieldDca(alice, 1 ether);

        assertFalse(yieldDca.isApprovedOrOwner(bob, positionId), "approved");

        vm.prank(bob);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        yieldDca.depositAndIncreasePosition(positionId, principal);
    }

    function test_depositAndIncreasePosition_failsIfAmountIsZero() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);
        _assetDealAndApproveYieldDca(alice, 1 ether);

        vm.expectRevert(CommonErrors.ZeroAmount.selector);
        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, 0);
    }

    function test_depositAndIncreasePosition_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        uint256 topUpAmount = 2 ether;
        uint256 totalShares = vault.convertToShares(principal + topUpAmount);
        _assetDealAndApproveYieldDca(alice, topUpAmount);

        // approve NFT to dave
        vm.prank(alice);
        yieldDca.approve(dave, positionId);

        vm.prank(dave);
        yieldDca.depositAndIncreasePosition(positionId, topUpAmount);

        assertEq(vault.balanceOf(alice), 0, "alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), totalShares, "contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, totalShares, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + topUpAmount, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance");
    }

    function test_depositAndIncreasePosition_worksMultipleTimesInSameEpoch() public {
        uint256 principal = 1 ether;
        uint256 totalShares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // top up with same amount
        uint256 firstTopUp = 1 ether;
        totalShares += vault.previewDeposit(firstTopUp);
        _assetDealAndApproveYieldDca(alice, firstTopUp);

        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, firstTopUp);

        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "1st: alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), totalShares, "1st: contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp), "1st: alice's balance");
        assertEq(dcaBalance, 0, "1st: alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + firstTopUp, "1st: total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "1st: dca token balance");

        // topUp with different amount
        uint256 secondTopUp = 2 ether;
        totalShares += vault.previewDeposit(secondTopUp);
        _assetDealAndApproveYieldDca(alice, secondTopUp);

        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, secondTopUp);

        assertEq(vault.balanceOf(alice), 0, "2nd: alice's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), totalShares, "2nd: contract's vault balance");

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp + secondTopUp), "2nd: alice's balance");
        assertEq(dcaBalance, 0, "2nd: alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + firstTopUp + secondTopUp, "2nd: total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "2nd: dca token balance");
    }

    function test_depositAndIncreasePosition_worksMultipleTimesInDifferentEpochs() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // add 100% yield
        uint256 expectedDcaAmount = 1 ether;
        _generateYield(1e18);
        _executeDcaAtExchangeRate(1e18);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal), "alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "alice's dca balance");

        uint256 firstTopUp = 3 ether;
        _assetDealAndApproveYieldDca(alice, firstTopUp);

        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, firstTopUp);

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + firstTopUp), "1st: alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "1st: alice's dca balance");

        expectedDcaAmount += 2 ether;
        _generateYield(0.5e18);
        _executeDcaAtExchangeRate(1e18);

        uint256 secondTopUp = 2 ether;
        _assetDealAndApproveYieldDca(alice, secondTopUp);

        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, secondTopUp);

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertApproxEqAbs(
            balance, vault.convertToShares(principal + firstTopUp + secondTopUp), 1, "2nd: alice's balance"
        );
        assertEq(dcaBalance, expectedDcaAmount, "2nd: alice's dca balance");
    }

    function test_depositAndIncreasePosition_emitsEvent() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(1e18);

        uint256 topUpAmount = 2 ether;
        uint256 shares = vault.previewDeposit(topUpAmount);
        _assetDealAndApproveYieldDca(alice, topUpAmount);

        vm.expectEmit(true, true, true, true);
        emit PositionIncreased(alice, alice, positionId, yieldDca.currentEpoch(), shares, topUpAmount);

        vm.prank(alice);
        yieldDca.depositAndIncreasePosition(positionId, topUpAmount);
    }

    /*
     * --------------------
     *  #depositAndIncreasePositionUsingPermit
     * --------------------
     */

    function test_depositAndIncreasePositionUsingPermit() public {
        uint256 principal = 1 ether;
        uint256 totalShares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(dave, principal);

        uint256 topUpAmount = 2 ether;
        totalShares += vault.previewDeposit(topUpAmount);
        deal(address(asset), dave, topUpAmount);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(asset), address(yieldDca), topUpAmount, deadline);
        vm.prank(dave);
        yieldDca.depositAndIncreasePositionUsingPermit(positionId, topUpAmount, deadline, v, r, s);

        assertEq(vault.balanceOf(dave), 0, "dave's vault balance");
        assertEq(vault.balanceOf(address(yieldDca)), totalShares, "contract's vault balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + topUpAmount), "position balance");
        assertEq(dcaBalance, 0, "position dca balance");
        assertEq(yieldDca.totalPrincipal(), principal + topUpAmount, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance");
        assertEq(asset.balanceOf(dave), 0, "dave's asset balance");
    }

    function test_depositAndIncreasePositionUsingPermit_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(dave, principal);

        uint256 topUpAmount = 2 ether;
        deal(address(asset), dave, topUpAmount);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(davesPrivateKey, address(asset), address(yieldDca), topUpAmount, deadline);

        vm.prank(dave);
        yieldDca.approve(alice, positionId);
        vm.prank(alice);
        yieldDca.depositAndIncreasePositionUsingPermit(positionId, topUpAmount, deadline, v, r, s);

        (uint256 balance,) = yieldDca.balancesOf(positionId);
        assertEq(balance, vault.convertToShares(principal + topUpAmount), "position balance");
        assertEq(yieldDca.totalPrincipal(), principal + topUpAmount, "total principal deposited");
    }

    /*
     * --------------------
     *    #canExecuteDCA
     * --------------------
     */

    function test_canExecuteDCA_revertsIfNotEnoughTimePassed() public {
        _openPositionWithPrincipal(alice, 1 ether);

        // shift time by less than min epoch duration
        _shiftTime(yieldDca.epochDuration() - 1);

        vm.expectRevert(YieldDCABase.EpochDurationNotReached.selector);
        yieldDca.canExecuteDCA();
    }

    function test_canExecuteDCA_revertIfNoYieldGenerated() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        vm.expectRevert(YieldDCABase.NoYield.selector);
        yieldDca.canExecuteDCA();
    }

    function test_canExecuteDCA_revertsIfYieldIsBelowMin() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        _generateYield(int256(uint256(yieldDca.minYieldPerEpoch() - 2)));

        vm.expectRevert(YieldDCABase.InsufficientYield.selector);
        yieldDca.canExecuteDCA();
    }

    function test_canExecuteDCA_returnsTrueIfAllConditionsMet() public {
        // total pricipal deposited != 0
        _openPositionWithPrincipal(alice, 1 ether);

        // dca interval passed
        _shiftTime(yieldDca.epochDuration());

        // yield >= min yield
        _generateYield(int256(uint256(yieldDca.minYieldPerEpoch())));

        assertTrue(yieldDca.canExecuteDCA());
    }

    /*
     * --------------------
     *     #executeDCA
     * --------------------
     */

    function test_executeDCA_failsIfCallerIsNotKeeper() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.KEEPER_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfNotEnoughTimeHasPassed() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration() - 1);

        vm.expectRevert(YieldDCABase.EpochDurationNotReached.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfYieldIsZero() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        vm.expectRevert(YieldDCABase.NoYield.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfYieldIsNegative() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        uint256 totalAssets = vault.totalAssets();
        // remove 10% of total assets
        _generateYield(-0.1e18);
        assertApproxEqAbs(vault.totalAssets(), totalAssets.mulWadDown(0.9e18), 1);

        vm.expectRevert(YieldDCABase.NoYield.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfYieldIsBelowMin() public {
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        _shiftTime(yieldDca.epochDuration());
        swapper.setExchangeRate(2e18);

        _generateYield(int256(uint256(yieldDca.minYieldPerEpoch() - 2)));

        vm.expectRevert(YieldDCABase.InsufficientYield.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfAmountReceivedIsBelowMin() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());
        _generateYield(1e18);

        uint256 expectedToReceive = 2 ether;
        swapper.setExchangeRate(2e18);

        vm.expectRevert(YieldDCABase.AmountReceivedTooLow.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(expectedToReceive + 1, "");
    }

    function test_executeDCA_oneDepositOneEpoch() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether in principal
         * 2. yield generated is 50%, ie 0.5 ether
         * 3. execute DCA at 3:1 exchange rate, ie by 1.5 DCA for 0.5 ether in yield
         * 4. alice closes position and gets 1 ether in shares and 1.5 DCA token
         */

        // step 1 - alice opens position with 1 ether in principal
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        // step 2 - generate 50% yield
        uint256 yieldPct = 0.5e18;
        _generateYield(int256(yieldPct));

        // step 3 - dca - buy 1.5 DCA tokens for 0.5 ether
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance not 0");

        uint256 currentEpoch = yieldDca.currentEpoch();
        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        _shiftTime(yieldDca.epochDuration());

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");

        assertEq(yieldDca.currentEpoch(), ++currentEpoch, "epoch not incremented");

        // balanceOf asserts
        uint256 expectedYield = principal.mulWadDown(yieldPct);
        uint256 expectedDcaAmount = expectedYield.mulWadDown(exchangeRate);
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount, 3, "dca token balance");

        (uint256 sharesLeft, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqAbs(vault.convertToAssets(sharesLeft), principal, 2, "balanceOf: principal");
        assertEq(dcaAmount, expectedDcaAmount, "balanceOf: dcaAmount");

        // step 4 - alice closes position and gets 1 ether in shares and 1.5 DCA tokens
        vm.prank(alice);
        yieldDca.closePosition(1);

        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaAmount, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), principal, 1, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(balance, 0, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
    }

    function test_executeDCA_emitsEvent() public {
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        uint256 sharePrice = uint256(0.5e18).divWadDown(vault.convertToShares(0.5e18));

        // generate 50% yield
        uint256 yieldPct = 0.5e18;
        _generateYield(int256(yieldPct));

        // dca - buy 2.5 DCA tokens for 0.5 ether
        uint32 currentEpoch = yieldDca.currentEpoch();
        uint256 exchangeRate = 5e18;
        swapper.setExchangeRate(exchangeRate);
        _shiftTime(yieldDca.epochDuration());

        uint256 expectedYield = principal.mulWadDown(yieldPct) + 1; // 1 is the rounding error
        uint256 expectedDcaAmount = expectedYield.mulWadDown(exchangeRate);
        uint128 expectedDcaPrice = uint128(exchangeRate);
        uint128 expectedSharePrice = uint128(sharePrice.mulWadDown(1e18 + yieldPct));

        vm.expectEmit(true, true, true, true);
        emit DCAExecuted(keeper, currentEpoch, expectedYield, expectedDcaAmount, expectedDcaPrice, expectedSharePrice);

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_failsIfRealizedPricePerDcaTokenDoesNotFitIntoUint128() public {
        // setup new vault and yieldDCA to start from a clean state
        vault = new MockERC4626(asset, "Mock ERC4626", "mERC4626");
        deal(address(dcaToken), address(swapper), type(uint136).max);

        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );

        // alice opens position with 1 ether
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        // generate 100% yield
        _generateYield(1e18);
        assertEq(uint256(yieldDca.calculateYield()), principal, "yield not 100%");

        // dca - buy uint136.max of DCA tokens for 1e18 in underlying assets
        uint256 exchangeRate = uint256(type(uint136).max);
        swapper.setExchangeRate(exchangeRate);
        _shiftTime(yieldDca.epochDuration());

        vm.expectRevert(bytes4(keccak256("Overflow()")));
        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }

    function test_executeDCA_positionIsIncreasedInSameEpoch() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. alice invreases position with 1 ether again
         * 4. execute DCA at 2:1 exchange, (alice gets 2 DCA tokens)
         * 5. alice withdraws and gets 2 ether in shares and 2 DCA tokens
         */

        // step 1 - alice opens position
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - alice increases position (this one will not generate any additional yield)

        _increasePosition(alice, 1 ether, positionId);

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertEq(dcaToken.balanceOf(alice), 0, "dca token balance");

        // step 4 - dca - buy 2 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(2e18);

        // step 5 - alice closes position and gets 2 DCA tokens
        _closePosition(alice, 1);

        assertApproxEqRel(dcaToken.balanceOf(alice), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    function test_executeDca_positionIsIncreasedInDifferentEpochs() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, (entitled to 3 DCA tokens)
         * 4. alice increases position with 1 ether again
         * 5. generate 100% yield in the second epoch, ie 2 ether
         * 6. execute DCA at 2:1 exchange, (entitiled to 4 DCA tokens)
         * 7. alice closes position and gets 2 ether in shares and 7 DCA tokens
         */

        // step 1 - alice opens position
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 4 - alice increases position
        _increasePosition(alice, principal, positionId);

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), 0, 0.00001e18, "dca token balance");

        // step 5 - generate 100% yield
        _generateYield(1e18);

        // step 6 - dca
        _executeDcaAtExchangeRate(2e18);

        // step 7 - alice closes position
        _closePosition(alice, 1);

        assertApproxEqRel(dcaToken.balanceOf(alice), 7e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    function test_executeDCA_oneOnePositionDuring200Epochs() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether in principal
         * 2. yield generated is 1% over 200 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice closes position and gets 1 ether in shares and gets 0.01 * 200 * 3 = 6 DCA tokens
         */

        // step 1 - alice opens position
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.01e18; // 1%
        uint256 epochs = 200;

        // step 2 & 3 - generate 1% yield over 200 epochs and do DCA
        for (uint256 i = 0; i < epochs; i++) {
            _generateYield(int256(yieldPerEpoch));

            _shiftTime(yieldDca.epochDuration());

            vm.prank(keeper);
            yieldDca.executeDCA(0, "");
        }

        assertEq(yieldDca.currentEpoch(), epochs + 1, "epoch not incremented");

        // step 4 - alice closes position and gets 6 DCA tokens
        _closePosition(alice, 1);

        uint256 expectedDcaTokenBalance = epochs * principal.mulWadDown(yieldPerEpoch).mulWadDown(exchangeRate);
        assertEq(expectedDcaTokenBalance, 6 ether, "expected dca token balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "actual dca token balance");
        assertApproxEqRel(_convertSharesToAssetsFor(alice), principal, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca token balance");
    }

    function test_executeDCA_onePositionDuring5Epochs() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether in principal
         * 2. yield generated is 5% over 5 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice closes position and gets 1 ether in shares and gets 0.05 * 5 * 3 = 0.75 DCA tokens
         */

        // step 1 - alice opens position
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.05e18; // 5%
        uint256 epochs = 5;

        // step 2 & 3 - generate 5% yield over 5 epochs and do DCA
        for (uint256 i = 0; i < epochs; i++) {
            _generateYield(int256(yieldPerEpoch));

            _shiftTime(yieldDca.epochDuration());

            vm.prank(keeper);
            yieldDca.executeDCA(0, "");
        }

        // step 4 - alice closes position and gets 0.75 DCA tokens
        _closePosition(alice, 1);

        uint256 expectedDcaTokenBalance = epochs * principal.mulWadDown(yieldPerEpoch).mulWadDown(exchangeRate);
        assertEq(expectedDcaTokenBalance, 0.75 ether, "expected dca token balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "actual dca token balance");
        assertApproxEqRel(_convertSharesToAssetsFor(alice), principal, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        // there can be some leftover dca tokens because of rounding errors and accounting inaccuracy
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), 0, 50, "contract's dca token balance");
    }

    function test_executeDCA_twoPositionsOverTwoEpochs_balancesCalculatedCorrectly() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice is entitled to 3 DCA tokens)
         * 4. bob opens position with 1 ether
         * 5. yield generated is 100% in the second epoch, ie 2 ether (from 2 deposits of 2 ether in total)
         * 6. execute DCA at 2:1 exchange, (bob is entitled to 2 DCA tokens and alice to 2 DCA tokens)
         * 7. alice closes position and gets 1 ether in shares and 5 DCA tokens (3 from first + 2 from second epoch)
         * 8. bob closes position and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice opens position with 1 ether
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 4 - bob opens position with 1 ether
        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        // step 5 - generate 100% yield
        _generateYield(1e18);

        // step 6 - dca
        _executeDcaAtExchangeRate(2e18);

        // step 7 - alice closes position and gets 5 DCA tokens
        _closePosition(alice, 1);

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 8 - bob closes position and gets 2 DCA tokens
        _closePosition(bob, 2);

        assertApproxEqRel(dcaToken.balanceOf(bob), 2e18, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 1, "bob's principal");
    }

    function test_executeDCA_twoPositionsInSameEpochCanExperienceDifferentYields() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. bob deposits 1 ether into vault only (no yield in DCA)
         * 3. yield generated is 100% in the first epoch, ie 1 ether from alices deposit
         * 4. bob opens position in DCA contract with 2 ether in principal (should not generate any yield)
         * 5. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice entitiled to 3 DCA tokens)
         * 6. alice closes position and gets 3 DCA tokens and 1 ether in principal
         * 7. bob is entitled to 0 DCA tokens
         */

        // step 1 - alice opens position
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - bob deposits into vault
        uint256 bobsPrincipal = 1 ether;
        uint256 bobsShares = _depositToVaultAndApproveYieldDca(bob, bobsPrincipal);

        // step 3 - generate 100% yield
        _generateYield(1e18);

        // step 4 - bob opens position in DCA
        vm.prank(bob);
        yieldDca.openPosition(bob, bobsShares);

        // step 4 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 5 - alice closes position and gets 5 DCA tokens
        _closePosition(alice, 1);

        assertApproxEqRel(dcaToken.balanceOf(alice), 3e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 6 - bob closes position and gets no DCA tokens
        _closePosition(bob, 2);

        assertApproxEqRel(dcaToken.balanceOf(bob), 0, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 2 * bobsPrincipal, 1, "bob's principal");
    }

    function test_executeDCA_multiplePositionsInDifferentEpochs_balanceAndDcaAmountsCalculatedCorrectly() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice is entitled to 3 DCA tokens)
         * 4. bob opens position with 2 ether
         * 5. carol opens position with 1 ether
         * 6. yield generated is 100% in the second epoch, ie 4 ether (from 3 deposits of 4 ether in total princpal)
         * 7. execute DCA at 2:1 exchange, (bob is entitled to 4 DCA tokens and alice & carol to 2 DCA tokens each)
         * 8. alice closes position and gets 1 ether in shares and 5 DCA tokens (3 + 2)
         * 9. bob closes position and gets 2 ether in shares and 4 DCA tokens
         * 10. carol closes position and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice opens position with 1 ether
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - dca - buy 3 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(3e18);

        // step 4 - bob opens position with 2 ether
        uint256 bobsPrincipal = 2 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        // step 5 - carol opens position with 1 ether
        uint256 carolsPrincipal = 1 ether;
        _openPositionWithPrincipal(carol, carolsPrincipal);

        // step 6 - generate 100% yield (ie 4 ether)
        _generateYield(1e18);

        // step 7 - dca - buy 8 DCA tokens for 4 ether
        _executeDcaAtExchangeRate(2e18);

        // step 8 - alice closes position and gets 5 DCA tokens
        _closePosition(alice, 1);

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 9 - bob closes position and gets 4 DCA tokens
        _closePosition(bob, 2);

        assertApproxEqRel(dcaToken.balanceOf(bob), 4e18, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 1, "bob's principal");

        // step 10 - carol closes position and gets 2 DCA tokens
        _closePosition(carol, 3);

        assertApproxEqRel(dcaToken.balanceOf(carol), 2e18, 0.00001e18, "carol's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(carol), carolsPrincipal, 1, "carol's principal");
    }

    function test_executeDCA_onePositionExperiencesNegativeYield() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% in the first epoch
         *      alice has 1 ether in principal and 1 ether in yield
         * 3. execute DCA at 4:1 exchange, 4 DCA tokens = 1 ether
         *      alice is entitled to 4 DCA tokens
         * 4. again yield generated is 100% (1 ether)
         *      alice has 1 ether in principal and 1 ether in yield (total 2 ether)
         * 5. bob opens position with 1 ether
         * 6. at this point yield becomes negative -25% (shares value drops by 25%)
         *      alice has 1 ether in principal and 0.5 ether in yield (total 1.5 ether)
         *      bob has 0.75 ether in principal (-0.25 from negative yield)
         *
         *      total principal per accouting is 2 ether but shares are only worth 3 * 0.75 = 2.25 ether => only 0.25 ether in yield can be spent
         *      this means that bob's loss of 0.25 is covered by alice's yield of 0.5, however this is not a permanent loss,
         *      as bob regains his principal, alice will regain her "lost" yield and thus also DCA tokens (but probably at different realized price)
         *
         * 7. execute DCA at 2:1 exchange, 0.25 ether = 0.5 DCA token
         *      alice is entitled to 1 DCA token per accounting, but only 0.5 DCA tokens are bought
         *      bob is entitled to 0 DCA tokens
         * 8. alice closes position and gets 1 ether in principal and 4.5 DCA tokens (should get 5 DCA tokens)
         * 9. bob closes position and gets 0.75 ether in shares and 0 DCA tokens
         * 10. 0.25 ether worth of shares are left in the contract as yield? - because alice withrew before bob had a chance to recover from his loss
         */

        // step 1 - alice opens position with 1 ether
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - dca - buy 4 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(4e18);

        // step 4 - generate 100% yield
        _generateYield(1e18);

        // step 5 - bob opens position with 1 ether
        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        // step 6 - generate -25% yield
        _generateYield(-0.25e18);

        // step 7 - dca - buy 1 DCA token for 0.5 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(yieldDca.totalPrincipal(), 2e18, "total principal deposited");

        // step 8 - alice's balance is 1 ether in principal and 5 DCA tokens
        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqAbs(vault.convertToAssets(shares), alicesPrincipal, 2, "bw: alice's principal");
        assertApproxEqRel(dcaAmount, 5e18, 0.00001e18, "bw: alice's dca token balance");

        // since alice is entitled to 5 DCA tokens but only 4.5 are available closing position will fail due to too large discrepancy
        vm.expectRevert(YieldDCABase.DCADiscrepancyAboveTolerance.selector);
        _closePosition(alice, 1);

        // the discrepancy tolerance needs to be set at 10% for alice to be able to close her position
        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(0.1e18);

        _closePosition(alice, 1);

        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 2, "aw: alice's principal");
        assertApproxEqRel(dcaToken.balanceOf(alice), 4.5e18, 0.00001e18, "aw: alice's dca token balance");

        // step 9 - bob's balance is 0.75 ether in principal and 0 DCA tokens
        (shares, dcaAmount) = yieldDca.balancesOf(2);
        assertApproxEqRel(vault.convertToAssets(shares), 0.75e18, 0.00001e18, "bob's principal");
        assertEq(dcaAmount, 0, "bob's dca token balance");

        _closePosition(bob, 2);

        assertEq(_convertSharesToAssetsFor(bob), bobsPrincipal.mulWadDown(0.75e18), "aw: bob's principal");
        assertEq(dcaToken.balanceOf(bob), 0, "aw: bob's dca token balance");

        // step 10 - 0.25 ether is left in the contract as surplus yield
        // which will be spend in the next epoch but it will not be accounted to any position but used for suppressing future discrepancies
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");

        uint256 yieldInShares = yieldDca.calculateYieldInShares();

        assertEq(vault.balanceOf(address(yieldDca)), yieldInShares, "contract's balance");
        assertApproxEqAbs(vault.convertToAssets(yieldInShares), 0.25 ether, 5, "contract's assets");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
    }

    function test_executeDca_negativeYieldCanBeRecoveredWithSurplus() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% (alice has 1 ether in principal and 1 ether in yield)
         * 3. bob opens position with 1 ether
         * 4. carol opens position with 1 ether
         * 5. from this point yield becomes negative -20% (shares value drpos by 20%)
         *      alice has 1.6 ether in actual value (1 in principal + 0.6 in yield)
         *      bob has 0.8 ether in actual value (lost some principal)
         *      carol has 0.8 ether (same as bob)
         *      total accounted principal = 3 ether, total assets = 3.2 ether, so usable yield per accounting is 0.2 ether
         * 6. execute DCA at 2:1 exchange, 0.2 ether = 0.4 DCA token
         *      alice can withdraw 0.4 DCA tokens (but is entitled to 1.2 DCA tokens per accounting logic because realized yield was only 0.6)
         *      bob is entitled to 0 DCA tokens
         *      carol is entitled to 0 DCA tokens
         * 7. generate 50% yield, enough to recover bob's and carol's loss
         *      alice has 2.1 ether in actual shares value ((1 in principal + 0.4 in yield from previous epoch) * 150%)
         *      bob has 1.2 ether in actual shares value ((1 in principal - 0.2 in yield from previous epoch) * 150%)
         *      carol has 1.2 ether in actual shares value ((1 in principal - 0.2 in yield from previous epoch) * 150%)
         *      total accounted principal = 3 ether, total assets = 4.5, so usable yield is 1.5 ether
         * 8. execute DCA at 2:1 exchange, 1.5 ether = 3 DCA token
         *      alice is entitled to total of 2.2 DCA tokens (per accounting 1 DCA tokens in current epoch + 1.2 DCA tokens from previous epoch)
         *      bob gets 0.4 DCA tokens
         *      carol gets 0.4 DCA tokens
         *
         *      in total: 3.4 DCA tokens are bought and divided like this:
         *          alice is entitled to 1.2 + 1 = 2.2 DCA tokens
         *          bob is entitled to 0 + 0.4 = 0.4 DCA tokens
         *          carol is entitled to 0 + 0.4 = 0.4 DCA tokens
         *          => 3.4 - 3 = 0.4 DCA tokens are undistributed due to accounting logic inability to handle negative yield per position
         *
         * 9. alice withdraws and gets 1 ether in shares and 2.2 DCA tokens
         * 10. bob withdraws and gets 1 ether in shares and 0.4 DCA tokens
         * 11. carol withdraws and gets 1 ether in shares and 0.4 DCA tokens
         *
         * 12. total DCA tokens bought is 3.4, but per accounting only 3 DCA tokens are expected -> 0.4 DCA tokens are undistributed
         */

        // step 1 - alice opens position
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - bob opens position
        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        // step 4 - carol opens position
        uint256 carolsPrincipal = 1 ether;
        _openPositionWithPrincipal(carol, carolsPrincipal);

        // step 5 - generate -20% yield
        _generateYield(-0.2e18);

        // step 6 - dca - buy 0.4 DCA tokens for 0.2 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(yieldDca.totalPrincipal(), 3e18, "total principal deposited");

        // step 7 - generate 50% yield
        _generateYield(0.5e18);

        // step 8 - dca - buy 3 DCA tokens for 1.5 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(yieldDca.totalPrincipal(), 3e18, "total principal deposited");

        // step 9 - alice's balance is 1 ether in principal and 2.2 DCA tokens
        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqAbs(vault.convertToAssets(shares), alicesPrincipal, 3, "bw: alice's principal");
        assertApproxEqRel(dcaAmount, 2.2e18, 0.00001e18, "bw: alice's dca token balance");

        _closePosition(alice, 1);

        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 3, "aw: alice's principal");
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "aw: alice's dca token balance");

        // step 10 - bob's balance is 1 ether in principal and 0.4 DCA tokens
        (shares, dcaAmount) = yieldDca.balancesOf(2);
        assertApproxEqAbs(vault.convertToAssets(shares), bobsPrincipal, 3, "bw: bob's principal");
        assertApproxEqRel(dcaAmount, 0.4e18, 0.00001e18, "bw: bob's dca token balance");

        _closePosition(bob, 2);

        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 3, "aw: bob's principal");
        assertEq(dcaToken.balanceOf(bob), dcaAmount, "aw: bob's dca token balance");

        // step 11 - carol's balance is 1 ether in principal and 0.4 DCA tokens
        (shares, dcaAmount) = yieldDca.balancesOf(3);
        assertApproxEqAbs(vault.convertToAssets(shares), carolsPrincipal, 3, "bw: carol's principal");
        assertApproxEqRel(dcaAmount, 0.4e18, 0.00001e18, "bw: carol's dca token balance");

        _closePosition(carol, 3);

        assertApproxEqAbs(_convertSharesToAssetsFor(carol), carolsPrincipal, 7, "aw: carol's principal");
        assertEq(dcaToken.balanceOf(carol), dcaAmount, "aw: carol's dca token balance");

        // step 12 - 0.4 DCA tokens are left in the contract
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertApproxEqRel(dcaToken.balanceOf(address(yieldDca)), 0.4e18, 0.00001e18, "contract's dca token balance");
    }

    function test_executeDCA_negativeYieldCanBeRecoveredWithDeficit() public {
        /**
         * scenario:
         * 1. alice opens position with 1 ether
         * 2. yield generated is 100% (alice has 1 ether in principal and 1 ether in yield)
         * 3. bob opens position 1 ether
         * 4. carol opens position 1 ether
         * 5. from this point yield becomes negative -20%,
         *      alice has 1.6 ether
         *      bob has 0.8 ether
         *      carol has 0.8 ether
         *      total principal = 3 ether, total assets = 3.2 ether, so usable yield per accounting is 0.2 ether
         * 6. execute DCA at 2:1 exchange, 0.2 ether = 0.4 DCA token
         *      alice gets 0.4 DCA tokens (per accounting 1.2 DCA tokens are expected)
         *      bob gets 0 DCA tokens
         *      carol gets 0 DCA tokens
         * 7. generate 50% yield, enough to recover bob's and carol's loss
         *      alice has 2.1 ether
         *      bob has 1.2 ether
         *      carol has 1.2 ether
         *      total principal = 3 ether, total assets = 4.5, so usable yield is 1.5 ether
         *
         * so far everything was the same as in the previous test case, but here price of DCA tokens is increased and thus less can be bought
         * 8. execute DCA at 1:1 exchange, 1.5 ether = 1.5 DCA token
         *      alice gets 1.1 DCA tokens (per accounting 0.5 DCA tokens are expected)
         *      bob gets 0.2 DCA tokens
         *      carol gets 0.2 DCA tokens
         *
         *      in total: 1.9 DCA tokens are bought
         *          alice is entitled to 1.2 + 0.5 = 1.7 DCA tokens
         *          bob is entitled to 0 + 0.2 = 0.2 DCA tokens
         *          carol is entitled to 0 + 0.2 = 0.2 DCA tokens
         *          => 1.9 - 2.1 = -0.2 DCA tokens are missing
         *
         * 9. alice withdraws and gets 1 ether in shares and 1.7 DCA tokens
         * 10. bob withdraws and gets 1 ether in shares and 0.2 DCA tokens
         *
         * 11. carol withdraws and gets 1 ether in shares and 0 DCA tokens - because of the missing DCA tokens, carol and bob are racing for the last DCA token?
         * But this is an extreme case after all so actual discrepancy is not realistic to be 100%
         */

        // step 1 - alice opens position
        uint256 alicesPrincipal = 1 ether;
        _openPositionWithPrincipal(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - bob opens position
        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        // step 4 - carol opens position
        uint256 carolsPrincipal = 1 ether;
        _openPositionWithPrincipal(carol, carolsPrincipal);

        // step 5 - generate -20% yield
        _generateYield(-0.2e18);

        // step 6 - dca - buy 0.4 DCA tokens for 0.2 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(yieldDca.totalPrincipal(), 3e18, "total principal deposited");

        // step 7 - generate 50% yield
        _generateYield(0.5e18);

        // step 8 - dca - buy 1.5 DCA tokens for 1.5 ether
        _executeDcaAtExchangeRate(1e18);

        assertEq(yieldDca.totalPrincipal(), 3e18, "total principal deposited");

        // step 9 - alice's balance is 1 ether in principal and 1.7 DCA tokens
        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqAbs(vault.convertToAssets(shares), alicesPrincipal, 3, "bw: alice's principal");
        assertApproxEqRel(dcaAmount, 1.7e18, 0.00001e18, "bw: alice's dca token balance");

        _closePosition(alice, 1);

        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 3, "aw: alice's principal");
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "aw: alice's dca token balance");

        // step 10 - bob's balance is 1 ether in principal and 0.2 DCA tokens
        (shares, dcaAmount) = yieldDca.balancesOf(2);
        assertApproxEqAbs(vault.convertToAssets(shares), bobsPrincipal, 3, "bob's principal");
        assertApproxEqRel(dcaAmount, 0.2e18, 0.00001e18, "bob's dca token balance");

        _closePosition(bob, 2);

        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 3, "aw: bob's principal");
        assertEq(dcaToken.balanceOf(bob), dcaAmount, "aw: bob's dca token balance");

        // step 11 - carol's balance is 1 ether in principal and 0 DCA tokens
        (shares, dcaAmount) = yieldDca.balancesOf(3);
        assertApproxEqAbs(vault.convertToAssets(shares), carolsPrincipal, 3, "carol's principal");
        assertEq(dcaAmount, 0.2e18, "carol's dca token balance");

        vm.expectRevert(YieldDCABase.DCADiscrepancyAboveTolerance.selector);
        _closePosition(carol, 3);

        // since carol is entitled to 0.2 DCA tokens and 0.2 DCA tokens are missing
        // the discrepancy tolerance needs to be set to 100% to allow carol to withdraw
        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(1e18); // 100%

        _closePosition(carol, 3);

        assertApproxEqAbs(_convertSharesToAssetsFor(carol), carolsPrincipal, 7, "aw: carol's principal");
        assertEq(dcaToken.balanceOf(carol), 0, "aw: carol's dca token balance");

        // 0 DCA tokens are left in the contract
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca token balance");
    }

    function test_executeDCA_maliciousSwapperCannotReenter() public {
        // the swapper is malicious and tries to reenter the contract
        // to enable this, admin has to be compromised and also grant the keeper role to the malicious swapper
        // step 1 - alice opens position
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        // step 2 - generate 50% yield
        _generateYield(0.5e18);
        _shiftTime(yieldDca.epochDuration());

        bytes memory reenterCall = abi.encodeCall(YieldDCAControlled.executeDCA, (0, ""));
        MaliciousSwapper maliciousSwapper = new MaliciousSwapper(reenterCall);

        // step 3 - admin sets the malicious swapper as the keeper
        vm.startPrank(admin);
        yieldDca.setSwapper(maliciousSwapper);
        yieldDca.grantRole(yieldDca.KEEPER_ROLE(), address(maliciousSwapper));
        vm.stopPrank();

        // step 4 - keeper executes DCA and swapper with keeper role tries to reenter
        vm.prank(keeper);
        // the malicious swapper tries to reenter the contract
        // it would fail anyway because the yield calcuation returns 0 and the tx would revert with NoYield error but just in case of future changes
        vm.expectRevert(bytes4(keccak256("Reentrancy()")));
        yieldDca.executeDCA(0, "");
    }

    /*
     * --------------------
     *   #reducePosition
     * --------------------
     */

    function test_reducePosition_failsIfInvalidPositionId() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        vm.prank(alice);
        yieldDca.reducePosition(positionId + 1, 1);
    }

    function test_reducePosition_failsIfNotOwnerOrApproved() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        vm.prank(bob);
        yieldDca.reducePosition(positionId, 1);
    }

    function test_reducePosition_failsIfAmountIs0() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(CommonErrors.ZeroAmount.selector);
        vm.prank(alice);
        yieldDca.reducePosition(positionId, 0);
    }

    function test_reducePosition_failsIfTryingToWithdrawMoreThanAvaiable() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);
        uint256 shares = vault.convertToShares(principal);

        vm.expectRevert(YieldDCABase.InsufficientSharesToWithdraw.selector);
        vm.prank(alice);
        yieldDca.reducePosition(positionId, shares + 1);
    }

    function test_reducePosition_worksInSameEpochAsDeposit() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        vm.prank(alice);
        yieldDca.reducePosition(positionId, shares / 2);

        assertEq(yieldDca.balanceOf(alice), 1, "token burned");
        assertEq(vault.balanceOf(alice), shares / 2, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares / 2, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(balance, shares / 2, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal / 2, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_reducePosition_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.convertToShares(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        vm.prank(alice);
        yieldDca.approve(dave, positionId);
        vm.prank(dave);
        yieldDca.reducePosition(positionId, shares / 2);

        assertEq(yieldDca.balanceOf(alice), 1, "token burned");
        assertEq(vault.balanceOf(alice), shares / 2, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares / 2, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(balance, shares / 2, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal / 2, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_reducePosition_burnsTokenIfWithdrawingAll() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        uint256 toWithdraw = _getSharesBalanceInDcaFor(positionId);

        assertEq(yieldDca.balanceOf(alice), 1, "bw: alice's nft balance");

        vm.prank(alice);
        yieldDca.reducePosition(positionId, toWithdraw);

        assertEq(yieldDca.balanceOf(alice), 0, "aw: alice's nft balance");

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.ownerOf(positionId);
    }

    function test_reducePosition_withdrawsOnlyShares() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(3e18);

        uint256 shares = vault.convertToShares(principal);
        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, shares, "alice's balance");
        assertEq(dcaBalance, 3e18, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 3e18, "contract's dca balance");

        uint256 toWithdraw = _getSharesBalanceInDcaFor(1) / 2;
        vm.prank(alice);
        yieldDca.reducePosition(positionId, toWithdraw);

        assertEq(vault.balanceOf(alice), shares / 2, "alice's balance after");
        assertEq(vault.convertToAssets(toWithdraw), principal / 2, "alice's assets after");
        assertEq(dcaToken.balanceOf(alice), 0, "alice's dca balance after");
        assertEq(yieldDca.totalPrincipal(), principal / 2, "total principal deposited after");
        assertEq(vault.balanceOf(address(yieldDca)), shares / 2, "contract's balance after");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 3e18, "contract's dca balance after");
    }

    function test_reducePosition_closePositionBurnsNftAndWithdrawsDcaAmount() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(2e18);

        (uint256 toWithdraw, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        yieldDca.reducePosition(positionId, toWithdraw);

        assertEq(yieldDca.balanceOf(alice), 0, "alice's nft balance");
        assertEq(vault.balanceOf(alice), toWithdraw, "alice's balance");
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "alice's dca balance");

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.ownerOf(positionId);
    }

    function test_reducePosition_accountsForRemainingSharesCorrectly() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether
         * 4. alice does partial withdraw of 1/2 principal (0.5 ether)
         * 5. again yield is generated at 100% (ie 0.5 ether)
         * 6. execute DCA at 3:1 exchange, 1.5 DCA tokens = 0.5 ether
         * 7. withdraws remaining 0.5 ether and receives 4.5 DCA tokens (end balance: 1.5 ether and 4.5 DCA tokens)
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // step 2 - generate 100% yield
        _generateYield(1e18);

        // step 3 - dca - buy 3 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(3e18);

        // step 4 - alice withdraws 1/2 principal
        uint256 toWithdraw = vault.convertToShares(principal / 2);
        vm.prank(alice);
        yieldDca.reducePosition(positionId, toWithdraw);

        assertEq(vault.balanceOf(alice), toWithdraw, "alice's balance");
        assertEq(dcaToken.balanceOf(alice), 0, "alice's dca balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(1);
        assertEq(dcaBalance, 3e18, "alice's dca balance in contract");
        assertEq(balance, vault.convertToShares(principal / 2), "alice's balance in contract");

        // step 5 - generate 100% yield
        _generateYield(1e18);
        // after doubilng again, alice's balance should be 1 ether
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1 ether, 1, "alice's principal");

        // step 6 - dca - buy 1.5 DCA tokens for 0.5 ether
        _executeDcaAtExchangeRate(3e18);

        // step 7 - withdraw remaining 0.5 ether
        toWithdraw = vault.convertToShares(principal / 2);
        vm.prank(alice);
        yieldDca.reducePosition(positionId, toWithdraw);

        assertApproxEqRel(dcaToken.balanceOf(alice), 4.5e18, 0.00001e18, "alice's dca balance after");
        // after withdrawing remaining 0.5 ether, alice's balance should be 1.5 ether
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1.5 ether, 1, "alice's principal after");

        (balance, dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, 0, "alice's balance after");
        assertEq(dcaBalance, 0, "alice's dca balance");

        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance after");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance after");
    }

    function test_reducePosition_emitsPositionReducedEvent() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        _generateYield(0.5e18);

        _executeDcaAtExchangeRate(5e18);

        (uint256 shares,) = yieldDca.balancesOf(1);
        uint256 toWithdraw = shares / 2;
        uint256 principalToWithdraw = vault.convertToAssets(toWithdraw) - 1; // -1 to account for rounding error

        vm.prank(alice);
        yieldDca.approve(bob, positionId);

        vm.expectEmit(true, true, true, true);
        emit PositionReduced(bob, alice, positionId, yieldDca.currentEpoch(), toWithdraw, principalToWithdraw);

        vm.prank(bob);
        yieldDca.reducePosition(positionId, toWithdraw);
    }

    function test_reducePosition_emitsPositionClosedEventIfWithdrawingAll() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(0.5e18);
        _executeDcaAtExchangeRate(5e18);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        // account for rounding error
        assertApproxEqAbs(shares, vault.balanceOf(address(yieldDca)), 1, "contract's balance");

        vm.prank(alice);
        yieldDca.approve(bob, positionId);

        vm.expectEmit(true, true, true, true);
        // use vault.balanceOf(address(yieldDca)) instead of shares to account for rounding error
        emit PositionClosed(
            bob, alice, positionId, yieldDca.currentEpoch(), vault.balanceOf(address(yieldDca)), principal, dcaAmount
        );

        vm.prank(bob);
        yieldDca.reducePosition(positionId, shares);
    }

    /*
     * --------------------
     *   #closePosition
     * --------------------
     */

    function test_closePosition_failsIfPositionDoesNotExist() public {
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.closePosition(1);
    }

    function test_closePosition_failsIfNotOwnerOrApproved() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        assertFalse(yieldDca.isApprovedForAll(alice, bob), "alice is not approved for bob");

        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        vm.prank(bob);
        yieldDca.closePosition(positionId);
    }

    function test_closePosition_worksInTheSameEpochWhenOpened() public {
        uint256 principal = 1 ether;
        uint256 shares = vault.previewDeposit(principal);
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        vm.prank(alice);
        yieldDca.closePosition(positionId);

        assertEq(vault.balanceOf(alice), shares, "alice' balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, 0, "alice's position balance");
        assertEq(dcaBalance, 0, "alice's position dca balance");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_closePosition_worksInDifferentEpoch() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(3e18);

        vm.prank(alice);
        yieldDca.closePosition(positionId);

        assertEq(vault.balanceOf(alice), vault.convertToShares(principal), "alice's balance");
        assertEq(dcaToken.balanceOf(alice), 3 * principal, "alice's dca balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, 0, "alice's position balance");
        assertEq(dcaBalance, 0, "alice's position dca balance");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
    }

    function test_closePosition_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(3e18);

        vm.prank(alice);
        yieldDca.approve(dave, positionId);
        vm.prank(dave);
        yieldDca.closePosition(positionId);

        assertEq(vault.balanceOf(alice), vault.convertToShares(principal), "alice's balance");
        assertEq(dcaToken.balanceOf(alice), 3e18, "alice's dca balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        assertEq(balance, 0, "alice's position balance");
        assertEq(dcaBalance, 0, "alice's position dca balance");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
    }

    function test_closePosition_emitsEvent() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(0.5e18);
        _executeDcaAtExchangeRate(5e18);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        assertApproxEqAbs(shares, vault.balanceOf(address(yieldDca)), 1, "contract's balance");

        vm.expectEmit(true, true, true, true);
        // use vault.balanceOf(address(yieldDca)) instead of shares to account for rounding error
        emit PositionClosed(
            alice, alice, positionId, yieldDca.currentEpoch(), vault.balanceOf(address(yieldDca)), principal, dcaAmount
        );

        vm.prank(alice);
        yieldDca.closePosition(positionId);
    }

    /*
     * --------------------
     *   #claimDCABalance
     * --------------------
     */

    function test_claimDCABalance_failsIfPositionDoesNotExist() public {
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.claimDCABalance(1, address(this));
    }

    function test_claimDCABalance_failsForZeroAddress() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(CommonErrors.ZeroAddress.selector);
        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, address(0));
    }

    function test_claimDCABalance_failsIfNotOwnerOrApproved() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        vm.prank(bob);
        yieldDca.claimDCABalance(positionId, bob);
    }

    function test_claimDCABalance_failsIfNothingToClaim() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(YieldDCABase.NothingToClaim.selector));
        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, alice);
    }

    function test_claimDCABalance_transfersOnlyDCATokens() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(3e18);

        (uint256 sharesRemaining, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, alice);

        assertEq(dcaToken.balanceOf(alice), dcaAmount, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "total principal deposited");
        assertEq(vault.balanceOf(address(yieldDca)), sharesRemaining, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");

        (uint256 sharesAfterClaim, uint256 dcaAmountAfterClaim) = yieldDca.balancesOf(positionId);
        assertEq(sharesAfterClaim, sharesRemaining, "alice's position balance");
        assertEq(dcaAmountAfterClaim, 0, "alice's position dca balance");

        // claim again should fail
        vm.expectRevert(abi.encodeWithSelector(YieldDCABase.NothingToClaim.selector));
        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, alice);
    }

    function test_claimDCABalance_transfersToProvidedAddress() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(3e18);

        (, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, bob);

        assertEq(dcaToken.balanceOf(bob), dcaAmount, "bob's dca balance");
        assertEq(dcaToken.balanceOf(alice), 0, "alices's dca balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");
    }

    function test_claimDCABalance_worksForApprovedCaller() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(3e18);

        (uint256 sharesRemaining, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        yieldDca.approve(dave, positionId);
        vm.prank(dave);
        yieldDca.claimDCABalance(positionId, alice);

        assertEq(dcaToken.balanceOf(alice), dcaAmount, "alice's dca balance");
        assertEq(dcaToken.balanceOf(dave), 0, "dave's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "total principal deposited");
        assertEq(vault.balanceOf(address(yieldDca)), sharesRemaining, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");

        (uint256 sharesAfterClaim, uint256 dcaAmountAfterClaim) = yieldDca.balancesOf(positionId);
        assertEq(sharesAfterClaim, sharesRemaining, "alice's position balance");
        assertEq(dcaAmountAfterClaim, 0, "alice's position dca balance");
    }

    function test_claimDCABalance_worksInConsequtiveEpochs() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(3e18);

        (uint256 sharesRemaining, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        uint256 totalClaimed = yieldDca.claimDCABalance(positionId, alice);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(5e18);

        (sharesRemaining, dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        totalClaimed += yieldDca.claimDCABalance(positionId, alice);

        assertEq(totalClaimed, 8e18, "total claimed");
        assertEq(dcaToken.balanceOf(alice), totalClaimed, "alice's dca balance");
        assertEq(yieldDca.totalPrincipal(), principal, "total principal deposited");
        assertEq(vault.balanceOf(address(yieldDca)), sharesRemaining, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");

        (uint256 sharesAfterClaim, uint256 dcaAmountAfterClaim) = yieldDca.balancesOf(positionId);
        assertEq(sharesAfterClaim, sharesRemaining, "alice's position balance");
        assertEq(dcaAmountAfterClaim, 0, "alice's position dca balance");
    }

    function test_claimDCABalance_emitsEvent() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);

        _generateYield(0.5e18);
        _executeDcaAtExchangeRate(5e18);

        (, uint256 dcaAmount) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        yieldDca.approve(carol, positionId);

        vm.expectEmit(true, true, true, true);
        emit DCABalanceClaimed(carol, alice, positionId, yieldDca.currentEpoch(), dcaAmount, dave);

        vm.prank(carol);
        yieldDca.claimDCABalance(positionId, dave);
    }

    function test_claimDCABalance_failsIfDcaDiscrepancyIsAboveTolerated() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);
        uint64 onePercent = 0.01e18;

        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(onePercent);

        assertEq(yieldDca.discrepancyTolerance(), onePercent, "discrepancy tolerance not set");

        _generateYield(1e18);

        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        _generateYield(-int256(uint256(onePercent) + 0.001e18));
        _executeDcaAtExchangeRate(2e18);

        vm.expectRevert(abi.encodeWithSelector(YieldDCABase.DCADiscrepancyAboveTolerance.selector));
        vm.prank(alice);
        yieldDca.claimDCABalance(positionId, alice);
    }

    function test_claimDCABalance_worksIfDcaDiscrepancyBelowTolerated() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1 ether);
        uint64 onePercent = 0.01e18;

        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(onePercent);

        assertEq(yieldDca.discrepancyTolerance(), onePercent, "discrepancy tolerance not set");

        _generateYield(1e18);

        uint256 bobsPrincipal = 1 ether;
        _openPositionWithPrincipal(bob, bobsPrincipal);

        _generateYield(-int256(uint256(onePercent) - 0.001e18));
        _executeDcaAtExchangeRate(2e18);

        (, uint256 entitled) = yieldDca.balancesOf(positionId);

        vm.prank(alice);
        uint256 claimed = yieldDca.claimDCABalance(positionId, alice);

        assertTrue(entitled > claimed, "there was no discrepancy");
        assertEq(dcaToken.balanceOf(alice), claimed, "alice's dca balance");
    }

    /*
     * --------------------
     *     #balancesOf
     * --------------------
     */

    function test_balancesOf_returnsZerosIfPositionDoesNotExist() public {
        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertEq(shares, 0, "shares");
        assertEq(dcaAmount, 0, "dca amount");
    }

    function test_balancesOf_returnsSharesIfDcaNotExecuted() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(positionId);
        assertEq(shares, vault.convertToShares(principal), "shares");
        assertEq(dcaAmount, 0, "dca amount");
    }

    function test_balancesOf_returnsSharesAndDcaAmountIfDcaExecuted() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(3e18);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(positionId);
        assertEq(shares, vault.convertToShares(principal), "shares");
        assertEq(dcaAmount, 3 ether, "dca amount");
    }

    function test_balancesOf_worksTrhuMultipleEpochs() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(3e18);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(positionId);
        assertEq(shares, vault.convertToShares(principal), "shares");
        assertEq(dcaAmount, 3 ether, "dca amount");

        _generateYield(1e18);
        _shiftTime(yieldDca.epochDuration());
        _executeDcaAtExchangeRate(5e18);

        (shares, dcaAmount) = yieldDca.balancesOf(positionId);
        assertEq(shares, vault.convertToShares(principal), "shares");
        assertEq(dcaAmount, 8 ether, "dca amount");
    }

    function test_balancesOf_returnsZeroDcaAmountIfYieldWasNegative() public {
        uint256 alicesPrincipal = 1 ether;
        uint256 alicesPosition = _openPositionWithPrincipal(alice, alicesPrincipal);

        _generateYield(1e18);

        uint256 bobsPrincipal = 1 ether;
        uint256 bobsPosition = _openPositionWithPrincipal(bob, bobsPrincipal);

        _generateYield(-0.2e18);
        _executeDcaAtExchangeRate(2e18);

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(alicesPosition);
        assertEq(shares, vault.convertToShares(alicesPrincipal), "alice's shares");
        assertEq(dcaAmount, 1.2e18, "alice's dca amount");

        (shares, dcaAmount) = yieldDca.balancesOf(bobsPosition);
        assertEq(shares, vault.convertToShares(bobsPrincipal.mulWadDown(0.8e18)), "bob's shares");
        assertEq(dcaAmount, 0, "bob's dca amount");
    }

    /*
     * --------------------
     *     #multicall
     * --------------------
     */

    function test_multicall_openPositionAndApprove() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, principal);
        uint256 positionId = yieldDca.nextPositionId();

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(YieldDCABase.openPosition, (alice, shares));
        data[1] = abi.encodeCall(ERC721.approve, (bob, positionId));

        vm.prank(alice);
        yieldDca.multicall(data);

        assertEq(yieldDca.balanceOf(alice), 1, "alice's nft balance");
        assertEq(yieldDca.ownerOf(positionId), alice, "alice's owner");
        assertEq(yieldDca.getApproved(positionId), bob, "bob's approval");
    }

    /*
     * --------------------
     *     #transfer
     * --------------------
     */

    function test_transfer_changesOwner() public {
        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        _generateYield(1e18);
        _executeDcaAtExchangeRate(3e18);

        vm.prank(alice);
        yieldDca.transferFrom(alice, bob, positionId);

        assertEq(yieldDca.ownerOf(positionId), bob, "new owner");

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertEq(vault.convertToAssets(shares), principal, "principal");
        assertEq(dcaAmount, 3 ether, "dca amount");

        _closePosition(bob, positionId);

        assertEq(vault.balanceOf(bob), vault.convertToShares(principal), "bob's balance");
        assertEq(dcaToken.balanceOf(bob), dcaAmount, "bob's dca balance");

        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");
    }

    /*
     * --------------------
     *   gas usage tests
     * --------------------
     */

    // NOTE: tests below fill likely fail if run with --gas-report flag due to the gas usage of the reporting infrastructure itself
    function testGas_claimDCABalance_canHandle30kEpochs() public {
        // NOTE: if one epoch is 5 days, 30k epochs is roughly 410 years
        // setup new vault and yieldDCA to start from a clean state
        vault = new MockERC4626(asset, "Mock ERC4626", "mERC4626");
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, 0, admin, keeper
        );

        vm.startPrank(admin);
        yieldDca.setMinYieldPerEpoch(0);
        yieldDca.setEpochDuration(uint32(1 weeks));
        vm.stopPrank();

        uint256 principal = 10 ether;
        _openPositionWithPrincipal(alice, principal);

        uint256 exchangeRate = 2e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.01 ether;
        uint256 epochs = 30_000;

        for (uint256 i = 0; i < epochs; i++) {
            asset.mint(address(vault), yieldPerEpoch);

            _shiftTime(yieldDca.epochDuration());

            vm.prank(keeper);
            yieldDca.executeDCA(0, "");
        }

        uint256 expectedTotalYield = epochs * yieldPerEpoch;
        uint256 expectedDcaBalance = expectedTotalYield.mulWadDown(exchangeRate);
        assertEq(yieldDca.currentEpoch(), epochs + 1, "epoch not incremented");
        assertApproxEqRel(dcaToken.balanceOf(address(yieldDca)), expectedDcaBalance, 0.000001e18, "dca token balance");

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        yieldDca.claimDCABalance(1, alice);
        uint256 gasAfter = gasleft();

        assertTrue(gasBefore - gasAfter < 30_000_000, "gas used greater than 30m");
        console2.log("gas used", gasBefore - gasAfter);
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaBalance, 0.000001e18, "alice's claimed dca amount");
        (uint256 shares2,) = yieldDca.balancesOf(1);
        assertApproxEqAbs(shares2, vault.convertToShares(principal), 100, "alice's position shares");
    }

    function testGas_calculateBalances_singleIterationGasAverage() public {
        // setup new vault and yieldDCA to start from a clean state
        vault = new MockERC4626(asset, "Mock ERC4626", "mERC4626");
        yieldDca = new YieldDCAControlled(
            IERC20Metadata(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, 0, admin, keeper
        );

        uint256 principal = 1 ether;
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        // number of loops inside the function equals to the number of epochs
        uint256 epochs = 100;
        uint256 yieldPerEpoch = 0.01 ether;
        swapper.setExchangeRate(1e18);

        for (uint256 i = 0; i < epochs; i++) {
            asset.mint(address(vault), yieldPerEpoch);

            _shiftTime(yieldDca.epochDuration());

            vm.prank(keeper);
            yieldDca.executeDCA(0, "");
        }

        vm.startPrank(alice);

        // Start measuring gas
        uint256 gasBefore = gasleft();
        (uint256 sharesBalance, uint256 dcaBalance) = yieldDca.balancesOf(positionId);
        uint256 gasAfter = gasleft();

        assertApproxEqAbs(sharesBalance, vault.convertToShares(principal), 150, "shares balance");
        assertApproxEqAbs(dcaBalance, epochs * yieldPerEpoch, 100, "dca balance");

        uint256 gasAverage = (gasBefore - gasAfter) / epochs;
        console2.log("single iteration average gas: ", gasAverage);
        assertTrue(gasAverage < 1000, "average gas greater than 1000");
    }

    /*
     * --------------------
     *     #setTokenCID
     * --------------------
     */

    function test_setTokenCID_failsIfTokenDoesntExist() public {
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.setTokenCID(1, "123");
    }

    function test_setTokenCID_failsIfCIDIsEmptyString() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        vm.expectRevert(YieldDCABase.EmptyCID.selector);
        vm.prank(alice);
        yieldDca.setTokenCID(positionId, "");
    }

    function test_setTokenCID_storesProvidedValue() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);
        assertEq(yieldDca.tokenCIDs(positionId), "", "token CID not empty");

        // hello world CID
        string memory cid = "QmYwAPJzv5CZsnAzt8auVZRn1pfejwPXv8rVd5NdKAX3io";

        vm.prank(alice);
        yieldDca.setTokenCID(positionId, cid);

        assertEq(yieldDca.tokenCIDs(positionId), cid, "CID not set");
    }

    function test_setTokenCID_overwritesExistingValue() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        // set initial CID
        vm.startPrank(alice);
        yieldDca.setTokenCID(positionId, "123");

        // image example
        string memory newCid = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDd7N8UMLrZw2";

        // update CID
        yieldDca.setTokenCID(positionId, newCid);

        assertEq(yieldDca.tokenCIDs(positionId), newCid, "CID not updated");
    }

    function test_setTokenCID_failsIfCallerIsNotApproved() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        vm.prank(carol);
        yieldDca.setTokenCID(positionId, "123");
    }

    function test_setTokenCID_worksIfCallerIsApproved() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        vm.prank(alice);
        yieldDca.approve(carol, positionId);

        vm.prank(carol);
        yieldDca.setTokenCID(positionId, "123");

        assertEq(yieldDca.tokenCIDs(positionId), "123", "CID not set");
    }

    function test_setTokenCID_emitsEvent() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);
        string memory cid = "QmYwAPJzv5CZsnAzt8auVZRn1pfejwPXv8rVd5NdKAX3io";

        vm.prank(alice);
        yieldDca.approve(carol, positionId);

        vm.expectEmit(true, true, true, true);
        emit TokenCIDUpdated(carol, alice, positionId, cid);

        vm.prank(carol);
        yieldDca.setTokenCID(positionId, cid);
    }

    /*
     * --------------------
     *      #tokenCID
     * --------------------
     */

    function test_tokenCIDs_returnsEmptyStringIfCIDIsntSet() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        assertEq(yieldDca.tokenCIDs(positionId), "", "token CID not empty");
    }

    function test_tokenCIDs_returnsEmptyStringAfterPositionIsClosed() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        // hello world CID
        string memory cid = "QmYwAPJzv5CZsnAzt8auVZRn1pfejwPXv8rVd5NdKAX3io";

        vm.prank(alice);
        yieldDca.setTokenCID(positionId, cid);

        assertEq(yieldDca.tokenCIDs(positionId), cid, "CID not set");

        vm.prank(alice);
        yieldDca.closePosition(positionId);

        assertEq(yieldDca.tokenCIDs(positionId), "", "token CID not empty");
    }

    /*
     * --------------------
     *      #tokenUri
     * --------------------
     */
    function test_tokenUri_failsIfTokenDoesntExist() public {
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        yieldDca.tokenURI(1);
    }

    function test_tokenUri_returnsEmptyStringIfCIDIsntSet() public {
        _openPositionWithPrincipal(alice, 1e18);

        assertEq(yieldDca.tokenURI(1), "", "token uri not empty");
    }

    function test_tokenUri_returnsCorrectCID() public {
        uint256 positionId = _openPositionWithPrincipal(alice, 1e18);

        // hello world CID
        string memory cid = "QmYwAPJzv5CZsnAzt8auVZRn1pfejwPXv8rVd5NdKAX3io";

        vm.prank(alice);
        yieldDca.setTokenCID(positionId, cid);

        assertEq(yieldDca.tokenCIDs(positionId), cid, "CID not set");
        assertEq(yieldDca.tokenURI(positionId), string.concat("ipfs://", cid), "token URI");
    }

    /*
     * --------------------
     *     #multicall
     * --------------------
     */

    function test_multicall_openPositionAndSetCID() public {
        uint256 shares = _depositToVaultAndApproveYieldDca(alice, 1e18);
        uint256 positionId = yieldDca.nextPositionId();

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(YieldDCABase.openPosition, (alice, shares));
        data[1] = abi.encodeCall(YieldDCABase.setTokenCID, (positionId, "123"));

        vm.prank(alice);
        yieldDca.multicall(data);

        assertEq(yieldDca.ownerOf(positionId), alice, "owner");
        assertEq(yieldDca.tokenCIDs(positionId), "123", "CID not set");
    }

    /*
     * --------------------
     *   helper functions
     * --------------------
     */

    function _openPositionWithPrincipal(address _account, uint256 _amount) public returns (uint256 positionId) {
        uint256 shares = _depositToVaultAndApproveYieldDca(_account, _amount);

        vm.prank(_account);
        positionId = yieldDca.openPosition(_account, shares);
    }

    function _depositToVault(address _account, uint256 _amount) public returns (uint256 shares) {
        return _depositToVault(IERC4626(address(vault)), _account, _amount);
    }

    function _depositToVaultAndApproveYieldDca(address _account, uint256 _amount) public returns (uint256 shares) {
        shares = _depositToVaultAndApprove(IERC4626(address(vault)), _account, address(yieldDca), _amount);
    }

    function _assetDealAndApproveYieldDca(address _owner, uint256 _amount) public {
        _dealAndApprove(IERC20(address(asset)), _owner, address(yieldDca), _amount);
    }

    function _vaultApproveYieldDca(address _owner, uint256 _shares) public {
        _approve(IERC20(address(vault)), _owner, address(yieldDca), _shares);
    }

    function _increasePosition(address _account, uint256 _amount, uint256 _positionId) public {
        uint256 shares = _depositToVault(_account, _amount);
        _vaultApproveYieldDca(_account, shares);

        vm.prank(_account);
        yieldDca.increasePosition(_positionId, shares);
    }

    function _generateYield(int256 _percent) public {
        _generateYield(IERC4626(address(vault)), _percent);
    }

    function _convertSharesToAssetsFor(address _account) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(_account));
    }

    function _getSharesBalanceInDcaFor(uint256 _positionId) internal view returns (uint256 shares) {
        (shares,) = yieldDca.balancesOf(_positionId);
    }

    function _closePosition(address _account, uint256 _positionId) internal {
        vm.prank(_account);
        yieldDca.closePosition(_positionId);
    }

    function _executeDcaAtExchangeRate(uint256 _exchangeRate) internal {
        swapper.setExchangeRate(_exchangeRate);
        _shiftTime(yieldDca.epochDuration());

        vm.prank(keeper);
        yieldDca.executeDCA(0, "");
    }
}
