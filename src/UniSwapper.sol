// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";
import {ISwapRouter} from "./interfaces/uniswap/ISwapRouter.sol";

contract UniSwapper is ISwapper {
    using SafeERC20 for IERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function execute(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _data
    ) public returns (uint256 amountOut) {
        // transfer tokens to this contract
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        // approve swapRouter to spend the tokens
        IERC20(_tokenIn).approve(address(swapRouter), _amountIn);

        uint24 poolFee = abi.decode(_data, (uint24));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: poolFee,
            // send the tokens to the caller
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }
}
