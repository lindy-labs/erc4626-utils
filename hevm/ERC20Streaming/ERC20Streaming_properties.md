# Properties of ERC20Streaming

## Overview of the ERC20Streaming

The ERC20Streaming contract enables the seamless streaming of ERC20 tokens, assigning distinct stream IDs to each streamer-receiver duo. Within this contract, users can initiate, replenish, withdraw from, and terminate streams. It's important to highlight that receivers are limited to claiming from one stream at a time, although they can leverage multicall functionality as a workaround if needed.

The ERC20Streaming has the following state variables:
* `lossTolerancePercent` (type `uint256`) (initial value `0.01e18`), this loss tolerance percent is set to 1%

And the following constant:
* `MAX_LOSS_TOLERANCE_PERCENT` (type `uint256`) (value `0.05e18`), this is the max loss tolerance percent and it has a constant value of 5%

The ERC20Streaming has the following external/public functions that change state variables:

* `function openYieldStream(address _receiver, uint256 _shares) public returns (uint256 principal)`, Opens a yield stream for a specific receiver with a given number of shares. If stream already exists, it will be topped up. When opening a new stream for a receiver who is in debt, the sender is taking a small amount of immediate loss. Acceptable loss amount is defined by the loss tolerance percentage configuration field;

It has the following external/public function that is privileged and changes settings:

* `function setLossTolerancePercent(uint256 _newlossTolerancePercent) external onlyOwner`, Sets the loss tolerance percentage for the contract;

It has the following external/public functions that are view only and change nothing:
* `function previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares)`, Calculates the amount of shares that would be recovered by closing a yield stream for a specific receiver;


## Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 1 | [Symbolic test checking that openYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming_FV.sol#L32) | Y | Y |

## Revertable Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 6 | [Checks that constructing ERC20Streaming with a zero vault address reverts](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming_FV.sol#L178) | Y | Y |
