// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {YieldDCA} from "src/YieldDCA.sol";
import {UniSwapper} from "src/UniSwapper.sol";

contract YieldDCATest is Test {
    using FixedPointMathLib for uint256;

    uint256 public constant DEFAULT_DCA_INTERVAL = 2 weeks;

    bytes constant POOL_FEE = abi.encode(500); // 0.05% USDC/ETH uniswap pool fee

    YieldDCA yieldDca;
    IERC20 asset;
    IERC4626 vault;
    IERC20 dcaToken;

    UniSwapper swapper;

    address constant admin = address(0x01);
    address constant keeper = address(0x02);

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        vault = IERC4626(0x096697720056886b905D0DEB0f06AfFB8e4665E5); // scUSDC vault (mainnet)
        asset = IERC20(vault.asset());
        dcaToken = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH (mainnet)
        swapper = new UniSwapper();

        yieldDca = new YieldDCA(
            IERC20(address(dcaToken)), IERC4626(address(vault)), swapper, DEFAULT_DCA_INTERVAL, admin, keeper
        );
    }

    function test_executeDCA_oneUserOneEpoch() public {
        uint256 principal = 10_000e6; // 10,000 USDC
        _depositIntoDca(alice, principal);

        _addYield(0.1e18); // 10% yield

        uint256 expectedYield = principal.mulWadDown(0.1e18);

        assertEq(yieldDca.getYield(), expectedYield, "calculated yield");

        _shiftTime(DEFAULT_DCA_INTERVAL);

        // actual yield is less after time shift?
        uint256 actualYield = yieldDca.getYield();
        assertTrue(actualYield < expectedYield, "actual yield < expected yield");
        assertApproxEqRel(actualYield, expectedYield, 0.02e18, "actual yield");

        uint256 expectedDcaAmount = swapper.previewExecute(address(asset), address(dcaToken), actualYield, POOL_FEE);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        assertEq(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount, "dca token balance");

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqRel(vault.convertToAssets(shares), principal, 0.00001e18, "alices principal");
        assertApproxEqRel(dcaAmount, expectedDcaAmount, 0.00001e18, "alices dca amount");

        _withdrawAll(alice, 1);

        assertEq(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount - dcaAmount, "aw: contract dca balance");
        assertEq(vault.balanceOf(address(yieldDca)), 0, "aw: contract vault balance");

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), principal, 2, "aw: alices principal");
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "aw: alices dca balance");
    }

    function test_executeDCA_multipleUsersTwoEpochs() public {
        /**
         * 1. alice deposits 10,000 USDC into DCA
         * 2. 10% yield is added
         * 3. execute DCA
         * 4. bob deposits 5,000 USDC into DCA
         * 5. 10% yield is added
         * 6. carol deposits 15,000 USDC into DCA
         * 7. execute DCA
         * 8. alice withdraws
         * 9. bob withdraws
         * 10. carol withdraws
         */
        uint256 alicePrincipal = 10_000e6; // 10,000 USDC
        uint256 bobPrincipal = 5_000e6; // 5,000 USDC
        uint256 carolPrincipal = 15_000e6; // 15,000 USDC

        uint256 alicesExpectedDca =
            swapper.previewExecute(address(asset), address(dcaToken), alicePrincipal.mulWadDown(0.1e18) * 2, POOL_FEE);
        uint256 bobsExpectedDca =
            swapper.previewExecute(address(asset), address(dcaToken), bobPrincipal.mulWadDown(0.1e18), POOL_FEE);

        _depositIntoDca(alice, alicePrincipal);
        _addYield(0.1e18); // 10% yield

        _shiftTime(DEFAULT_DCA_INTERVAL);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        _depositIntoDca(bob, bobPrincipal);
        _addYield(0.1e18); // 10% yield

        _depositIntoDca(carol, carolPrincipal);

        _shiftTime(DEFAULT_DCA_INTERVAL);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        _withdrawAll(alice, 1);

        _withdrawAll(bob, 2);

        _withdrawAll(carol, 3);

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), alicePrincipal, 0.001e18, "alice principal");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(bob)), bobPrincipal, 0.001e18, "bob principal");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(carol)), carolPrincipal, 0.001e18, "carol principal");

        assertApproxEqRel(dcaToken.balanceOf(alice), alicesExpectedDca, 0.03e18, "alice dca balance");
        assertApproxEqRel(dcaToken.balanceOf(bob), bobsExpectedDca, 0.03e18, "bob dca balance");
        assertEq(dcaToken.balanceOf(carol), 0, "carol dca balance");

        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract dca balance");
    }

    // *** helper functions *** ///

    function _depositIntoDca(address _account, uint256 _amount) public returns (uint256 tokenId) {
        vm.startPrank(_account);

        deal(address(asset), _account, _amount);
        asset.approve(address(vault), _amount);
        uint256 shares = vault.deposit(_amount, _account);

        vault.approve(address(yieldDca), shares);
        tokenId = yieldDca.deposit(shares);

        vm.stopPrank();
    }

    function _addYield(uint256 _percent) internal {
        uint256 usdcBalance = asset.balanceOf(address(vault));
        uint256 yield = vault.totalAssets().mulWadDown(_percent);

        deal(address(asset), address(vault), usdcBalance + yield);
    }

    function _shiftTime(uint256 _period) internal {
        vm.warp(block.timestamp + _period);
    }

    function _withdrawAll(address _account, uint256 _id) internal {
        vm.startPrank(_account);

        (uint256 shares,) = yieldDca.balancesOf(_id);

        yieldDca.withdraw(shares, _id);

        vm.stopPrank();
    }
}
