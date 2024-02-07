// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {ERC4626StreamHubFactory} from "../src/ERC4626StreamHubFactory.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract ERC4626StreamHubFactoryTest is Test {
    function test_create_deploysStreamHubInstance() public {
        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        MockERC4626 vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");

        ERC4626StreamHubFactory factory = new ERC4626StreamHubFactory();

        ERC4626StreamHub deployed = ERC4626StreamHub(factory.create(address(vault)));

        assertEq(factory.deployedCount(), 1);
        assertEq(factory.deployedAddresses(0), address(deployed));

        // assert vault is set
        assertEq(deployed.token(), address(vault), "vault");

        asset.mint(address(this), 2 ether);
        asset.approve(address(vault), 2 ether);
        uint256 shares = vault.deposit(2 ether, address(this));
        vault.approve(address(deployed), shares);
        address receiver = address(0x02);

        // open yield stream
        deployed.openYieldStream(receiver, shares / 2);

        assertEq(vault.balanceOf(address(deployed)), shares / 2, "yield stream shares");
        assertEq(deployed.receiverShares(receiver), shares / 2, "yield receiver shares");

        // open token stream
        deployed.openStream(receiver, shares / 2, 1 days);

        assertEq(vault.balanceOf(address(deployed)), shares, "total shares");
        uint256 streamId = deployed.getStreamId(address(this), receiver);
        assertEq(deployed.getStream(streamId).amount, shares / 2, "token stream amount");
    }
}
