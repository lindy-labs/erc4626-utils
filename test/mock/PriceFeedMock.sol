// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IPriceFeed} from "src/interfaces/IPriceFeed.sol";

contract PriceFeedMock is IPriceFeed {
    uint256 public latestPrice = 1e18;

    function setLatestPrice(uint256 _latestPrice) external {
        latestPrice = _latestPrice;
    }

    function getLatestPrice(address, address) external view override returns (uint256) {
        return latestPrice;
    }
}
