// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract DeployYieldStreaming is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (YieldStreaming yieldStreaming) {
        vm.startBroadcast(deployer);

        yieldStreaming = YieldStreaming(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreaming).name),
                abi.encodePacked(type(YieldStreaming).creationCode, abi.encode(vault))
            )
        );

        require(yieldStreaming.token() == vault, "incorrect vault set");

        vm.stopBroadcast();
    }
}
