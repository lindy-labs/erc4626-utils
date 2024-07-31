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
import {YieldDCASimple} from "src/YieldDCASimple.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {IPriceFeed} from "src/interfaces/IPriceFeed.sol";
import {SwapperMock, MaliciousSwapper} from "./mock/SwapperMock.sol";
import {PriceFeedMock} from "./mock/PriceFeedMock.sol";
import {TestCommon} from "./common/TestCommon.sol";

contract YieldDCASimpleTest is TestCommon {
    using FixedPointMathLib for uint256;

    event PriceFeedUpdated(address indexed caller, IPriceFeed oldPriceFeed, IPriceFeed newPriceFeed);
    event SwapDataUpdated(address indexed caller, bytes oldSwapData, bytes newSwapData);
    event ToleratedSlippageUpdated(address indexed caller, uint256 oldSlippage, uint256 newSlippage);

    uint32 public constant DEFAULT_DCA_INTERVAL = 2 weeks;
    uint64 public constant DEFAULT_MIN_YIELD_PERCENT = 0.001e18; // 0.1%

    YieldDCASimple yieldDca;
    MockERC20 asset;
    MockERC4626 vault;
    MockERC20 dcaToken;

    SwapperMock swapper;
    PriceFeedMock priceFeed;
    bytes swapData = bytes("test");

    function setUp() public {
        asset = new MockERC20("Mock ERC20", "mERC20", 18);
        vault = new MockERC4626(asset, "Mock ERC4626", "mERC4626");
        dcaToken = new MockERC20("Mock DCA", "mDCA", 18);
        swapper = new SwapperMock();
        priceFeed = new PriceFeedMock();

        dcaToken.mint(address(swapper), type(uint128).max);
        yieldDca = new YieldDCASimple(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            priceFeed,
            swapData,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin
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
        assertEq(address(yieldDca.priceFeed()), address(priceFeed), "price feed");
        assertEq(yieldDca.swapData(), swapData, "swap data");
        assertEq(yieldDca.toleratedSlippage(), 0.05e18, "default tolerated slippage");

        assertEq(yieldDca.currentEpoch(), 1, "current epoch");
        assertEq(yieldDca.currentEpochTimestamp(), block.timestamp, "current epoch timestamp");
        assertEq(yieldDca.totalPrincipal(), 0, "total principal deposited");
        assertEq(yieldDca.discrepancyTolerance(), 0.05e18, "default discrepancy tolerance");

        assertTrue(yieldDca.hasRole(yieldDca.DEFAULT_ADMIN_ROLE(), admin), "admin role");

        assertEq(asset.allowance(address(yieldDca), address(swapper)), type(uint256).max, "swapper allowance");
        assertEq(asset.allowance(address(yieldDca), address(vault)), type(uint256).max, "vault allowance");
    }

    function test_constructor_revertsForPriceFeedAddressZero() public {
        priceFeed = PriceFeedMock(address(0));

        vm.expectRevert(YieldDCASimple.PriceFeedAddressZero.selector);
        yieldDca = new YieldDCASimple(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            priceFeed,
            swapData,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin
        );
    }

    function test_constructor_revertsForEmptySwapData() public {
        swapData = bytes("");

        yieldDca = new YieldDCASimple(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            priceFeed,
            swapData,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin
        );

        assertEq(yieldDca.swapData(), swapData, "swap data not empty");
    }

    /*
     * --------------------
     *    #setPriceFeed
     * --------------------
     */

    function test_setPriceFeed_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setPriceFeed(priceFeed);
    }

    function test_setPriceFeed_revertsForAddressZero() public {
        vm.expectRevert(YieldDCASimple.PriceFeedAddressZero.selector);

        vm.prank(admin);
        yieldDca.setPriceFeed(PriceFeedMock(address(0)));
    }

    function test_setPriceFeed_updatesPriceFeed() public {
        IPriceFeed newPriceFeed = new PriceFeedMock();

        vm.prank(admin);
        yieldDca.setPriceFeed(newPriceFeed);

        assertEq(address(yieldDca.priceFeed()), address(newPriceFeed), "price feed");
    }

    function test_setPriceFeed_emitsEvent() public {
        IPriceFeed newPriceFeed = new PriceFeedMock();
        IPriceFeed oldPriceFeed = yieldDca.priceFeed();

        vm.expectEmit(true, true, true, true);
        emit PriceFeedUpdated(admin, oldPriceFeed, newPriceFeed);

        vm.prank(admin);
        yieldDca.setPriceFeed(newPriceFeed);
    }

    /*
     * --------------------
     *    #setSwapData
     * --------------------
     */

    function test_setSwapData_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setSwapData(swapData);
    }

    function test_setSwapData_worksForEmptySwapData() public {
        bytes memory empty = bytes("");

        vm.prank(admin);
        yieldDca.setSwapData(empty);

        assertEq(yieldDca.swapData(), empty, "swap data");
    }

    function test_setSwapData_updatesSwapData() public {
        bytes memory newSwapData = bytes("new swap data");

        vm.prank(admin);
        yieldDca.setSwapData(newSwapData);

        assertEq(yieldDca.swapData(), newSwapData, "new swap data");
    }

    function test_setSwapData_emitsEvent() public {
        bytes memory newSwapData = bytes("new swap data");
        bytes memory oldSwapData = yieldDca.swapData();

        vm.expectEmit(true, true, true, true);
        emit SwapDataUpdated(admin, oldSwapData, newSwapData);

        vm.prank(admin);
        yieldDca.setSwapData(newSwapData);
    }

    /*
     * --------------------
     * #setToleratedSlippage
     * --------------------
     */

    function test_setToleratedSlippage_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setToleratedSlippage(0.1e18);
    }

    function test_setToleratedSlippage_revertsIfBelowMin() public {
        uint256 invalidSlippage = yieldDca.MIN_TOLERATED_SLIPPAGE() - 1;

        vm.expectRevert(YieldDCASimple.InvalidSlippageTolerance.selector);

        vm.prank(admin);
        yieldDca.setToleratedSlippage(invalidSlippage);
    }

    function test_setToleratedSlippage_revertsIfAboveMax() public {
        uint256 invalidSlippage = yieldDca.MAX_TOLERATED_SLIPPAGE() + 1;

        vm.expectRevert(YieldDCASimple.InvalidSlippageTolerance.selector);

        vm.prank(admin);
        yieldDca.setToleratedSlippage(invalidSlippage);
    }

    function test_setToleratedSlippage_worksForMax() public {
        uint256 newSlippage = yieldDca.MAX_TOLERATED_SLIPPAGE();

        vm.prank(admin);
        yieldDca.setToleratedSlippage(newSlippage);

        assertEq(yieldDca.toleratedSlippage(), newSlippage, "new slippage");
    }

    function test_setToleratedSlippage_worksForMin() public {
        uint256 newSlippage = yieldDca.MIN_TOLERATED_SLIPPAGE();

        vm.prank(admin);
        yieldDca.setToleratedSlippage(newSlippage);

        assertEq(yieldDca.toleratedSlippage(), newSlippage, "new slippage");
    }

    function test_setToleratedSlippage_emitsEvent() public {
        uint256 newSlippage = 0.1e18;
        uint256 oldSlippage = yieldDca.toleratedSlippage();

        vm.expectEmit(true, true, true, true);
        emit ToleratedSlippageUpdated(admin, oldSlippage, newSlippage);

        vm.prank(admin);
        yieldDca.setToleratedSlippage(newSlippage);
    }

    /*
     * --------------------
     *    #executeDCA
     * --------------------
     */

    function test_executeDCA_failsIfNotEnoughTimeHasPassed() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration() - 1);

        vm.expectRevert(YieldDCABase.EpochDurationNotReached.selector);
        yieldDca.executeDCA();
    }

    function test_executeDCA_failsIfYieldIsZero() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        vm.expectRevert(YieldDCABase.NoYield.selector);
        yieldDca.executeDCA();
    }

    function test_executeDCA_failsIfYieldIsNegative() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());

        uint256 totalAssets = vault.totalAssets();
        // remove 10% of total assets
        _generateYield(-0.1e18);
        assertApproxEqAbs(vault.totalAssets(), totalAssets.mulWadDown(0.9e18), 1);

        vm.expectRevert(YieldDCABase.NoYield.selector);
        yieldDca.executeDCA();
    }

    function test_executeDCA_failsIfYieldIsBelowMin() public {
        uint256 principal = 1 ether;
        _openPositionWithPrincipal(alice, principal);

        _shiftTime(yieldDca.epochDuration());
        swapper.setExchangeRate(2e18);

        _generateYield(int256(uint256(yieldDca.minYieldPerEpoch() - 2)));

        vm.expectRevert(YieldDCABase.InsufficientYield.selector);
        yieldDca.executeDCA();
    }

    function test_executeDCA_failsIfAmountReceivedIsBelowMin() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());
        _generateYield(1e18);

        uint256 latestPrice = 3e18;
        uint256 exchangeRate = 2e18;

        // assert price + slippage is below the expected min amount out
        assertTrue(latestPrice.mulWadDown(1e18 - yieldDca.toleratedSlippage()) > exchangeRate, "incorrect setup");

        priceFeed.setLatestPrice(latestPrice);
        swapper.setExchangeRate(exchangeRate);

        vm.expectRevert(YieldDCABase.AmountReceivedTooLow.selector);
        yieldDca.executeDCA();
    }

    function test_executeDCA_worksForArbitraryCaller() public {
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

        // assert admin role is not set to the caller
        address caller = address(0x1111);
        assertTrue(!yieldDca.hasRole(yieldDca.DEFAULT_ADMIN_ROLE(), caller), "unexepcted admin role");

        vm.prank(caller);
        yieldDca.executeDCA();

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

    function test_executeDCA_accountsForToleratedSlippageChanges() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());
        _generateYield(1e18);

        uint256 latestPrice = 10e18;
        uint256 exchangeRate = 9e18;
        priceFeed.setLatestPrice(latestPrice);
        swapper.setExchangeRate(exchangeRate);

        uint256 toleratedSlippage = yieldDca.toleratedSlippage();

        // assert price + slippage is below the expected min amount out
        assertTrue(latestPrice.mulWadDown(1e18 - toleratedSlippage) > exchangeRate, "incorrect setup");

        vm.expectRevert(YieldDCABase.AmountReceivedTooLow.selector);
        yieldDca.executeDCA();

        // increase slippage
        uint256 newSlippage = 0.2e18;
        vm.prank(admin);
        yieldDca.setToleratedSlippage(newSlippage);

        // assert price + slippage is above the expected min amount out
        assertTrue(latestPrice.mulWadDown(1e18 - newSlippage) < exchangeRate, "incorrect setup");

        // execute DCA should pass
        yieldDca.executeDCA();

        assertEq(dcaToken.balanceOf(address(yieldDca)), 9e18, "dca token end balance");
    }

    function test_executeDCA_correctlyPassesSwapData() public {
        _openPositionWithPrincipal(alice, 1 ether);

        _shiftTime(yieldDca.epochDuration());
        _generateYield(1e18);

        uint256 exchangeRate = 9e18;
        swapper.setExchangeRate(exchangeRate);

        bytes memory data = bytes("test swap data");
        vm.prank(admin);
        yieldDca.setSwapData(data);

        yieldDca.executeDCA();

        assertEq(swapper.lastSwapData(), data, "incorrect swap data");
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

    function _generateYield(int256 _percent) public {
        _generateYield(IERC4626(address(vault)), _percent);
    }

    function _convertSharesToAssetsFor(address _account) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(_account));
    }
}
