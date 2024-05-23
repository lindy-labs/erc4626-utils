// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";

contract SwapperMock is ISwapper {
    using FixedPointMathLib for uint256;

    uint256 public constant DEFAULT_EXCHANGE_RATE = 1e18;

    uint256 public exchangeRate = DEFAULT_EXCHANGE_RATE;

    function setExchangeRate(uint256 _exchangeRate) external {
        exchangeRate = _exchangeRate;
    }

    function execute(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        // console2.log("Swapper: execute");
        amountOut = _amountIn.mulWadDown(exchangeRate);

        // console2.log("amountIn", _amountIn);
        // console2.log("amountOut", amountOut);

        IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn);

        // console2.log("token out balance", IERC20(_tokenOut).balanceOf(address(this)));

        IERC20(_tokenOut).transfer(msg.sender, amountOut);
    }
}
