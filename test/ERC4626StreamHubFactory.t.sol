// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import "../src/ERC4626StreamHub.sol";
import {ERC4626StreamHubFactory} from "../src/ERC4626StreamHubFactory.sol";
import {ERC4626StreamHub} from "../src/ERC4626StreamHub.sol";

contract ERC4626StreamHubFactoryTest is Test {
    ERC4626StreamHubFactory public factory;
    MockERC4626 public vault;

    address constant hubOwner = address(0x01);

    event Deployed(address indexed vault, address indexed deployed);
    event HubInstanceOwnerUpdated(address indexed sender, address oldOwner, address newOwner);

    function setUp() public {
        factory = new ERC4626StreamHubFactory(hubOwner);

        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
    }

    function test_constructor_setsHubInstanceOwner() public {
        assertEq(factory.hubInstanceOwner(), hubOwner);
    }

    function test_constructor_failsIfHubInstanceOwnerIsZero() public {
        vm.expectRevert("invalid hub instance owner");
        new ERC4626StreamHubFactory(address(0));
    }

    function test_setHubInstanceOwner_updatesHubInstanceOwner() public {
        address newHubInstanceOwner = address(0x02);

        factory.setHubInstanceOwner(newHubInstanceOwner);

        assertEq(factory.hubInstanceOwner(), newHubInstanceOwner);
    }

    function test_setHubInstanceOwner_failsIfNewHubInstanceOwnerIsZero() public {
        vm.expectRevert("invalid hub instance owner");
        factory.setHubInstanceOwner(address(0));
    }

    function test_setHubInstanceOwner_emitsEvent() public {
        address newHubInstanceOwner = address(0x02);

        vm.expectEmit(true, true, true, true);
        emit HubInstanceOwnerUpdated(address(this), hubOwner, newHubInstanceOwner);

        factory.setHubInstanceOwner(newHubInstanceOwner);
    }

    function test_create_failsIfVaultIsZero() public {
        vm.expectRevert("invalid vault address");
        factory.create(address(0));
    }

    function test_create_deploysStreamHubContract() public {
        address predicted = factory.predictDeploy(address(vault));
        assertTrue(!factory.isDeployed(address(vault)), "isDeployed");
        assertEq(factory.deployedCount(), 0, "deployedCount");

        address deployed = factory.create(address(vault));

        assertTrue(deployed != address(0));
        assertTrue(factory.isDeployed(address(vault)), "isDeployed");
        assertTrue(factory.deployedAddresses(0) == deployed, "deployedAddresses[0]");
        assertTrue(ERC4626StreamHub(deployed).owner() == hubOwner, "deployed instance owner");
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

    function test_create_failsIfAlreadyDepolyed() public {
        factory.create(address(vault));

        vm.expectRevert("already deployed");
        factory.create(address(vault));
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
