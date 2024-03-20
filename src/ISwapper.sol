// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

interface ISwapper {
    function execute(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOutMin)
        external
        returns (uint256 amountOut);
}
