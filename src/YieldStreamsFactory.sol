// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {CREATE3} from "solmate/utils/CREATE3.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";

import {YieldStreams} from "./YieldStreams.sol";
import {CommonErrors} from "./common/CommonErrors.sol";

/**
 * @title YieldStreamsFactory
 * @notice Factory contract to deploy YieldStreams instances.
 */
contract YieldStreamsFactory {
    using CommonErrors for address;

    /**
     * @dev Emitted when a new YieldStreams contract instance is deployed.
     * @param caller The address of the caller of the create function.
     * @param vault The address of the underlying ERC4626 vault contract.
     * @param yieldStreams The address of the deployed YieldStreams contract instance.
     */
    event Deployed(address indexed caller, address vault, address yieldStreams);

    error AlreadyDeployed();

    /// @dev The addresses of deployed YieldStreams instances.
    address[] public deployedAddresses;
    /// @dev The number of deployed YieldStreams instances.
    uint256 public deployedCount;

    /**
     * @dev Creates a new instance of the YieldStreams contract.
     * @param _vault The address of the underlying ERC4626 vault contract.
     * @return deployed The address of the deployed YieldStreams contract instance.
     */
    function create(IERC4626 _vault) public virtual returns (YieldStreams deployed) {
        address(_vault).checkIsZero();

        if (isDeployed(_vault)) revert AlreadyDeployed();

        bytes memory creationCode = abi.encodePacked(type(YieldStreams).creationCode, abi.encode(_vault));

        deployed = YieldStreams(CREATE3.deploy(getSalt(_vault), creationCode, 0));

        deployedAddresses.push(address(deployed));

        unchecked {
            deployedCount++;
        }

        emit Deployed(msg.sender, address(_vault), address(deployed));
    }

    /**
     * @dev Predicts the address of the deployed YieldStreams contract instance.
     * @param _vault The address of the underlying ERC4626 vault contract.
     * @return predicted The predicted address of the deployed YieldStreams contract instance.
     */
    function predictDeploy(IERC4626 _vault) public view returns (YieldStreams predicted) {
        predicted = YieldStreams(CREATE3.getDeployed(getSalt(_vault), address(this)));
    }

    /**
     * @dev Checks if a YieldStreams contract instance is deployed for the given ERC4626 vault address.
     * @param _vault The address of the ERC4626 vault contract.
     * @return bool Returns true if the YieldStreams contract instance is deployed, false otherwise.
     */
    function isDeployed(IERC4626 _vault) public view returns (bool) {
        return address(predictDeploy(_vault)).code.length > 0;
    }

    /**
     * @dev Returns the salt for the CREATE3 deployment.
     * @param _vault The address of the underlying ERC4626 vault contract.
     */
    function getSalt(IERC4626 _vault) public pure returns (bytes32) {
        return keccak256(abi.encode(_vault));
    }
}
