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
    address public immutable token;

    function _checkZeroAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert AddressZero();
    }

    function _checkAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }
}
