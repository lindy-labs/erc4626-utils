// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {SharesStreaming} from "../src/SharesStreaming.sol";

contract DeploySharesStreaming is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (SharesStreaming sharesStreaming) {
        vm.startBroadcast(deployer);

        sharesStreaming = SharesStreaming(
            create3.deploy(
                getCreate3ContractSalt(type(SharesStreaming).name),
                abi.encodePacked(type(SharesStreaming).creationCode, abi.encode(vault))
            )
        );

        vm.stopBroadcast();
    }
}
