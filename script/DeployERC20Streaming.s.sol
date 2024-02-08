// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract DeployERC20Streaming is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (ERC20Streaming erc20Streaming) {
        vm.startBroadcast(deployer);

        erc20Streaming = ERC20Streaming(
            create3.deploy(
                getCreate3ContractSalt(type(ERC20Streaming).name),
                abi.encodePacked(type(ERC20Streaming).creationCode, abi.encode(vault))
            )
        );

        require(erc20Streaming.token() == vault, "incorrect vault set");

        vm.stopBroadcast();
    }
}
