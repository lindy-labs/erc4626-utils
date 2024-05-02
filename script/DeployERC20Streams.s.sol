// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {ERC20Streams} from "../src/ERC20Streams.sol";

contract DeployERC20Streams is DeployScriptBase {
    address vault;

    function _initStateVars() internal override {
        super._initStateVars();

        vault = vm.envAddress("ERC4626_VAULT");
    }

    function run() external virtual returns (ERC20Streams erc20Streams) {
        vm.startBroadcast(deployer);

        erc20Streams = ERC20Streams(
            create3.deploy(
                getCreate3ContractSalt(type(ERC20Streams).name),
                abi.encodePacked(type(ERC20Streams).creationCode, abi.encode(vault))
            )
        );

        require(address(erc20Streams.token()) == vault, "incorrect token set");

        vm.stopBroadcast();
    }
}
