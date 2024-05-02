// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreamsFactory} from "../src/YieldStreamsFactory.sol";

contract DeployYieldStreamsFactory is DeployScriptBase {
    function _initStateVars() internal override {
        super._initStateVars();
    }

    function run() external virtual returns (YieldStreamsFactory factory) {
        vm.startBroadcast(deployer);

        factory = YieldStreamsFactory(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreamsFactory).name),
                abi.encodePacked(type(YieldStreamsFactory).creationCode)
            )
        );

        vm.stopBroadcast();
    }
}
