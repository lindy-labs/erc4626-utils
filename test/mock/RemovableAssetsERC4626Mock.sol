// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {ERC4626Mock} from "openzeppelin-contracts/mocks/token/ERC4626Mock.sol";

contract RemovableAssetsERC4626Mock is ERC4626Mock {
    constructor(address _asset, string memory _name, string memory _symbol) ERC4626Mock(_asset) {}

    /// @dev removing assets allows to simualte a drop in share price
    /// @dev to simuulate an increase in share price it is enough to just transfer assets directly to the contract
    function removeAssets(uint256 _amount, address _sendTo) external {
        IERC20(this.asset()).transfer(_sendTo, _amount);
    }
}
