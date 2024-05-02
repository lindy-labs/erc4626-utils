// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreams} from "../src/YieldStreams.sol";

contract DeployYieldStreams is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (YieldStreams ys) {
        vm.startBroadcast(deployer);

        ys = YieldStreams(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreams).name),
                abi.encodePacked(type(YieldStreams).creationCode, abi.encode(vault))
            )
        );

        require(address(ys.vault()) == vault, "incorrect vault set");

        vm.stopBroadcast();
    }
}
