// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract YieldStreamingFactoryTest is Test {
    function test_create_deploysYieldStreamingInstance() public {
        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        MockERC4626 vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");

        YieldStreamingFactory factory = new YieldStreamingFactory();

        YieldStreaming deployed = YieldStreaming(factory.create(address(vault)));

        assertEq(factory.deployedCount(), 1);
        assertEq(factory.deployedAddresses(0), address(deployed));

        // assert vault is set
        assertEq(address(deployed.vault()), address(vault), "vault");

        // open yield stream to confirm correcntess
        asset.mint(address(this), 1 ether);
        asset.approve(address(vault), 1 ether);
        uint256 shares = vault.deposit(1 ether, address(this));
        vault.approve(address(deployed), shares);
        address receiver = address(0x02);

        deployed.openYieldStream(receiver, shares, 0);

        assertEq(vault.balanceOf(address(deployed)), shares, "stream shares");
    }
}
