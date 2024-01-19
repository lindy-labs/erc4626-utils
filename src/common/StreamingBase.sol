// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./Errors.sol";

abstract contract StreamingBase is Multicall {
    IERC4626 public immutable vault;

    constructor(IERC4626 _vault) {
        _checkZeroAddress(address(_vault));

        vault = _vault;
    }

    function _checkZeroAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert AddressZero();
    }

    function _checkShares(address _streamer, uint256 _shares) internal view {
        if (_shares == 0) revert ZeroShares();

        if (vault.allowance(_streamer, address(this)) < _shares) revert TransferExceedsAllowance();
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }
}
