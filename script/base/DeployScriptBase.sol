// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {CREATE3Script} from "./CREATE3Script.sol";

abstract contract DeployScriptBase is CREATE3Script {
    uint256 public deployerPrivateKey;
    address public deployer;

    constructor() {
        _initStateVars();
    }

    function _initStateVars() internal virtual {
        deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        deployer = vm.rememberKey(deployerPrivateKey);
    }
}
