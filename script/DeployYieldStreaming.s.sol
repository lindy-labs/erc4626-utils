// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {MULTISIG} from "./base/CommonAddresses.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract DeployYieldStreaming is DeployScriptBase {
    address vault;
    address owner;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
        owner = MULTISIG;
    }

    function run() external virtual returns (YieldStreaming deployed) {
        vm.startBroadcast(deployer);

        deployed = YieldStreaming(
            create3.deploy(
                getCreate3ContractSalt(type(YieldStreaming).name),
                abi.encodePacked(type(YieldStreaming).creationCode, abi.encode(owner, vault))
            )
        );

        vm.stopBroadcast();
    }
}
