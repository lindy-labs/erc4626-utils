// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract YieldStreamingFactory_FV is Test {
    YieldStreamingFactory public factory;
    MockERC4626 public vault;
    MockERC20 public asset;

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        factory = new YieldStreamingFactory();
    }

    // The `prove_create_deploysYieldStreamingInstance` function verifies the deployment and basic functionality of a `YieldStreaming` contract instance through a
    // factory contract. It creates a new instance, verifies deployment, checks initialization with a vault address, sets up a yield stream, and confirms share
    // allocation.
    function prove_create_deploysYieldStreamingInstance(address receiver, uint256 value, uint256 tolerance) public {

        YieldStreaming deployed = YieldStreaming(factory.create(address(vault)));

        assertEq(factory.deployedCount(), 1);
        assertEq(factory.deployedAddresses(0), address(deployed));

        // assert vault is set
        assertEq(deployed.token(), address(vault), "vault");

        // open yield stream to confirm correcntess
        asset.mint(address(this), value);
        asset.approve(address(vault), value);
        uint256 shares = vault.deposit(value, address(this));
        vault.approve(address(deployed), shares);

        deployed.openYieldStream(receiver, shares, tolerance);

        assertEq(vault.balanceOf(address(deployed)), shares, "stream shares");
        
    }
}
