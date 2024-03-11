// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldDCA} from "../src/YieldDCA.sol";
import {ISwapper} from "../src/ISwapper.sol";
import {SwapperMock} from "./mock/SwapperMock.sol";

contract YieldDCATest is Test {
    using FixedPointMathLib for uint256;

    YieldDCA yieldDca;
    MockERC20 asset;
    MockERC4626 vault;
    MockERC20 dcaToken;

    SwapperMock swapper;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        dcaToken = new MockERC20("DCA Token", "DCA", 18);
        swapper = new SwapperMock();

        dcaToken.mint(address(swapper), 10000 ether);
        yieldDca = new YieldDCA(IERC20(address(dcaToken)), IERC4626(address(vault)), swapper);
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

    // *** #executeDCA *** //

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
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        assertEq(yieldDca.currentEpoch(), ++currentEpoch, "epoch not incremented");

        // balanceOf asserts
        uint256 expectedYield = principal.mulWadDown(yieldPct);
        uint256 expectedDcaAmount = expectedYield.mulWadDown(exchangeRate);
        assertApproxEqAbs(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount, 3, "dca token balance");

        (uint256 sharesLeft, uint256 dcaAmount) = yieldDca.balanceOf(alice);
        assertEq(vault.convertToAssets(sharesLeft), principal, "balanceOf: principal");
        assertEq(dcaAmount, expectedDcaAmount, "balanceOf: dcaAmount");

        // step 4 - alice withdraws and gets 1 ether in shares and 1.5 DCA tokens
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaAmount, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), principal, 1, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);

        (uint256 balance, uint256 dcaBalance) = yieldDca.balanceOf(alice);
        assertEq(balance, 0, "alice's balance");
        assertEq(dcaBalance, 0, "alice's dca balance");
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
        swapper.setExchangeRate(2e18);
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        // step 5 - alice withdraws and gets 2 DCA tokens
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    function test_deposit_twoTimesInDifferentEpochs() public {
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
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        uint256 alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        // step 2 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 3 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(3e18);
        yieldDca.executeDCA();

        // step 4 - alice deposits again
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), 3e18, 0.00001e18, "dca token balance");

        // step 5 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 6 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(2e18);
        yieldDca.executeDCA();

        // step 7 - alice withdraws
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 7e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 2e18, 1, "principal");
    }

    function test_executeDCA_oneDepositMultipleEpochs() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether in principal
         * 2. yield generated is 5% over 200 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice withdraws and gets 1 ether in shares and gets 0.05 * 200 * 3 = 30 DCA tokens
         */
        uint256 principal = 1 ether;
        _depositIntoDca(alice, principal);

        // set exchange rate
        uint256 exchangeRate = 3e18;
        swapper.setExchangeRate(exchangeRate);
        uint256 yieldPerEpoch = 0.05e18; // 5%
        uint256 epochs = 200;

        // generate yield over all epochs
        for (uint256 i = 0; i < epochs; i++) {
            _addYield(yieldPerEpoch);

            _shiftTime(yieldDca.DCA_PERIOD());

            yieldDca.executeDCA();
        }

        assertEq(yieldDca.currentEpoch(), epochs + 1, "epoch not incremented");

        vm.prank(alice);
        yieldDca.withdraw();

        uint256 expectedDcaTokenBalance = epochs * principal.mulWadDown(yieldPerEpoch).mulWadDown(exchangeRate);
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "dca token balance");
        assertApproxEqRel(_convertSharesToAssetsFor(alice), principal, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);
        assertEq(dcaToken.balanceOf(address(yieldDca)), 0);
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
        uint256 firstExchangeRate = 3e18;
        swapper.setExchangeRate(firstExchangeRate);
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        // step 4 - bob deposits

        uint256 bobsPrincipal = 1 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 5 - generate 100% yield
        _addYield(1e18);

        // step 6 - dca
        uint256 secondExchangeRate = 2e18;
        swapper.setExchangeRate(secondExchangeRate);
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        // step 7 - alice withdraws and gets 5 DCA tokens
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "alice's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), alicesPrincipal, 1, "alice's principal");

        // step 8 - bob withdraws and gets 2 DCA tokens
        vm.prank(bob);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(bob), 2e18, 0.00001e18, "bob's dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), bobsPrincipal, 1, "bob's principal");
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
        uint256 firstExchangeRate = 3e18;
        swapper.setExchangeRate(firstExchangeRate);
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        // step 4 - bob deposits
        uint256 bobsPrincipal = 2 ether;
        _depositIntoDca(bob, bobsPrincipal);

        // step 5 - carol deposits
        uint256 carolsPrincipal = 1 ether;
        _depositIntoDca(carol, carolsPrincipal);

        // step 6 - generate 100% yield (ie 4 ether)
        _addYield(1e18);

        // step 7 - dca - buy 8 DCA tokens for 4 ether
        uint256 secondExchangeRate = 2e18;
        swapper.setExchangeRate(secondExchangeRate);
        _shiftTime(yieldDca.DCA_PERIOD());

        yieldDca.executeDCA();

        // step 8 - alice withdraws and gets 5 DCA tokens
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(alice), 1e18, 1, "principal");

        // step 9 - bob withdraws and gets 4 DCA tokens
        vm.prank(bob);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(bob), 4e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(bob), 2e18, 1, "principal");

        // step 10 - carol withdraws and gets 2 DCA tokens
        vm.prank(carol);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(carol), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(_convertSharesToAssetsFor(carol), 1e18, 1, "principal");
    }

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

    function _shiftTime(uint256 _period) internal {
        vm.warp(block.timestamp + _period);
    }

    function _convertSharesToAssetsFor(address _account) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(_account));
    }
}
