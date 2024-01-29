// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {MULTISIG} from "./base/CommonAddresses.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {ERC4626StreamHubFactory} from "../src/ERC4626StreamHubFactory.sol";

contract DeployStreamHubFactory is DeployScriptBase {
    address hubInstanceOwner;

    function _initStateVars() internal override {
        super._initStateVars();

        hubInstanceOwner = MULTISIG;
    }

    function run() external virtual returns (ERC4626StreamHubFactory streamHubFactory) {
        vm.startBroadcast(deployer);

        streamHubFactory = ERC4626StreamHubFactory(
            create3.deploy(
                getCreate3ContractSalt(type(ERC4626StreamHubFactory).name),
                abi.encodePacked(type(ERC4626StreamHubFactory).creationCode, abi.encode(hubInstanceOwner))
            )
        );

        vm.stopBroadcast();
    }
}
