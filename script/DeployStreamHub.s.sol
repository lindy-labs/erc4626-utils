// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract DeployStreamHub is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (ERC4626StreamHub streamHub) {
        vm.startBroadcast(deployer);

        streamHub = ERC4626StreamHub(
            create3.deploy(
                getCreate3ContractSalt(type(ERC4626StreamHub).name),
                abi.encodePacked(type(ERC4626StreamHub).creationCode, abi.encode(vault))
            )
        );

        require(streamHub.token() == vault, "incorrect vault set");

        vm.stopBroadcast();
    }
}
