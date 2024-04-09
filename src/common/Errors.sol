// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// *** common errors *** ///

error TransferExceedsAllowance();
error AmountZero();
error AddressZero();

// *** streaming errors *** ///

error CannotOpenStreamToSelf();

// *** factory errors *** ///

error AlreadyDeployed();
