// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldDCA} from "../src/YieldDCA.sol";
import {ISwapper} from "../src/ISwapper.sol";
import {SwapperMock} from "./mock/SwapperMock.sol";

contract YieldDCATest is Test {
    using FixedPointMathLib for uint256;

    event DCAIntervalUpdated(address indexed admin, uint256 newInterval);
    event SwapperUpdated(address indexed admin, address newSwapper);
    event Deposit(address indexed user, uint256 epoch, uint256 shares, uint256 principal);
    event Withdraw(address indexed user, uint256 epoch, uint256 principal, uint256 shares, uint256 dcaTokens);
    event DCAExecuted(uint256 epoch, uint256 yieldSpent, uint256 dcaBought, uint256 dcaPrice, uint256 sharePrice);

    uint256 public constant DEFAULT_DCA_INTERVAL = 2 weeks;

    YieldDCA yieldDca;
    MockERC20 asset;
    MockERC4626 vault;
    MockERC20 dcaToken;

    SwapperMock swapper;

    address constant admin = address(0x01);
    address constant keeper = address(0x02);

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        dcaToken = new MockERC20("DCA Token", "DCA", 18);
        swapper = new SwapperMock();

        dcaToken.mint(address(swapper), 10000 ether);
        yieldDca = new YieldDCA(
            IERC20(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, admin, keeper
        );
    }

    // *** #constructor *** //

    function test_constructor_initialState() public {
        assertEq(address(yieldDca.dcaToken()), address(dcaToken), "dca token");
        assertEq(address(yieldDca.vault()), address(vault), "vault");
        assertEq(address(yieldDca.swapper()), address(swapper), "swapper");

        assertEq(yieldDca.currentEpoch(), 1, "current epoch");
        assertEq(yieldDca.currentEpochTimestamp(), block.timestamp, "current epoch timestamp");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");

        assertTrue(yieldDca.hasRole(yieldDca.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertTrue(yieldDca.hasRole(yieldDca.KEEPER_ROLE(), keeper), "keeper role");
    }

    function test_constructor_dcaTokenZeroAddress() public {
        vm.expectRevert(YieldDCA.DcaTokenAddressZero.selector);
        yieldDca =
            new YieldDCA(IERC20(address(0)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, admin, keeper);
    }

    function test_constructor_vaultZeroAddress() public {
        vm.expectRevert(YieldDCA.VaultAddressZero.selector);
        yieldDca =
            new YieldDCA(IERC20(address(dcaToken)), IERC4626(address(0)), swapper, DEFAULT_DCA_INTERVAL, admin, keeper);
    }

    function test_constructor_swapperZeroAddress() public {
        vm.expectRevert(YieldDCA.SwapperAddressZero.selector);
        yieldDca = new YieldDCA(
            IERC20(address(dcaToken)),
            IERC4626(address(vault)),
            ISwapper(address(0)),
            DEFAULT_DCA_INTERVAL,
            admin,
            keeper
        );
    }

    function test_constructor_dcaTokenSameAsVaultAsset() public {
        vm.expectRevert(YieldDCA.DcaTokenSameAsVaultAsset.selector);
        yieldDca =
            new YieldDCA(IERC20(address(asset)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, admin, keeper);
    }

    function test_constructor_keeperZeroAddress() public {
        vm.expectRevert(YieldDCA.KeeperAddressZero.selector);
        yieldDca = new YieldDCA(
            IERC20(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, admin, address(0)
        );
    }

    function test_constructor_adminZeroAddress() public {
        vm.expectRevert(YieldDCA.AdminAddressZero.selector);
        yieldDca = new YieldDCA(
            IERC20(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, address(0), keeper
        );
    }

    // *** #setSwapper *** //

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
    }

    function test_setSwapper_emitsEvent() public {
        address newSwapper = address(0x03);

        vm.expectEmit(true, true, true, true);
        emit SwapperUpdated(admin, newSwapper);

        vm.prank(admin);
        yieldDca.setSwapper(ISwapper(newSwapper));
    }

    function test_setSwapper_failsIfNewSwapperIsZeroAddress() public {
        vm.expectRevert(YieldDCA.SwapperAddressZero.selector);
        vm.prank(admin);
        yieldDca.setSwapper(ISwapper(address(0)));
    }

    // *** #setDcaInterval *** //

    function test_setDcaInterval_failsIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.setDcaInterval(1 weeks);
    }

    function test_setDcaInterval_updatesDcaInterval() public {
        uint256 newInterval = 2 weeks;

        vm.prank(admin);
        yieldDca.setDcaInterval(newInterval);

        assertEq(yieldDca.dcaInterval(), newInterval);
    }

    function test_setDcaInterval_emitsEvent() public {
        uint256 newInterval = 3 weeks;

        vm.expectEmit(true, true, true, true);
        emit DCAIntervalUpdated(admin, newInterval);

        vm.prank(admin);
        yieldDca.setDcaInterval(newInterval);
    }

    function test_setDcaInterval_failsIfIntervalIsLessThanMin() public {
        uint256 invalidInterval = yieldDca.MIN_DCA_INTERVAL() - 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCA.DcaIntervalNotAllowed.selector);
        yieldDca.setDcaInterval(invalidInterval);
    }

    function test_setDcaInterval_failsIfIntervalIsGreaterThanMax() public {
        uint256 invalidInterval = yieldDca.MAX_DCA_INTERVAL() + 1;

        vm.prank(admin);
        vm.expectRevert(YieldDCA.DcaIntervalNotAllowed.selector);
        yieldDca.setDcaInterval(invalidInterval);
    }

    // *** #deposit *** //

    function test_deposit_transfersSharesToDcaContract() public {
        uint256 principal = 1 ether;
        asset.mint(alice, principal);

        vm.startPrank(alice);
        asset.approve(address(vault), principal);
        uint256 shares = vault.deposit(principal, alice);
        vault.approve(address(yieldDca), shares);

        yieldDca.deposit(shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, shares, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipalDeposited(), principal, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_deposit_emitsEvent() public {
        uint256 principal = 1 ether;
        asset.mint(alice, principal);

        vm.startPrank(alice);
        asset.approve(address(vault), principal);
        uint256 shares = vault.deposit(principal, alice);
        vault.approve(address(yieldDca), shares);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, 1, shares, principal);

        yieldDca.deposit(shares);
        vm.stopPrank();
    }

    function test_deposit_worksMultipleTimesInSameEpoch() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositIntoDca(alice, principal);

        // repeat the deposit with same amount
        _depositIntoDca(alice, principal);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), shares * 2, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, shares * 2, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipalDeposited(), principal * 2, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_deposit_subsequentDepositsDontAffectSharesAndDcaBalances() public {
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // add 100% yield
        _addYield(1e18);

        _executeDcaAtExchangeRate(1e18);

        uint256 expectedDcaAmount = 1 ether;

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, vault.convertToShares(principal), "1st: alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "1st: alice's dca balance");

        // repeat the deposit with same principal amount
        uint256 addedPrincipal = 3 ether;
        _depositIntoDca(alice, addedPrincipal);

        (balance, dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, vault.convertToShares(principal + addedPrincipal), "2nd: alice's balance");
        assertEq(dcaBalance, expectedDcaAmount, "2nd: alice's dca balance");
    }

    function test_deposit_restoresUnrealizedYieldDueToSomeAccountsExperiencingNegativeYield() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% (alice has 1 ether in principal and 1 ether in yield)
         * 3. bob deposits 1 ether
         * 4. from this point yield becomes negative -20%, bob is 0.8 ether in principal and alice has 1.6 ether (0.6 in yield)
         *      total principal = 2 ether, total assets = 2.4 ether, so yield is 0.4 ether
         * 5. execute DCA at 2:1 exchange, 0.4 ether = 0.8 DCA token (bob gets 0 DCA tokens and alice gets 0.8 DCA token but should be entitled to 1.2 DCA tokens)
         *      this creates a discrepancy in dca distribution of 0.4 DCA tokens
         * 6. again yield generated is 50%, enough to recover bob's loss (from 0.8 to 1.2 ether)
         *      total principal = 2 ether, total assets = 3 ether, so usable yield is 1 ether
         *      alices will get half of the yield, ie 0.5 ether since her principal is equal to bob's
         * 7. execute DCA at 2:1 exchange, 1 ether = 2 DCA token (bob should get 0.4 DCA tokens and alice 1.6 DCA token)
         *      due to the way accounting works, alice will get 1 DCA token from this distribution and 1.2 from previous so 2.2 DCA tokens
         *      bob will get 0.4 DCA tokens as expected, however total DCA tokens bought is 2.8! -> 0.2 are now undistributed!!!
         * 8. bob deposits 1 ether and thus updates the discrepancy in dca distribution to 0.2 DCA tokens
         * 9. alice withdraws principal and should get 2.2 DCA tokens + share of 0.2 undistributed DCA tokens
         *      since alices principal is now 1/3 of the total principal, she should get 1/3 of the pending dca tokens
         *      alice gets: 2.2 + 1/3 * 0.2 = 2266666666666666667 DCA tokens
         * 10. bob withdraws and gets 0.4 + 2/3 * 0.2 = 0.533333333333333333 DCA tokens
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - bob deposits
        uint256 bobsPrincipal = 1 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 4 - generate -20% yield
        _removeYield(0.2e18);

        // step 5 - dca - buy 0.8 DCA tokens for 0.4 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(dcaToken.balanceOf(address(yieldDca)), 0.8e18, "dca token balance not 0.8");

        // step 6 - generate 50% yield
        _addYield(0.5e18);

        // step 7 - dca - buy 2 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(dcaToken.balanceOf(address(yieldDca)), 2.8e18, "dca token balance not 2.8");

        // step 8 - deposit 1 ether
        _depositIntoDca(bob, 1 ether);

        assertEq(yieldDca.pendingDcaAllocation(), 0.2e18, "undistributed dca");

        // step 9 - alice withdraws and gets 2.3 DCA tokens
        (uint256 remainingShares, uint256 dcaAmount) = yieldDca.balanceOf(alice);
        assertApproxEqAbs(
            vault.convertToAssets(remainingShares), alicesPrincipal, 5, "alice's principal before withdraw"
        );

        assertApproxEqAbs(dcaAmount, 2.2e18, 5, "alice's dca token balance before withdraw");

        _withdrawAll(alice);

        assertApproxEqAbs(dcaToken.balanceOf(alice), 2.266666666666666667e18, 5, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1e18, 5, "alice's principal");

        // step 10 - bob withdraws and gets 0.533333333333333333 DCA tokens
        _withdrawAll(bob);

        assertApproxEqAbs(dcaToken.balanceOf(bob), 0.533333333333333333e18, 5, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 2e18, 5, "bob's principal");

        // assert contract's end balances
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), 0, 10, "contract's dca token balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");
        assertEq(yieldDca.pendingDcaAllocation(), 0, "undistributed dca");
    }

    // *** #executeDCA *** //

    function test_executeDCA_failsIfCallerIsNotKeeper() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, yieldDca.KEEPER_ROLE()
            )
        );

        vm.prank(alice);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_failsIfNotEnoughTimePassed() public {
        _depositIntoDca(alice, 1 ether);

        _shiftTime(yieldDca.dcaInterval() - 1);

        vm.expectRevert(YieldDCA.DcaIntervalNotPassed.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_failsIfNoPrincipalDeposited() public {
        uint256 amount = 1 ether;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));

        // send shares directly to the yieldDca contract
        vault.transfer(address(yieldDca), shares);

        _shiftTime(yieldDca.dcaInterval() - 1);

        assertEq(vault.balanceOf(address(yieldDca)), shares, "contract's balance");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");

        vm.expectRevert(YieldDCA.NoPrincipalDeposited.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_failsIfYieldIsZero() public {
        _depositIntoDca(alice, 1 ether);

        _shiftTime(yieldDca.dcaInterval());

        vm.expectRevert(YieldDCA.DcaYieldZero.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_failsIfYieldIsNegative() public {
        _depositIntoDca(alice, 1 ether);

        _shiftTime(yieldDca.dcaInterval());

        uint256 totalAssets = vault.totalAssets();
        // remove 10% of total assets
        _removeYield(0.1e18);
        assertApproxEqAbs(vault.totalAssets(), totalAssets.mulWadDown(0.9e18), 1);

        vm.expectRevert(YieldDCA.DcaYieldZero.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_failsIfAmountReceivedIsBelowMin() public {
        _depositIntoDca(alice, 1 ether);

        _shiftTime(yieldDca.dcaInterval());
        _addYield(1e18);

        uint256 expectedToReceive = 2 ether;
        swapper.setExchangeRate(2e18);

        vm.expectRevert(YieldDCA.DcaAmountReceivedTooLow.selector);

        vm.prank(keeper);
        yieldDca.executeDCA(expectedToReceive + 1);
    }

    function test_executeDCA_oneDepositOneEpoch() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 50%, ie 0.5 ether
         * 3. execute DCA at 3:1 exchange rate, ie by 1.5 DCA for 0.5 ether in yield
         * 4. alice withdraws and gets 1 ether in shares and 1.5 DCA token
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // step 2 - generate 50% yield
        uint256 yieldPct = 0.5e18;
        _addYield(yieldPct);

        // step 3 - dca - buy 1.5 DCA tokens for 0.5 ether
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "dca token balance not 0");

        uint256 currentEpoch = yieldDca.currentEpoch();
        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        _shiftTime(yieldDca.dcaInterval());

        vm.prank(keeper);
        yieldDca.executeDCA(0);

        assertEq(yieldDca.currentEpoch(), ++currentEpoch, "epoch not incremented");

        // balanceOf asserts
        uint256 expectedYield = principal.mulWadDown(yieldPct);
        uint256 expectedDcaAmount = expectedYield.mulWadDown(exchangeRate);
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount, 3, "dca token balance");

        (uint256 sharesLeft, uint256 dcaAmount) = yieldDca.balanceOf(alice);
        assertEq(vault.convertToAssets(sharesLeft), principal, "balanceOf: principal");
        assertEq(dcaAmount, expectedDcaAmount, "balanceOf: dcaAmount");

        // step 4 - alice withdraws and gets 1 ether in shares and 1.5 DCA tokens
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaAmount, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), principal, 1, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, 0, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
    }

    function test_executeDca_emitsEvent() public {
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // generate 50% yield
        uint256 yieldPct = 0.5e18;
        _addYield(yieldPct);

        // dca - buy 2.5 DCA tokens for 0.5 ether
        uint256 currentEpoch = yieldDca.currentEpoch();
        uint256 exchangeRate = 5e18;
        swapper.setExchangeRate(exchangeRate);
        _shiftTime(yieldDca.dcaInterval());

        uint256 expectedYield = 0.5 ether + 1; // 1 is the rounding error
        uint256 expectedDcaAmount = expectedYield.mulWadDown(exchangeRate);
        uint256 expectedDcaPrice = 5e18;
        uint256 expectedSharePrice = 1.5e18; // 50% yield

        vm.expectEmit(true, true, true, true);
        emit DCAExecuted(currentEpoch, expectedYield, expectedDcaAmount, expectedDcaPrice, expectedSharePrice);

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }

    function test_executeDCA_twoDepositsInSameEpoch() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. alice deposits 1 ether again
         * 4. execute DCA at 2:1 exchange, (alice gets 2 DCA tokens)
         * 5. alice withdraws and gets 2 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        _depositIntoDca(alice, 1 ether);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - alice deposits again (this one doesn't generate yield)
        _depositIntoDca(alice, 1 ether);

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertEq(dcaToken.balanceOf(alice), 0, "dca token balance");

        // step 4 - dca - buy 2 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(2e18);

        // step 5 - alice withdraws and gets 2 DCA tokens
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    function test_executeDca_twoDepositsInDifferentEpochs() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, (alice gets 3 DCA tokens)
         * 4. alice deposits 1 ether again (receives 3 DCA tokens)
         * 5. generate 100% yield in the second epoch, ie 2 ether
         * 6. execute DCA at 2:1 exchange, (alice gets 4 DCA tokens)
         * 7. alice withdraws and gets 2 ether in shares and 4 DCA tokens (7 in total)
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 4 - alice deposits again
        _depositIntoDca(alice, principal);

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), 0, 0.00001e18, "dca token balance");

        // step 5 - generate 100% yield
        _addYield(1e18);

        // step 6 - dca
        _executeDcaAtExchangeRate(2e18);

        // step 7 - alice withdraws
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), 7e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    // TODO: make this a fuzzing test?
    function test_executeDCA_oneDeposit200Epochs() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 5% over 200 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice withdraws and gets 1 ether in shares and gets 0.05 * 200 * 3 = 30 DCA tokens
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.05e18; // 5%
        uint256 epochs = 200;

        // step 2 & 3 - generate 5% yield over 200 epochs and do DCA
        for (uint256 i = 0; i < epochs; i++) {
            _addYield(yieldPerEpoch);

            _shiftTime(yieldDca.dcaInterval());

            vm.prank(keeper);
            yieldDca.executeDCA(0);
        }

        assertEq(yieldDca.currentEpoch(), epochs + 1, "epoch not incremented");

        // step 4 - alice withdraws and gets 30 DCA tokens
        _withdrawAll(alice);

        uint256 expectedDcaTokenBalance = epochs * principal.mulWadDown(yieldPerEpoch).mulWadDown(exchangeRate);
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "dca token balance");
        assertApproxEqRel(_convertSharesToAssetsFor(alice), principal, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca token balance");
    }

    function test_executeDCA_oneDeposit5Epochs() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 5% over 5 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice withdraws and gets 1 ether in shares and gets 0.05 * 5 * 3 = 0.75 DCA tokens
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.05e18; // 5%
        uint256 epochs = 5;

        // step 2 & 3 - generate 5% yield over 5 epochs and do DCA
        for (uint256 i = 0; i < epochs; i++) {
            _addYield(yieldPerEpoch);

            _shiftTime(yieldDca.dcaInterval());

            vm.prank(keeper);
            yieldDca.executeDCA(0);
        }

        // step 4 - alice withdraws and gets 30 DCA tokens
        _withdrawAll(alice);

        uint256 expectedDcaTokenBalance = epochs * principal.mulWadDown(yieldPerEpoch).mulWadDown(exchangeRate);
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "dca token balance");
        assertApproxEqRel(_convertSharesToAssetsFor(alice), principal, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        // there can be some leftover dca tokens because of rounding errors
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), 0, 3 * epochs, "contract's dca token balance");
    }

    function test_executeDCA_twoDeposits_separatesBalancesOverTwoEpochsCorrectly() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice gets 3 DCA tokens)
         * 4. bob deposits 1 ether
         * 5. yield generated is 100% in the second epoch, ie 2 ether (from 2 deposits)
         * 6. execute DCA at 2:1 exchange, (bob gets 2 DCA tokens and alice gets 2 DCA tokens)
         * 7. alice withdraws and gets 1 ether in shares and 5 DCA tokens
         * 8. bob withdraws and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 4 - bob deposits

        uint256 bobsPrincipal = 1 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 5 - generate 100% yield
        _addYield(1e18);

        // step 6 - dca
        _executeDcaAtExchangeRate(2e18);

        // step 7 - alice withdraws and gets 5 DCA tokens
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 8 - bob withdraws and gets 2 DCA tokens
        _withdrawAll(bob);

        assertApproxEqRel(dcaToken.balanceOf(bob), 2e18, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 1, "bob's principal");
    }

    function test_executeDCA_twoDepositsInSameEpochWithDifferentYield() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. bob deposits 1 ether into vault only
         * 3. yield generated is 100% in the first epoch, ie 1 ether
         * 4. bob deposits to DCA contract
         * 5. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice gets 3 DCA tokens)
         * 6. alice withdraws and gets 3 DCA tokens and 1 ether in principal
         * 7. bob is entitled to 0 DCA tokens
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - bob deposits into vault
        vm.startPrank(bob);
        uint256 bobsPrincipal = 1 ether;
        asset.mint(bob, bobsPrincipal);
        asset.approve(address(vault), bobsPrincipal);
        uint256 bobsShares = vault.deposit(bobsPrincipal, bob);

        // step 3 - generate 100% yield
        _addYield(1e18);

        // step 4 - bob deposits into DCA
        vault.approve(address(yieldDca), bobsShares);
        yieldDca.deposit(bobsShares);
        vm.stopPrank();

        // step 4 - dca
        _executeDcaAtExchangeRate(3e18);

        // step 5 - alice withdraws and gets 5 DCA tokens
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), 3e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 6 - bob withdraws and gets 2 DCA tokens
        _withdrawAll(bob);

        assertApproxEqRel(dcaToken.balanceOf(bob), 0, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 2 * bobsPrincipal, 1, "bob's principal");
    }

    function test_executeDCA_multipleUserDepositsInTwoEpochs_balanceAndDcaAmountSeparatedCorrectly() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice gets 3 DCA tokens)
         * 4. bob deposits 2 ether
         * 5. carol deposits 1 ether
         * 6. yield generated is 100% in the second epoch, ie 4 ether (from 3 deposits of 4 ether in total)
         * 7. execute DCA at 2:1 exchange, (bob gets 4 DCA tokens and alice & carol get 2 DCA tokens each)
         * 8. alice withdraws and gets 1 ether in shares and 5 DCA tokens
         * 9. bob withdraws and gets 2 ether in shares and 4 DCA tokens
         * 10. carol withdraws and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - dca - buy 3 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(3e18);

        // step 4 - bob deposits
        uint256 bobsPrincipal = 2 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 5 - carol deposits
        uint256 carolsPrincipal = 1 ether;
        _depositIntoDca(carol, carolsPrincipal);

        // step 6 - generate 100% yield (ie 4 ether)
        _addYield(1e18);

        // step 7 - dca - buy 8 DCA tokens for 4 ether
        _executeDcaAtExchangeRate(2e18);

        // step 8 - alice withdraws and gets 5 DCA tokens
        _withdrawAll(alice);

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1e18, 1, "principal");

        // step 9 - bob withdraws and gets 4 DCA tokens
        _withdrawAll(bob);

        assertApproxEqRel(dcaToken.balanceOf(bob), 4e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 2e18, 1, "principal");

        // step 10 - carol withdraws and gets 2 DCA tokens
        _withdrawAll(carol);

        assertApproxEqRel(dcaToken.balanceOf(carol), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(carol), 1e18, 1, "principal");
    }

    function test_executeDCA_correctAccountingIfOneUserHasNegativeYield() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 4:1 exchange, 4 DCA tokens = 1 ether (alice gets 4 DCA tokens)
         * 4. again yield generated is 100% (1 ether)
         * 5. bob deposits 1 ether
         * 6. at this point yield becomes negative -25%, alice still has 0.5 ether in yield but bob is underwater 0.25 ether.
         *      total principal variable is 2 ether but shares are worth 3 * 0.75 = 2.25 ether, so only 0.25 ether in yield can be spent.
         *      this means that bob's loss of 0.25 is is "eating up" the yield from alice's gain of 0.5.
         *      however this is not a permanent loss, and as bob regains his principal, alice will regain part of her yield but not the entirety of it
         *      because of the accounting logic in the contract. There will be some discrepancy in the DCA token distribution, which will be resolved when
         *      users with negative yield regain their principal and interact with the contract again.
         *
         * 7. execute DCA at 2:1 exchange, 0.25 ether = 0.5 DCA token (bob gets 0 DCA tokens and alice gets 0.5 DCA token)
         * 8. alice withdraws and gets 1 ether in shares and 4.5 DCA tokens
         * 9. bob withdraws and gets 0.75 ether in shares and 0 DCA tokens
         * TODO: - check this
         * 10. 0.25 ether is left in the contract as yield? inconsistent state?
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - dca - buy 4 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(4e18);

        // step 4 - generate 100% yield
        _addYield(1e18);

        // step 5 - bob deposits
        uint256 bobsPrincipal = 1 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 6 - generate -25% yield
        _removeYield(0.25e18);

        // step 7 - dca - buy 1 DCA token for 0.5 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(yieldDca.totalPrincipalDeposited(), 2e18, "total principal deposited");

        // step 8 - alice's balance is 1 ether in principal and 5 DCA tokens
        (uint256 shares, uint256 dcaAmount) = yieldDca.balanceOf(alice);
        assertApproxEqAbs(vault.convertToAssets(shares), alicesPrincipal, 2, "bw: alice's principal");
        assertApproxEqRel(dcaAmount, 5e18, 0.00001e18, "bw: alice's dca token balance");

        _withdrawAll(alice);

        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 2, "aw: alice's principal");
        assertApproxEqRel(dcaToken.balanceOf(alice), 4.5e18, 0.00001e18, "aw: alice's dca token balance");

        // step 9 - bob's balance is 1.5 ether in principal and 0 DCA tokens
        (shares, dcaAmount) = yieldDca.balanceOf(bob);
        assertApproxEqRel(vault.convertToAssets(shares), 0.75e18, 0.00001e18, "bob's principal");
        assertEq(dcaAmount, 0, "bob's dca token balance");

        _withdrawAll(bob);

        assertEq(_convertSharesToAssetsFor(bob), bobsPrincipal.mulWadDown(0.75e18), "aw: bob's principal");
        assertEq(dcaToken.balanceOf(bob), 0, "aw: bob's dca token balance");

        // step 10 - 0.25 ether is left in the contract as yield
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");

        uint256 yieldInShares = yieldDca.calculateCurrentYieldInShares();

        assertEq(vault.balanceOf(address(yieldDca)), yieldInShares, "contract's balance");
        assertApproxEqAbs(vault.convertToAssets(yieldInShares), 0.25 ether, 5, "contract's assets");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");
    }

    // *** #withdraw *** //

    function test_withdraw_failsIfNoDepositWasMade() public {
        vm.expectRevert(YieldDCA.NoDepositFound.selector);
        yieldDca.withdraw(0);
    }

    function test_withdraw_failsIfTryingToWithdrawMoreThanAvaiable() public {
        uint256 shares = _depositIntoDca(alice, 1 ether);

        vm.expectRevert(YieldDCA.InsufficientSharesToWithdraw.selector);
        vm.prank(alice);
        yieldDca.withdraw(shares + 1);
    }

    function test_withdraw_worksInSameEpochAsDeposit() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositIntoDca(alice, principal);

        uint256 toWithdraw = _getSharesBalanceInDcaFor(alice);
        vm.prank(alice);
        yieldDca.withdraw(toWithdraw);

        assertEq(vault.balanceOf(alice), shares, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, 0, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
    }

    function test_withdraw_withdrawsOnlySharesIfDcaTokensNotEarned() public {
        uint256 principal = 1 ether;
        uint256 shares = _depositIntoDca(alice, principal);

        _addYield(1e18);
        _shiftTime(yieldDca.dcaInterval());

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, shares, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
        assertEq(yieldDca.totalPrincipalDeposited(), principal, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);

        uint256 toWithdraw = _getSharesBalanceInDcaFor(alice);
        vm.prank(alice);
        yieldDca.withdraw(toWithdraw);

        assertEq(vault.balanceOf(alice), shares, "alice's balance");
        assertEq(vault.convertToAssets(shares), principal * 2, "alice's assets");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
        assertEq(dcaToken.balanceOf(alice), 0, "alice's dca balance");
    }

    function test_withdraw_withdrawsOnlyDcaTokensWhenParamIs0() public {
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        _addYield(1e18);

        _executeDcaAtExchangeRate(1e18);

        uint256 dcaAmount = 1 ether;

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, vault.convertToShares(principal), "alice's balance");
        assertEq(dcaBalance, dcaAmount, "alice's dca balance");
        assertEq(yieldDca.totalPrincipalDeposited(), principal, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), dcaAmount);

        vm.prank(alice);
        yieldDca.withdraw(0);

        assertEq(vault.balanceOf(alice), 0, "alice's balance");
        assertEq(vault.balanceOf(address(yieldDca)), vault.convertToShares(principal), "contract's balance");
        assertEq(yieldDca.totalPrincipalDeposited(), principal, "total principal deposited");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "alice's dca balance");
    }

    function test_withdraw_worksForPartialWithdraws() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether
         * 4. alice does partial withdraw of 1/2 principal (0.5 ether) and receives 3 DCA tokens
         * 5. again yield is generated at 100% (ie 0.5 ether)
         * 6. execute DCA at 3:1 exchange, 1.5 DCA tokens = 0.5 ether
         * 7. withdraws remaining 0.5 ether and receives 1.5 DCA tokens (1 ether principal and 4.5 DCA tokens in total)
         */

        // step 1 - alice deposits
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - dca - buy 3 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(3e18);

        // step 4 - alice withdraws 1/2 principal
        uint256 toWithdraw = vault.convertToShares(principal / 2);
        vm.prank(alice);
        yieldDca.withdraw(toWithdraw);

        assertEq(vault.balanceOf(alice), toWithdraw, "alice's balance");
        assertEq(dcaToken.balanceOf(alice), 3e18, "alice's dca balance");

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(dcaBalance, 0, "alice's dca balance in contract");
        assertEq(balance, vault.convertToShares(principal / 2), "alice's balance in contract");

        // step 5 - generate 100% yield
        _addYield(1e18);
        // after doubilg again, alice's balance should be 1 ether
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1 ether, 1, "alice's principal");

        // step 6 - dca - buy 1.5 DCA tokens for 0.5 ether
        _executeDcaAtExchangeRate(3e18);

        // step 7 - withdraw remaining 0.5 ether
        toWithdraw = vault.convertToShares(principal / 2);
        vm.prank(alice);
        yieldDca.withdraw(toWithdraw);

        assertApproxEqRel(dcaToken.balanceOf(alice), 4.5e18, 0.00001e18, "alice's dca balance");
        // after withdrawing remaining 0.5 ether, alice's balance should be 1.5 ether
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1.5 ether, 1, "alice's principal");

        (balance, dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, 0, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");

        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract's dca balance");
    }

    function test_withdraw_emitsEvent() public {
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        _addYield(0.5e18);

        _executeDcaAtExchangeRate(5e18);

        (uint256 shares, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        uint256 toWithdraw = shares / 2;
        uint256 principalToWithdraw = vault.convertToAssets(toWithdraw);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alice, 2, principalToWithdraw, toWithdraw, dcaBalance);

        vm.prank(alice);
        (uint256 principalWithdrawn, uint256 dcaWithdrawn) = yieldDca.withdraw(toWithdraw);
        assertEq(principalWithdrawn, principalToWithdraw, "principal withdrawn");
        assertEq(dcaWithdrawn, dcaBalance, "dca withdrawn");
    }

    function test_withdraw_restoresUnrealizedYieldDueToSomeAccountsExperiencingNegativeYield() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% (alice has 1 ether in principal and 1 ether in yield)
         * 3. bob deposits 1 ether
         * 4. from this point yield becomes negative -20%, bob is 0.8 ether in principal and alice has 1.6 ether (0.6 in yield)
         *      total principal = 2 ether, total assets = 2.4 ether, so yield is 0.4 ether
         * 5. execute DCA at 2:1 exchange, 0.4 ether = 0.8 DCA token (bob gets 0 DCA tokens and alice gets 0.8 DCA token but should be entitled to 1.2 DCA tokens)
         * 6. again yield generated is 50%, enough to recover bob's loss (from 0.8 to 1.2 ether)
         *      total principal = 2 ether, total assets = 3 ether, so usable yield is 1 ether
         * 7. execute DCA at 2:1 exchange, 1 ether = 2 DCA token (bob gets 0.4 DCA tokens and alice gets 1.6 DCA token)
         * 8. alice withdraws principal and should also get 2.4 DCA tokens
         *      but instead she gets 2.3 DCA tokens (due to dca distribution discrepancy)
         * 9. bob withdraws principal and should also get 0.4 DCA tokens
         *      but instead he gets 0.5 DCA tokens (due to dca distribution discrepancy)
         */

        // step 1 - alice deposits
        uint256 alicesPrincipal = 1 ether;
        _depositIntoDca(alice, alicesPrincipal);

        // step 2 - generate 100% yield
        _addYield(1e18);

        // step 3 - bob deposits
        uint256 bobsPrincipal = 1 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 4 - generate -20% yield
        _removeYield(0.2e18);

        // step 5 - dca - buy 0.8 DCA tokens for 0.4 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(dcaToken.balanceOf(address(yieldDca)), 0.8e18, "dca token balance not 0.8");

        // step 6 - generate 50% yield
        _addYield(0.5e18);

        // step 7 - dca - buy 2 DCA tokens for 1 ether
        _executeDcaAtExchangeRate(2e18);

        assertEq(dcaToken.balanceOf(address(yieldDca)), 2.8e18, "dca token balance not 2.8");

        // step 8 - bob withdraws and gets 0.5 DCA tokens
        _withdrawAll(bob);

        assertApproxEqAbs(dcaToken.balanceOf(bob), 0.5e18, 5, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 1e18, 5, "bob's principal");

        // step 9 - alice withdraws and gets 2.3 DCA tokens
        _withdrawAll(alice);

        assertApproxEqAbs(dcaToken.balanceOf(alice), 2.3e18, 5, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1e18, 5, "alice's principal");

        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), 0, 10, "contract's dca token balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "contract's balance");
        assertEq(yieldDca.totalPrincipalDeposited(), 0, "total principal deposited");
        assertEq(yieldDca.pendingDcaAllocation(), 0, "undistributed dca");
    }

    // *** helper functions *** ///

    function _depositIntoDca(address _account, uint256 _amount) public returns (uint256 shares) {
        vm.startPrank(_account);

        asset.mint(_account, _amount);
        asset.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _account);

        vault.approve(address(yieldDca), shares);
        yieldDca.deposit(shares);

        vm.stopPrank();
    }

    function _addYield(uint256 _percent) internal {
        asset.mint(address(vault), asset.balanceOf(address(vault)).mulWadDown(_percent));
    }

    function _removeYield(uint256 _percent) internal {
        asset.burn(address(vault), asset.balanceOf(address(vault)).mulWadDown(_percent));
    }

    function _shiftTime(uint256 _period) internal {
        vm.warp(block.timestamp + _period);
    }

    function _convertSharesToAssetsFor(address _account) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(_account));
    }

    function _getSharesBalanceInDcaFor(address _account) internal view returns (uint256 shares) {
        (shares,) = yieldDca.balanceOf(_account);
    }

    function _withdrawAll(address _account) internal {
        vm.startPrank(_account);

        yieldDca.withdraw(_getSharesBalanceInDcaFor(_account));

        vm.stopPrank();
    }

    function _executeDcaAtExchangeRate(uint256 _exchangeRate) internal {
        swapper.setExchangeRate(_exchangeRate);
        _shiftTime(yieldDca.dcaInterval());

        vm.prank(keeper);
        yieldDca.executeDCA(0);
    }
}

contract Hacked {
    address immutable vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function stealFunds() external {
        IERC20(vault).approve(address(0x05), type(uint256).max);
        uint256 balance = IERC20(vault).balanceOf(address(this));

        IERC20(vault).transfer(address(0x05), balance);
    }
}
