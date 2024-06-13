// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";

abstract contract TestCommon is Test {
    using FixedPointMathLib for uint256;

    address constant admin = address(0x01);
    address constant keeper = address(0x02);

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    uint256 davesPrivateKey = uint256(bytes32("0xDAVE"));
    address dave = vm.addr(davesPrivateKey);

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _signPermit(uint256 _ownerKey, address _token, address _spender, uint256 _amount, uint256 _deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(_ownerKey);
        bytes32 data = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(_token).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(PERMIT_TYPEHASH, owner, _spender, _amount, IERC20Permit(_token).nonces(owner), _deadline)
                )
            )
        );

        return vm.sign(_ownerKey, data);
    }

    function _depositToVault(IERC4626 _vault, address _from, uint256 _amount) internal returns (uint256 shares) {
        _dealAndApprove(IERC20(_vault.asset()), _from, address(_vault), _amount);

        vm.prank(_from);
        shares = _vault.deposit(_amount, _from);
    }

    function _approve(IERC20 _token, address _owner, address _spender, uint256 _amount) internal {
        vm.prank(_owner);
        _token.approve(address(_spender), _amount);
    }

    function _depositToVaultAndApprove(IERC4626 _vault, address _from, address _spender, uint256 _amount)
        internal
        returns (uint256 shares)
    {
        shares = _depositToVault(_vault, _from, _amount);
        _approve(IERC20(_vault), _from, _spender, shares);
    }

    function _dealAndApprove(IERC20 _token, address _owner, address _spender, uint256 _amount) internal {
        deal(address(_token), _owner, _amount);
        _approve(_token, _owner, _spender, _amount);
    }

    function _shiftTime(uint256 _period) internal {
        vm.warp(block.timestamp + _period);
    }

    function _generateYield(IERC4626 _vault, int256 _percent) internal {
        require(_percent >= -1e18, "TestCommon: percent must greater than or equal to -1e18");
        require(_percent != 0, "TestCommon: percent must be non-zero");

        IERC20 asset = IERC20(_vault.asset());
        uint256 balance = asset.balanceOf(address(_vault));
        uint256 totalAssets = _vault.totalAssets();
        uint256 endTotalAssets = totalAssets.mulWadUp(uint256(1e18 + _percent));
        uint256 endBalance = balance + endTotalAssets - totalAssets;

        deal(address(asset), address(_vault), endBalance);
    }
}
