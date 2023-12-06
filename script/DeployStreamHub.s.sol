// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {ERC20Mock} from "openzeppelin-contracts/mocks/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/mocks/ERC4626Mock.sol";
import {CREATE3Script} from "./base/CREATE3Script.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract DeployScript is CREATE3Script {
    // constructor() CREATE3Script(vm.envString("VERSION")) {}
    constructor() CREATE3Script("1.0.0") {}

    function run()
        external
        returns (ERC4626StreamHub streamHub, ERC4626Mock vault, ERC20Mock asset)
    {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(vm.addr(deployerPrivateKey));

        // vm.startBroadcast(address(this));

        asset = new ERC20Mock("ERC20Mock", "ERC20Mock", address(this), 0);
        vault = new ERC4626Mock(asset, "ERC4626Mock", "ERC4626Mock");
        streamHub = new ERC4626StreamHub(vault);

        // c = Contract(
        //     create3.deploy(
        //         getCreate3ContractSalt("Contract"),
        //         bytes.concat(type(Contract).creationCode, abi.encode(param))
        //     )
        // );

        vm.stopBroadcast();
    }
}
