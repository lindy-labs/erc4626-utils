// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {CREATE3} from "solmate/utils/CREATE3.sol";
import {ERC4626StreamHub} from "./ERC4626StreamHub.sol";

/**
 * @title ERC4626StreamHubFactory
 * @dev A contract for creating and managing ERC4626StreamHub instances.
 */
contract ERC4626StreamHubFactory {
    /// @dev The addresses of deployed ERC4626StreamHub instances.
    address[] public deployedAddresses;
    /// @dev The number of deployed ERC4626StreamHub instances.
    uint256 public deployedCount;

    event Deployed(address indexed vault, address indexed deployed);

    /**
     * @dev Creates a new ERC4626StreamHub instance.
     * @param _vault The address of the vault contract.
     * @return deployed The address of the deployed ERC4626StreamHub instance.
     */
    function create(address _vault) public returns (address deployed) {
        bytes32 salt = keccak256(abi.encode(_vault));
        bytes memory creationCode = abi.encodePacked(type(ERC4626StreamHub).creationCode, abi.encode(_vault));

        deployed = CREATE3.deploy(salt, creationCode, 0);

        deployedAddresses.push(address(deployed));
        deployedCount++;

        emit Deployed(_vault, address(deployed));
    }

    /**
     * @dev Predicts the address of the deployed ERC4626StreamHub instance.
     * @param _vault The address of the vault contract.
     * @return predicted The predicted address of the deployed ERC4626StreamHub instance.
     */
    function predictDeploy(address _vault) public view returns (address predicted) {
        bytes32 salt = keccak256(abi.encode(_vault));

        predicted = CREATE3.getDeployed(salt, address(this));
    }

    /**
     * @dev Checks if an ERC4626StreamHub instance is deployed for the given vault contract address.
     * @param _vault The address of the vault contract.
     * @return bool Returns true if an ERC4626StreamHub instance is deployed, false otherwise.
     */
    function isDeployed(address _vault) public view returns (bool) {
        return predictDeploy(_vault).code.length > 0;
    }
}
