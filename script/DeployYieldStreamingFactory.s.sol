// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {MULTISIG} from "./base/CommonAddresses.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";

contract DeployStreamHubFactory is DeployScriptBase {
    address instanceOwner;

    function _initStateVars() internal override {
        super._initStateVars();

        instanceOwner = MULTISIG;
    }

    function run() external virtual returns (YieldStreamingFactory streamHubFactory) {
        vm.startBroadcast(deployer);

        streamHubFactory = YieldStreamingFactory(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreamingFactory).name),
                abi.encodePacked(type(YieldStreamingFactory).creationCode, abi.encode(instanceOwner))
            )
        );

        vm.stopBroadcast();
    }
}
