// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
 * @title CommonErrors
 * @notice A library for commonly used errors and respective checking functions.
 */
library CommonErrors {
    error ZeroAmount();
    error ZeroAddress();

    function revertIfZero(uint256 _amount) internal pure {
        if (_amount == 0) revert ZeroAmount();
    }

    function revertIfZero(uint256 _amount, bytes4 _errorSelector) internal pure {
        if (_amount != 0) return;

        _revertWithSelector(_errorSelector);
    }

    function revertIfZero(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function revertIfZero(address _address, bytes4 _errorSelector) internal pure {
        if (_address != address(0)) return;

        _revertWithSelector(_errorSelector);
    }

    function _revertWithSelector(bytes4 _selector) private pure {
        // Encode the error selector with no additional arguments
        bytes memory errorData = abi.encodeWithSelector(_selector);

        // Use assembly to revert with the encoded error data
        assembly {
            let errorSize := mload(errorData)
            revert(add(errorData, 32), errorSize)
        }
    }
}
