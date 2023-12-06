// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {ERC20Mock} from "openzeppelin-contracts/mocks/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/mocks/ERC4626Mock.sol";
import {CREATE3Script} from "./base/CREATE3Script.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract DeployScript is CREATE3Script {
    // constructor() CREATE3Script(vm.envString("VERSION")) {}
    constructor() CREATE3Script("1.0.0") {}

    address constant erc20Mock = 0xB96CcC02290102424A10795bea3Ba0dF99374CD7;
    address constant erc4626Mock = 0x415849Ed40dFd67c9422686F9E2FfF9E3d7e04D1;

    function run() external returns (ERC4626StreamHub streamHub) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(vm.addr(deployerPrivateKey));

        // vm.startBroadcast(address(this));

        streamHub = new ERC4626StreamHub(ERC4626Mock(erc4626Mock));

        // c = Contract(
        //     create3.deploy(
        //         getCreate3ContractSalt("Contract"),
        //         bytes.concat(type(Contract).creationCode, abi.encode(param))
        //     )
        // );

        vm.stopBroadcast();
    }
}
