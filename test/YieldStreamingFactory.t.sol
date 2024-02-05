// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {YieldStreamingFactory} from "../src/YieldStreamingFactory.sol";
import {YieldStreaming} from "../src/YieldStreaming.sol";

contract YieldStreamingFactoryTest is Test {
    YieldStreamingFactory public factory;
    MockERC4626 public vault;

    address constant instanceOwner = address(0x01);

    event Deployed(address indexed vault, address indexed deployed);
    event InstanceOwnerUpdated(address indexed sender, address oldOwner, address newOwner);

    function setUp() public {
        factory = new YieldStreamingFactory(instanceOwner);

        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
    }

    function test_constructor_setsHubInstanceOwner() public {
        assertEq(factory.instanceOwner(), instanceOwner);
    }

    function test_setHubInstanceOwner_updatesHubInstanceOwner() public {
        address newHubInstanceOwner = address(0x02);

        factory.setInstanceOwner(newHubInstanceOwner);

        assertEq(factory.instanceOwner(), newHubInstanceOwner);
    }

    function test_setHubInstanceOwner_emitsEvent() public {
        address newHubInstanceOwner = address(0x02);

        vm.expectEmit(true, true, true, true);
        emit InstanceOwnerUpdated(address(this), instanceOwner, newHubInstanceOwner);

        factory.setInstanceOwner(newHubInstanceOwner);
    }

    function test_create_deploysStreamHubContract() public {
        address predicted = factory.predictDeploy(address(vault));
        assertTrue(!factory.isDeployed(address(vault)), "isDeployed");
        assertEq(factory.deployedCount(), 0, "deployedCount");

        address deployed = factory.create(address(vault));

        assertTrue(deployed != address(0));
        assertTrue(factory.isDeployed(address(vault)), "isDeployed");
        assertTrue(factory.deployedAddresses(0) == deployed, "deployedAddresses[0]");
        assertTrue(YieldStreaming(deployed).owner() == instanceOwner, "deployed instance owner");
        assertEq(predicted, deployed, "predicted");
        assertEq(factory.deployedCount(), 1, "deployedCount");
    }

    function test_create_emitsEvent() public {
        address predicted = factory.predictDeploy(address(vault));

        vm.expectEmit(true, true, true, true);
        emit Deployed(address(vault), address(predicted));

        address deployed = factory.create(address(vault));

        assertEq(predicted, deployed, "predicted");
    }

    function test_create_deployTwiceForDifferentVaults() public {
        MockERC20 asset2 = new MockERC20("ERC20Mock2", "ERC20Mock2", 18);
        address vault2 = address(new MockERC4626(asset2, "ERC4626Mock2", "ERC4626Mock2"));

        address predicted = factory.predictDeploy(address(vault));
        address predicted2 = factory.predictDeploy(address(vault2));

        address deployed = factory.create(address(vault));
        address deployed2 = factory.create(address(vault2));

        assertTrue(factory.isDeployed(address(vault)), "isDeployed");
        assertTrue(factory.isDeployed(address(vault2)), "isDeployed2");
        assertTrue(factory.deployedAddresses(0) == deployed, "deployedAddresses[0]");
        assertTrue(factory.deployedAddresses(1) == deployed2, "deployedAddresses[1]");
        assertEq(predicted, deployed, "predicted");
        assertEq(predicted2, deployed2, "predicted2");
        assertEq(factory.deployedCount(), 2, "deployedCount");
    }
}
