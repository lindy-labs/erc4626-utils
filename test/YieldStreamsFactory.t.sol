// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {CommonErrors} from "src/common/CommonErrors.sol";
import {YieldStreamsFactory} from "src/YieldStreamsFactory.sol";
import {YieldStreams} from "src/YieldStreams.sol";

contract YieldStreamsFactoryTest is Test {
    YieldStreamsFactory public factory;
    MockERC20 public asset;
    IERC4626 public vault;

    event Deployed(address indexed caller, address vault, address yieldStreams);

    function setUp() public {
        factory = new YieldStreamsFactory();

        asset = new MockERC20("Mock ERC20", "mERC20", 18);
        vault = IERC4626(address(new MockERC4626(asset, "Mock ERC4626", "mERC4626")));
    }

    function test_create_failsIfVaultIsZero() public {
        vm.expectRevert(CommonErrors.ZeroAddress.selector);
        factory.create(IERC4626(address(0)));
    }

    function test_create_deploysYieldStreamsContract() public {
        address predicted = address(factory.predictDeploy(vault));
        assertTrue(!factory.isDeployed(vault), "isDeployed before");
        assertEq(factory.deployedCount(), 0, "deployedCount before");

        YieldStreams deployed = factory.create(vault);

        assertTrue(address(deployed) != address(0));
        assertTrue(factory.isDeployed(vault), "isDeployed after");
        assertTrue(factory.deployedAddresses(0) == address(deployed), "deployedAddresses[0]");
        assertEq(predicted, address(deployed), "predicted address");
        assertEq(factory.deployedCount(), 1, "deployedCount");

        // assert vault is set
        assertEq(address(deployed.vault()), address(vault), "vault");

        // open yield stream to confirm correcntess
        asset.mint(address(this), 1 ether);
        asset.approve(address(vault), 1 ether);
        uint256 shares = vault.deposit(1 ether, address(this));
        vault.approve(address(deployed), shares);
        address receiver = address(0x02);

        deployed.open(receiver, shares, 0);

        assertEq(vault.balanceOf(address(deployed)), shares, "stream shares");
    }

    function test_create_emitsEvent() public {
        address predicted = address(factory.predictDeploy(vault));

        vm.expectEmit(true, true, true, true);
        emit Deployed(address(this), address(vault), predicted);

        address deployed = address(factory.create(vault));

        assertEq(address(predicted), deployed, "predicted");
    }

    function test_create_failsIfAlreadyDepolyed() public {
        factory.create(vault);

        vm.expectRevert(YieldStreamsFactory.AlreadyDeployed.selector);
        factory.create(vault);
    }

    function test_create_deployTwiceWorksForDifferentVaults() public {
        MockERC20 asset2 = new MockERC20("ERC20Mock2", "ERC20Mock2", 18);
        IERC4626 vault2 = IERC4626(address(new MockERC4626(asset2, "ERC4626Mock2", "ERC4626Mock2")));

        address predicted = address(factory.predictDeploy(vault));
        address predicted2 = address(factory.predictDeploy(vault2));

        address deployed = address(factory.create(vault));
        address deployed2 = address(factory.create(vault2));

        assertTrue(factory.isDeployed(vault), "isDeployed");
        assertTrue(factory.isDeployed(vault2), "isDeployed2");
        assertTrue(factory.deployedAddresses(0) == deployed, "deployedAddresses[0]");
        assertTrue(factory.deployedAddresses(1) == deployed2, "deployedAddresses[1]");
        assertEq(predicted, deployed, "predicted");
        assertEq(predicted2, deployed2, "predicted2");
        assertEq(factory.deployedCount(), 2, "deployedCount");
    }
}
