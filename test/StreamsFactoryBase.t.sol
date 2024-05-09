// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import "src/common/CommonErrors.sol";

import {StreamsFactoryBase} from "../src/common/StreamsFactoryBase.sol";

contract StreamsFactoryBaseTest is Test {
    FactoryHarness public factory;
    MockERC4626 public vault;

    event Deployed(address indexed vault, address indexed deployed);

    function setUp() public {
        factory = new FactoryHarness();

        MockERC20 asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
    }

    function test_create_failsIfVaultIsZero() public {
        vm.expectRevert(CommonErrors.AddressZero.selector);
        factory.create(address(0));
    }

    function test_create_deploysStreamsContract() public {
        address predicted = factory.predictDeploy(address(vault));
        assertTrue(!factory.isDeployed(address(vault)), "isDeployed");
        assertEq(factory.deployedCount(), 0, "deployedCount");

        address deployed = factory.create(address(vault));

        assertTrue(deployed != address(0));
        assertTrue(factory.isDeployed(address(vault)), "isDeployed");
        assertTrue(factory.deployedAddresses(0) == deployed, "deployedAddresses[0]");
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

        vm.expectRevert(StreamsFactoryBase.AlreadyDeployed.selector);
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

contract FactoryHarness is StreamsFactoryBase {
    function _getCreationCode(address) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(DeployMock).creationCode);
    }
}

contract DeployMock {}
