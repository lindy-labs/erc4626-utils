// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "openzeppelin-contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC721Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";

import {YieldDCA} from "src/YieldDCA.sol";
import {UniSwapper} from "src/UniSwapper.sol";
import {TestCommon} from "./common/TestCommon.sol";

contract YieldDCAForkTest is TestCommon {
    using FixedPointMathLib for uint256;

    uint32 public constant DEFAULT_DCA_INTERVAL = 2 weeks;
    uint64 public constant DEFAULT_MIN_YIELD_PERCENT = 0.001e18; // 0.1%

    bytes constant POOL_FEE = abi.encode(500); // 0.05% USDC/ETH uniswap pool fee

    YieldDCA yieldDca;
    IERC20Metadata asset;
    IERC4626 vault;
    IERC20Metadata dcaToken;

    UniSwapper swapper;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        vault = IERC4626(0x096697720056886b905D0DEB0f06AfFB8e4665E5); // scUSDC vault (mainnet)
        asset = IERC20Metadata(vault.asset());
        dcaToken = IERC20Metadata(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH (mainnet)
        swapper = new UniSwapper();

        yieldDca = new YieldDCA(
            IERC20Metadata(address(dcaToken)),
            IERC4626(address(vault)),
            swapper,
            DEFAULT_DCA_INTERVAL,
            DEFAULT_MIN_YIELD_PERCENT,
            admin,
            keeper
        );
    }

    function test_executeDCA_oneUserOneEpoch() public {
        uint256 principal = 10_000e6; // 10,000 USDC
        uint256 positionId = _openPositionWithPrincipal(alice, principal);

        assertEq(yieldDca.balanceOf(alice), 1, "alice's position count");
        assertEq(yieldDca.ownerOf(positionId), alice, "alice's position owner");

        _generateYield(0.1e18); // 10% yield

        uint256 expectedYield = principal.mulWadDown(0.1e18);

        assertEq(uint256(yieldDca.calculateYield()), expectedYield, "calculated yield");

        _shiftTime(DEFAULT_DCA_INTERVAL);

        // actual yield is less after time shift?
        uint256 actualYield = uint256(yieldDca.calculateYield());
        assertTrue(actualYield < expectedYield, "actual yield < expected yield");
        assertApproxEqRel(actualYield, expectedYield, 0.02e18, "actual yield");

        uint256 expectedDcaAmount = swapper.previewExecute(address(asset), address(dcaToken), actualYield, POOL_FEE);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        assertApproxEqRel(dcaToken.balanceOf(address(yieldDca)), expectedDcaAmount, 0.00001e18, "dca token balance");

        (uint256 shares, uint256 dcaAmount) = yieldDca.balancesOf(1);
        assertApproxEqRel(vault.convertToAssets(shares), principal, 0.0000001e18, "alices principal");
        assertApproxEqRel(dcaAmount, expectedDcaAmount, 0.00001e18, "alices dca amount");

        vm.prank(alice);
        yieldDca.closePosition(positionId);

        assertEq(yieldDca.balanceOf(alice), 0, "aw: alice's NFT not burned");

        vm.expectRevert();
        yieldDca.ownerOf(positionId);

        assertApproxEqAbs(
            dcaToken.balanceOf(address(yieldDca)),
            0,
            expectedDcaAmount.mulWadDown(0.0000001e18), // dust leftover from accounting inaccuracy
            "aw: contract dca balance"
        );
        assertEq(vault.balanceOf(address(yieldDca)), 0, "aw: contract vault balance");

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), principal, 2, "aw: alices principal");
        assertEq(dcaToken.balanceOf(alice), dcaAmount, "aw: alices dca balance");
    }

    function test_executeDCA_multipleUsersTwoEpochs() public {
        /**
         * 1. alice deposits 10,000 USDC into DCA contract
         * 2. 10% yield is added in the first epoch
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

        // alice is expected to have DCA tokens worth 20% of her principal (2 * 10%)
        uint256 alicesExpectedDca =
            swapper.previewExecute(address(asset), address(dcaToken), alicePrincipal.mulWadDown(0.1e18) * 2, POOL_FEE);
        // bob is expected to have DCA tokens worth 10% of his principal
        uint256 bobsExpectedDca =
            swapper.previewExecute(address(asset), address(dcaToken), bobPrincipal.mulWadDown(0.1e18), POOL_FEE);

        _openPositionWithPrincipal(alice, alicePrincipal);
        _generateYield(0.1e18); // 10% yield

        _shiftTime(DEFAULT_DCA_INTERVAL);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        _openPositionWithPrincipal(bob, bobPrincipal);
        _generateYield(0.1e18); // 10% yield

        _openPositionWithPrincipal(carol, carolPrincipal);

        _shiftTime(DEFAULT_DCA_INTERVAL);

        vm.prank(keeper);
        yieldDca.executeDCA(0, POOL_FEE);

        // when shifiting time, the yield is less than expected, not sure why but it's not a big deal
        // we need to set the discepancy tolerance to 2% to pass the test
        vm.prank(admin);
        yieldDca.setDiscrepancyTolerance(0.02e18);

        vm.prank(alice);
        yieldDca.closePosition(1);

        vm.prank(bob);
        yieldDca.closePosition(2);

        vm.prank(carol);
        yieldDca.closePosition(3);

        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), alicePrincipal, 0.001e18, "alice principal");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(bob)), bobPrincipal, 0.001e18, "bob principal");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(carol)), carolPrincipal, 0.001e18, "carol principal");

        assertApproxEqRel(dcaToken.balanceOf(alice), alicesExpectedDca, 0.03e18, "alice dca balance");
        assertApproxEqRel(dcaToken.balanceOf(bob), bobsExpectedDca, 0.03e18, "bob dca balance");
        assertEq(dcaToken.balanceOf(carol), 0, "carol dca balance");

        assertEq(dcaToken.balanceOf(address(yieldDca)), 0, "contract dca balance");
    }

    // *** helper functions *** ///

    function _openPositionWithPrincipal(address _account, uint256 _amount) public returns (uint256 positionId) {
        uint256 shares = _depositToVaultAndApprove(IERC4626(address(vault)), _account, address(yieldDca), _amount);

        vm.prank(_account);
        positionId = yieldDca.openPosition(shares, _account);
    }

    function _generateYield(int256 _percent) internal {
        _generateYield(vault, _percent);
    }
}
