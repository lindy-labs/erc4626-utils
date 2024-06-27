// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {CommonErrors} from "./common/CommonErrors.sol";
import {YieldDCABase} from "./YieldDCABase.sol";

/**
 * @title YieldDCASimple
 * @notice Implements a simplified Dollar Cost Averaging (DCA) strategy by utilizing the yield generated by an ERC4626 vault.
 * @dev This contract automates the DCA strategy by regularly converting the yield generated by an ERC4626 vault into a specified ERC20 DCA token at regular intervals, called epochs. Unlike `YieldDCAControlled`, this contract does not use a swapper contract and does not require role-based execution control.
 *
 * ## Key Features
 * - **Position Management:** Allows users and their approved operators to open, close, increase, and reduce DCA positions represented by ERC721 tokens.
 * - **Automatic Yield Conversion:** Converts yield to DCA tokens at fixed intervals (epochs).
 * - **Position Tracking:** Tracks the yield generated from user positions and allocates DCA tokens accordingly.
 * - **Configurable Parameters:** Admins can configure epoch duration, minimum yield per epoch, and discrepancy tolerance.
 * - **Simple Execution:** Integrated swap logic without the need for an external swapper contract or permissioned execution.
 *
 * ## Roles
 * - `DEFAULT_ADMIN_ROLE`: Manages configuration settings such as epoch duration, minimum yield per epoch, and discrepancy tolerance.
 *
 * ## External Integrations
 * - **ERC4626 Vault:** Manages the underlying asset and generates yield.
 * - **ERC20 Token:** Acts as the target DCA token.
 *
 * ## Security Considerations
 * - **Input Validation:** Ensures all input parameters are valid and within acceptable ranges.
 * - **Access Control:** Restricts critical functions to authorized roles only.
 * - **Use of Safe Libraries:** Utilizes SafeTransferLib and other safety libraries to prevent overflows and underflows.
 * - **Non-Upgradable:** The contract is designed to be non-upgradable to simplify security and maintainability.
 *
 * ## Usage
 * Users and their approved operators can open and manage positions using both direct interactions and ERC20 permit-based approvals. Positions are represented as ERC721 tokens, enabling easy tracking and management of each user's investments.
 */
abstract contract YieldDCASimple is YieldDCABase {
    using CommonErrors for address;
    using SafeTransferLib for address;

    constructor(
        IERC20 _dcaToken,
        IERC4626 _vault,
        uint32 _epochDuration,
        uint64 _minYieldPerEpochPercent,
        address _admin,
        address _keeper
    ) YieldDCABase(_dcaToken, _vault, _epochDuration, _minYieldPerEpochPercent, _admin, _keeper) {}

    /**
     * @notice Executes the DCA strategy for the current epoch by converting yield into DCA tokens.
     * @dev Redeems yield from the vault, swaps it for DCA tokens using an integrated swap logic, updates the epoch information, and starts a new epoch.
     *
     * @custom:requirements
     * - The epoch duration must have been reached.
     * - The yield must be sufficient to meet the minimum yield per epoch requirement.
     *
     * @custom:reverts
     * - `EpochDurationNotReached` if the epoch duration has not been reached.
     * - `InsufficientYield` if the yield is not sufficient to meet the minimum yield per epoch.
     * - `AmountReceivedTooLow` if the amount of DCA tokens received is below the minimum expected amount.
     *
     * @custom:emits
     * - Emits {DCAExecuted} event upon successful DCA execution.
     */
    function executeDCA() external {
        (uint256 yield, uint256 yieldInShares) = _redeemYield();

        // swap yield for DCA tokens
        uint256 amountOut = _buyDcaTokens(yield);

        _updateEpoch(amountOut, yield, yieldInShares);
    }

    /**
     * @notice Swaps the yield for DCA tokens using integrated swap logic.
     * @dev This function performs the actual swapping of the yield for DCA tokens.
     * @param _amountIn The amount of yield to be swapped.
     * @return The amount of DCA tokens received.
     */
    function _buyDcaTokens(uint256 _amountIn) internal returns (uint256) {
        uint256 balanceBefore = dcaBalance();

        _executeSwap(_amountIn);

        uint256 balanceAfter = dcaBalance();

        if (balanceAfter < balanceBefore + _calculateDcaAmountOutMin(_amountIn)) revert AmountReceivedTooLow();

        unchecked {
            return balanceAfter - balanceBefore;
        }
    }

    /**
     * @notice Executes the swap logic for converting yield to DCA tokens.
     * @dev This function must be implemented by the inheriting contract to define the specific swap logic.
     * @param _amountIn The amount of yield to be swapped.
     */
    function _executeSwap(uint256 _amountIn) internal virtual;

    /**
     * @notice Calculates the minimum amount of DCA tokens expected from the swap.
     * @dev This function must be implemented by the inheriting contract to define the minimum amount calculation logic.
     * @param _amountIn The amount of yield to be swapped.
     * @return The minimum amount of DCA tokens expected.
     */
    function _calculateDcaAmountOutMin(uint256 _amountIn) internal virtual returns (uint256);
}