// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {YieldStreaming} from "./YieldStreaming.sol";
import {SharesStreaming} from "./SharesStreaming.sol";

contract ERC4626StreamHub is YieldStreaming, SharesStreaming {
    constructor(IERC4626 _vault) YieldStreaming(_vault) SharesStreaming(_vault) {}
}
