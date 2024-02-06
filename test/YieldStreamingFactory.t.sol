// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract YieldStreamingFactoryTest is Test {
    function test_create_deploysYieldStreaming() public {
        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        MockERC4626 vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");

        address instanceOwner = address(0x01);
        YieldStreamingFactory factory = new YieldStreamingFactory(instanceOwner);

        YieldStreaming deployed = YieldStreaming(factory.create(address(vault)));

        assertEq(factory.deployedCount(), 1);
        assertEq(factory.deployedAddresses(0), address(deployed));

        // assert correct owner and vault
        assertEq(deployed.owner(), instanceOwner, "owner");
        assertEq(deployed.token(), address(vault), "vault");

        // open yield stream to confirm correcntess
        asset.mint(address(this), 1 ether);
        asset.approve(address(vault), 1 ether);
        uint256 shares = vault.deposit(1 ether, address(this));
        vault.approve(address(deployed), shares);
        address receiver = address(0x02);

        deployed.openYieldStream(receiver, shares);

        assertEq(vault.balanceOf(address(deployed)), shares, "stream shares");
    }
}
