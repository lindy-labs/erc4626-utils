// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {CommonErrors} from "./common/CommonErrors.sol";
import {YieldDCABase} from "./YieldDCABase.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

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
contract YieldDCASimple is YieldDCABase {
    using CommonErrors for address;
    using FixedPointMathLib for uint256;

    uint256 public constant MIN_TOLERATED_SLIPPAGE = 0.001e18; // 0.1%
    uint256 public constant MAX_TOLERATED_SLIPPAGE = 0.2e18; // 20%

    event PriceFeedUpdated(address indexed caller, IPriceFeed oldPriceFeed, IPriceFeed newPriceFeed);
    event SwapDataUpdated(address indexed caller, bytes oldSwapData, bytes newSwapData);
    event ToleratedSlippageUpdated(address indexed caller, uint256 oldSlippage, uint256 newSlippage);

    error PriceFeedAddressZero();
    error InvalidSlippageTolerance();

    IPriceFeed public priceFeed;
    bytes public swapData;
    uint256 public toleratedSlippage = 0.05e18; // 5%

    /**
     * @notice Initializes the YieldDCASimple contract.
     * @dev Sets up the DCA strategy contract with the specified parameters, including the ERC20 token for DCA, the ERC4626 vault, and the initial configuration parameters.
     * Assigns the DEFAULT_ADMIN_ROLE to the provided admin address.
     * Approves the vault to spend the underlying assets.
     * @param _dcaToken The address of the ERC20 token used for DCA.
     * @param _vault The address of the underlying ERC4626 vault contract.
     * @param _epochDuration The minimum duration between epochs in seconds.
     * @param _minYieldPerEpochPercent The minimum yield required per epoch as a WAD-scaled percentage of the total principal.
     * @param _admin The address with the admin role.
     *
     * @custom:requirements
     * - `_dcaToken` must not be the zero address.
     * - `_vault` must not be the zero address.
     * - `_dcaToken` must not be the same as the vault's underlying asset.
     * - `_admin` must not be the zero address.
     *
     * @custom:reverts
     * - `DCATokenAddressZero` if `_dcaToken` is the zero address.
     * - `VaultAddressZero` if `_vault` is the zero address.
     * - `DCATokenSameAsVaultAsset` if `_dcaToken` is the same as the vault's underlying asset.
     * - `AdminAddressZero` if `_admin` is the zero address.
     */
    constructor(
        IERC20 _dcaToken,
        IERC4626 _vault,
        ISwapper _swapper,
        IPriceFeed _priceFeed,
        bytes memory _swapData,
        uint32 _epochDuration,
        uint64 _minYieldPerEpochPercent,
        address _admin
    ) YieldDCABase(_dcaToken, _vault, _swapper, _epochDuration, _minYieldPerEpochPercent, _admin) {
        _setPriceFeed(_priceFeed);
        _setSwapData(_swapData);
    }

    function setPriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
        IPriceFeed oldPriceFeed = priceFeed;

        _setPriceFeed(_priceFeed);

        emit PriceFeedUpdated(msg.sender, oldPriceFeed, _priceFeed);
    }

    function setSwapData(bytes memory _swapData) external onlyAdmin {
        bytes memory oldSwapData = swapData;

        _setSwapData(_swapData);

        emit SwapDataUpdated(msg.sender, oldSwapData, _swapData);
    }

    function setToleratedSlippage(uint256 _toleratedSlippage) external onlyAdmin {
        if (_toleratedSlippage < MIN_TOLERATED_SLIPPAGE || _toleratedSlippage > MAX_TOLERATED_SLIPPAGE) {
            revert InvalidSlippageTolerance();
        }

        uint256 oldSlippage = toleratedSlippage;
        toleratedSlippage = _toleratedSlippage;

        emit ToleratedSlippageUpdated(msg.sender, oldSlippage, _toleratedSlippage);
    }

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
        uint256 amountOut = _executeSwap(yield, _calculateDcaAmountOutMin(yield), swapData);

        _updateEpoch(amountOut, yield, yieldInShares);
    }

    /**
     * @notice Calculates the minimum amount of DCA tokens expected from the swap.
     * @dev This function must be implemented by the inheriting contract to define the minimum amount calculation logic.
     * @param _amountIn The amount of yield to be swapped.
     * @return The minimum amount of DCA tokens expected.
     */
    function _calculateDcaAmountOutMin(uint256 _amountIn) internal virtual returns (uint256) {
        uint256 price = priceFeed.getLatestPrice(address(asset), address(dcaToken));

        unchecked {
            return price.mulWad(_amountIn).mulWad(1e18 - toleratedSlippage);
        }
    }

    function _setPriceFeed(IPriceFeed _priceFeed) internal {
        address(_priceFeed).revertIfZero(PriceFeedAddressZero.selector);

        priceFeed = _priceFeed;
    }

    function _setSwapData(bytes memory _swapData) internal {
        swapData = _swapData;
    }
}
