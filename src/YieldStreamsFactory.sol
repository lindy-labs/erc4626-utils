// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {StreamsFactoryBase} from "./common/StreamsFactoryBase.sol";
import {YieldStreams} from "./YieldStreams.sol";

/**
 * @title YieldStreamsFactory
 * @dev A contract for creating and managing YieldStreams instances.
 */
contract YieldStreamsFactory is StreamsFactoryBase {
    function _getCreationCode(address _vault) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(YieldStreams).creationCode, abi.encode(_vault));
    }
}
