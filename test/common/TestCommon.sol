// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";

abstract contract TestCommon is Test {
    using FixedPointMathLib for uint256;

    function _depositToVault(IERC4626 _vault, address _from, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_from);

        address asset = _vault.asset();

        deal(asset, _from, _amount);
        IERC20(asset).approve(address(_vault), _amount);

        shares = _vault.deposit(_amount, _from);

        vm.stopPrank();
    }

    function _approve(IERC20 _token, address _spender, address _from, uint256 _shares) internal {
        vm.prank(_from);
        _token.approve(address(_spender), _shares);
    }

    function _generateYield(IERC4626 _vault, int256 _percent) internal {
        require(_percent >= -1e18 && _percent <= 1e18, "TestCommon: percent must be inside -1e18 and 1e18");
        require(_percent != 0, "TestCommon: percent must be non-zero");

        IERC20 asset = IERC20(_vault.asset());
        uint256 balance = asset.balanceOf(address(_vault));
        uint256 totalAssets = _vault.totalAssets();
        uint256 endTotalAssets = totalAssets.mulWadUp(uint256(1e18 + _percent));
        uint256 endBalance = balance + endTotalAssets - totalAssets;

        deal(address(asset), address(_vault), endBalance);
    }
}
