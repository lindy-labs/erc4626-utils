// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {CREATE3} from "solmate/utils/CREATE3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {AddressZero, AlreadyDeployed} from "./Errors.sol";

/**
 * @title StreamingFactoryBase
 * @dev A base contract for creating and managing streaming contract instances.
 */
abstract contract StreamingFactoryBase {
    /// @dev The addresses of deployed instances.
    address[] public deployedAddresses;
    /// @dev The number of deployed instances.
    uint256 public deployedCount;

    event Deployed(address indexed vault, address indexed deployed);

    /**
     * @dev Creates a new ERC4626StreamHub instance.
     * @param _vault The address of the vault contract.
     * @return deployed The address of the deployed ERC4626StreamHub instance.
     */
    function create(address _vault) public virtual returns (address deployed) {
        _checkZeroAddress(_vault);
        if (isDeployed(_vault)) revert AlreadyDeployed();

        bytes memory creationCode = _getCreationCode(_vault);

        deployed = CREATE3.deploy(getSalt(_vault), creationCode, 0);

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
        predicted = CREATE3.getDeployed(getSalt(_vault), address(this));
    }

    /**
     * @dev Checks if an ERC4626StreamHub instance is deployed for the given vault contract address.
     * @param _vault The address of the vault contract.
     * @return bool Returns true if an ERC4626StreamHub instance is deployed, false otherwise.
     */
    function isDeployed(address _vault) public view returns (bool) {
        return predictDeploy(_vault).code.length > 0;
    }

    /**
     * @dev Returns the salt for the CREATE3 deployment.
     * @param _vault The address of the vault contract.
     */
    function getSalt(address _vault) public pure returns (bytes32) {
        return keccak256(abi.encode(_vault));
    }

    /**
     * @dev Returns the creation code for the CREATE3 deployment.
     * @param _vault The address of the vault contract.
     */
    function _getCreationCode(address _vault) internal view virtual returns (bytes memory);

    function _checkZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert AddressZero();
    }
}
