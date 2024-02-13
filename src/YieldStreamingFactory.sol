// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {StreamingFactoryBase} from "./common/StreamingFactoryBase.sol";
import {YieldStreaming} from "./ERC4626StreamHub.sol";

/**
 * @title YieldStreamingFactory
 * @dev A contract for creating and managing YieldStreaming instances.
 */
contract YieldStreamingFactory is StreamingFactoryBase {
    function _getCreationCode(address _vault) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(YieldStreaming).creationCode, abi.encode(_vault));
    }
}
