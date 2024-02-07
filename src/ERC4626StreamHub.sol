// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {YieldStreaming} from "./YieldStreaming.sol";
import {ERC20Streaming} from "./ERC20Streaming.sol";

/**
 * @title ERC4626StreamHub
 * @notice This is a convenience contract that combines functionalities YieldStreaming and SharesStreaming contracts
 */
contract ERC4626StreamHub is YieldStreaming, ERC20Streaming {
    constructor(IERC4626 _vault) YieldStreaming(_vault) ERC20Streaming(_vault) {}
}
