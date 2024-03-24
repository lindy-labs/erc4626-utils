// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {UniSwapper} from "src/UniSwapper.sol";

contract UniSwapperTest is Test {
    using FixedPointMathLib for uint256;

    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ISwapper swapper;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18783515);

        swapper = new UniSwapper();
    }

    function test_execute_swapsUsdcForWeth() public {
        uint256 usdcSwapAmount = 2000e6;
        deal(address(usdc), address(this), usdcSwapAmount);
        usdc.approve(address(swapper), usdcSwapAmount);

        uint24 poolFee = 500;

        uint256 amountReceived = swapper.execute(address(usdc), address(weth), usdcSwapAmount, 0, abi.encode(poolFee));

        assertEq(usdc.balanceOf(address(this)), 0, "usdc balance");
        assertEq(amountReceived, weth.balanceOf(address(this)), "amount received");
        assertEq(weth.balanceOf(address(this)), 0.877770309464456727e18, "weth balance");
    }

    function test_execute_swapsWethForUsdc() public {
        uint256 wethSwapAmount = 2 ether;
        deal(address(weth), address(this), wethSwapAmount);
        weth.approve(address(swapper), wethSwapAmount);

        uint24 poolFee = 500;

        swapper.execute(address(weth), address(usdc), 1 ether, 0, abi.encode(poolFee));

        assertEq(weth.balanceOf(address(this)), 1 ether, "1st: weth balance");
        assertEq(usdc.balanceOf(address(this)), 2276206437, "1st: usdc balance");

        poolFee = 3000; // target another pool with 0.3% fee

        swapper.execute(address(weth), address(usdc), 1 ether, 0, abi.encode(poolFee));

        assertEq(weth.balanceOf(address(this)), 0, "2nd: weth balance");
        assertApproxEqAbs(
            usdc.balanceOf(address(this)),
            2276206437 + 2276206437,
            uint256(2276206437).mulWadDown(0.0025e18),
            "2nd: usdc balance"
        );
    }

    function test_execute_failsIfPoolFeeIsZero() public {
        uint256 usdcSwapAmount = 2000e6;
        deal(address(usdc), address(this), usdcSwapAmount);
        usdc.approve(address(swapper), usdcSwapAmount);

        uint24 poolFee = 0;

        vm.expectRevert();
        swapper.execute(address(usdc), address(weth), usdcSwapAmount, 0, abi.encode(poolFee));
    }

    function test_execute_failsIfAmountOutIsBelowMin() public {
        uint256 usdcSwapAmount = 2000e6;
        deal(address(usdc), address(this), usdcSwapAmount);
        usdc.approve(address(swapper), usdcSwapAmount);

        uint256 expectedToReceive = 0.877770309464456727e18;

        vm.expectRevert("Too little received");

        swapper.execute(address(usdc), address(weth), usdcSwapAmount, expectedToReceive + 1, abi.encode(500));
    }
}
