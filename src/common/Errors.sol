// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// *** common errors *** ///

error AmountZero();
error AddressZero();

// *** streaming errors *** ///

error CannotOpenStreamToSelf();
error StreamDoesNotExist();

// *** factory errors *** ///

error AlreadyDeployed();
