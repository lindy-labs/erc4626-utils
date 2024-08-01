// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";
import {ISwapRouter} from "./interfaces/uniswap/ISwapRouter.sol";
import {IQuoterV2} from "./interfaces/uniswap/IQuoterV2.sol";

/**
 * @title UniSwapper
 * @notice Implements token swapping functionality using Uniswap's ISwapRouter and IQuoterV2.
 * @dev This contract allows users to execute exact input for output amount token swaps through Uniswap's ISwapRouter and preview swap results using IQuoterV2.
 *
 * ## Key Features
 * - **Exact Input Token Swapping:** Allows users to swap tokens by specifying the exact amount of input tokens and receiving the output tokens through Uniswap's ISwapRouter.
 * - **Swap Preview:** Provides a function to preview swap results using Uniswap's IQuoterV2.
 *
 * ## External Integrations
 * - **Uniswap ISwapRouter:** Facilitates token swaps.
 * - **Uniswap IQuoterV2:** Provides quote for token swaps.
 *
 * ## Usage
 * Users can execute token swaps by specifying the input and output tokens, the exact amount to swap, and the minimum acceptable output amount. They can also preview swap results to estimate the output amount for a given input.
 */
contract UniSwapper is ISwapper {
    using Address for address;
    using SafeTransferLib for address;

    /**
     * @notice The Uniswap swap router contract used for executing token swaps.
     */
    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    /**
     * @notice The Uniswap quoter contract used for previewing swap results.
     */
    IQuoterV2 public constant quoter = IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);

    /**
     * @notice Executes an exact input for output amount token swap using Uniswap's ISwapRouter.
     * @dev Transfers the input tokens from the caller to the contract, approves the swap router, and executes the swap.
     * @param _tokenIn The address of the input token.
     * @param _tokenOut The address of the output token.
     * @param _amountIn The exact amount of input tokens to swap.
     * @param _amountOutMin The minimum amount of output tokens expected from the swap.
     * @param _data Additional data required for the swap (e.g., pool fee).
     * @return amountOut The amount of output tokens received from the swap.
     *
     * Requirements:
     * - The caller must approve the contract to spend `_amountIn` of `_tokenIn`.
     */
    function execute(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _data
    ) public returns (uint256 amountOut) {
        // Transfer tokens to this contract
        _tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        // Approve swapRouter to spend the tokens
        _tokenIn.safeApprove(address(swapRouter), _amountIn);

        uint24 poolFee = abi.decode(_data, (uint24));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: poolFee,
            // Send the tokens to the caller
            recipient: msg.sender,
            // Execute the swap immediately
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Previews the output amount for a given input amount using Uniswap's IQuoterV2.
     * @dev Provides an estimate of the output tokens without executing the swap. Meant for read-only purposes.
     * @param _tokenIn The address of the input token.
     * @param _tokenOut The address of the output token.
     * @param _amountIn The exact amount of input tokens to swap.
     * @param _data Additional data required for the swap preview (e.g., pool fee).
     * @return amountOut The estimated amount of output tokens.
     *
     * Note:
     * - This function is intended for read-only purposes and should not be used within transactions due to inefficient gas usage.
     */
    function previewExecute(address _tokenIn, address _tokenOut, uint256 _amountIn, bytes calldata _data)
        external
        returns (uint256 amountOut)
    {
        uint24 poolFee = abi.decode(_data, (uint24));

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: poolFee,
            amountIn: _amountIn,
            sqrtPriceLimitX96: 0
        });

        (amountOut,,,) = quoter.quoteExactInputSingle(params);
    }
}
