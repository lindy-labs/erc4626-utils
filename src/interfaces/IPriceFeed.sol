// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
 * @title IPriceFeed
 * @notice Interface for the PriceFeed contract used to get the latest price of a token pair.
 */
interface IPriceFeed {
    /**
     * @notice Get the latest price of a token pair expressed as WAD.
     * @param tokenIn The address of the input token
     * @param tokenOut The address of the output token
     * @return The price of the token pair calculated as one unit of the input token divided by one unit of the output token and expressed as WAD.
     */
    function getLatestPrice(address tokenIn, address tokenOut) external returns (uint256);
}
