// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {CREATE3} from "solmate/utils/CREATE3.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {ERC4626StreamHub} from "./ERC4626StreamHub.sol";
import {StreamingFactoryBase} from "./common/StreamingFactoryBase.sol";

/**
 * @title ERC4626StreamHubFactory
 * @dev A contract for creating and managing ERC4626StreamHub instances.
 */
contract ERC4626StreamHubFactory is StreamingFactoryBase {
    function _getCreationCode(address _vault) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(ERC4626StreamHub).creationCode, abi.encode(_vault));
    }
}
