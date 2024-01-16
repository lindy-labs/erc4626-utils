// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";
import {RemovableAssetsERC4626Mock} from "../test/mock/RemovableAssetsERC4626Mock.sol";

contract DeployScriptTestnet is CREATE3Script {
    // constructor() CREATE3Script(vm.envString("VERSION")) {}
    constructor() CREATE3Script("1.0.0") {}

    // sepolia addresses
    address constant erc20Mock = 0xB96CcC02290102424A10795bea3Ba0dF99374CD7;
    address constant erc4626Mock = 0xF78Ab707bdC48F6E7eAC9115d3BAC2a6323C26A6;

    function run() external returns (ERC4626StreamHub streamHub) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(vm.addr(deployerPrivateKey));

        streamHub = new ERC4626StreamHub(RemovableAssetsERC4626Mock(erc4626Mock));

        vm.stopBroadcast();
    }
}
