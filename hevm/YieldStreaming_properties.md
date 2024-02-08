# Properties of YieldStreaming

## Overview of the YieldStreaming

The YieldStreaming contract streamlines the administration of yield exchanges between individuals sending and receiving ERC4626 tokens. It enables users to initiate yield streams, collect yields from these streams, and terminate streams to retrieve any remaining shares. The contract operates under the assumption that ERC4626 tokens are appreciating assets, thereby indicating that the value of each share grows over time, generating yields.

The YieldStreaming has the following state variables:
* `lossTolerancePercent` (type `uint256`) (initial value `0.01e18`), this loss tolerance percent is set to 1%
* `receiverShares` (type `mapping(address => uint256)`), receiver to number of shares it is entitled to as the yield beneficiary;
* `receiverTotalPrincipal` (type `mapping(address => uint256)`), receiver to total amount of assets (principal)---not claimable;
* `receiverPrincipal` (type `mapping(address => mapping(address => uint256))`), receiver to total amount of assets (principal) allocated from a single address.

And the following constant:
* `MAX_LOSS_TOLERANCE_PERCENT` (type `uint256`) (value `0.05e18`), this is the max loss tolerance percent and it has a constant value of 5%

The YieldStreaming has the following external/public functions that change state variables:

* `function openYieldStream(address _receiver, uint256 _shares) public returns (uint256 principal)`, Opens a yield stream for a specific receiver with a given number of shares. If stream already exists, it will be topped up. When opening a new stream for a receiver who is in debt, the sender is taking a small amount of immediate loss. Acceptable loss amount is defined by the loss tolerance percentage configuration field;
* `openYieldStreamUsingPermit(address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public returns (uint256 principal)`, Opens a yield stream for a specific receiver with a given number of shares using the ERC20 permit functionality to obtain the necessary allowance. When opening a new stream, the sender is taking an immediate loss if the receiver is in debt. Acceptable loss is defined by the loss tolerance percentage configured for the contract;
* `function closeYieldStream(address _receiver) public returns (uint256 shares)`, Closes a yield stream for a specific receiver. If there is any yield to claim for the stream, it will remain unclaimed until the receiver calls `claimYield` function;
* `function claimYield(address _sendTo) external returns (uint256 assets)`, Claims the yield from all streams for the sender and transfers it to the specified receiver address;
* `function claimYieldInShares(address _sendTo) external returns (uint256 shares)`, Claims the yield from all streams for the sender and transfers it to the specified receiver address as shares;

It has the following external/public function that is privileged and changes settings:

* `function setLossTolerancePercent(uint256 _newlossTolerancePercent) external onlyOwner`, Sets the loss tolerance percentage for the contract;

It has the following external/public functions that are view only and change nothing:
* `function previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares)`, Calculates the amount of shares that would be recovered by closing a yield stream for a specific receiver;
* `function _previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares, uint256 principal)`;
* `function previewClaimYield(address _receiver) public view returns (uint256 yield)`, Calculates the yield for a given receiver;
* `function previewClaimYieldInShares(address _receiver) public view returns (uint256 yieldInShares)`, Calculates the yield for a given receiver as claimable shares;
* `function debtFor(address _receiver) public view returns (uint256)`, Calculates the debt for a given receiver. The receiver is in debt all streams he is entitled to have negative yield in total;


## Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 1 | [`constructor` reverts if `vault == address(0)`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L31) | Y | Y |
| 2 | [`constructor` reverts if `owner == address(0)`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L35) | Y | Y |
| 3 | [`setLossTolerancePercent` reverts if `caller != owner`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L39) | Y | Y |
| 4 | [`setLossTolerancePercent` reverts if `newToleramce > maxLossTolerance`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L45) | Y | Y |
| 5 | [`setLossTolerancePercent` updates the `lossTolerancePercent` to `newToleramce`, if `newToleramce <= maxLossTolerance`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L50) | Y | Y |
| 6 | [`debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal) <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L57) | Y | Y |
| 7 | [Integrity of `openYieldStream`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L66) | Y | Y |
| 8 | [Integrity of `openYieldStreamUsingPermit`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L92) | Y | Y |
| 9 | [Integrity of `closeYieldStream`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L117) | Y | Y |
| 10 | [Integrity of `claimYield`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L141) | Y | Y |
| 11 | [Integrity of `claimYieldInShares`](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L179) | Y | Y |
