// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";

import "forge-std/Script.sol";

abstract contract CREATE3Script is Script {
    CREATE3Factory internal create3 = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    function getCreate3Contract(address deployer, string memory name) public virtual returns (address) {
        return create3.getDeployed(deployer, getCreate3ContractSalt(name));
    }

    function getCreate3ContractSalt(string memory name) internal virtual returns (bytes32) {
        string memory version = vm.envOr("VERSION", string("1.0.0"));

        return keccak256(bytes(string.concat(name, "-v", version)));
    }
}
