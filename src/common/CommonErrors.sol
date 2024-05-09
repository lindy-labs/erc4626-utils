// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
 * @title CommonErrors
 * @notice A library for commonly used errors and respective checking functions.
 */
library CommonErrors {
    error AmountZero();
    error AddressZero();

    function checkIsZero(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }

    function checkIsZero(address _address) internal pure {
        if (_address == address(0)) revert AddressZero();
    }
}
