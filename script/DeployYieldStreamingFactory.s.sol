// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";

contract DeployieldStreamingFactory is DeployScriptBase {
    function _initStateVars() internal override {
        super._initStateVars();
    }

    function run() external virtual returns (YieldStreamingFactory factory) {
        vm.startBroadcast(deployer);

        factory = YieldStreamingFactory(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreamingFactory).name),
                abi.encodePacked(type(YieldStreamingFactory).creationCode)
            )
        );

        vm.stopBroadcast();
    }
}
