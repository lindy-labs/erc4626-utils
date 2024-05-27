// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
 * @title CommonErrors
 * @notice A library for commonly used errors and respective checking functions.
 */
library CommonErrors {
    error AmountZero();
    error AddressZero();

    function revertIfZero(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }

    function revertIfZero(uint256 _amount, bytes4 _errorSelector) internal pure {
        if (_amount != 0) return;

        // Encode the error selector with no additional arguments
        bytes memory errorData = abi.encodeWithSelector(_errorSelector);
        // Use assembly to revert with the encoded error data
        assembly {
            let errorSize := mload(errorData)
            revert(add(errorData, 32), errorSize)
        }
    }

    function revertIfZero(address _address) internal pure {
        if (_address == address(0)) revert AddressZero();
    }

    function revertIfZero(address _address, bytes4 _errorSelector) internal pure {
        if (_address != address(0)) return;

        // Encode the error selector with no additional arguments
        bytes memory errorData = abi.encodeWithSelector(_errorSelector);
        // Use assembly to revert with the encoded error data
        assembly {
            let errorSize := mload(errorData)
            revert(add(errorData, 32), errorSize)
        }
    }
}
