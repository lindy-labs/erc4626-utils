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
| 1 | [Symbolic test checking that openYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L32) | Y | Y |
| 2 | [Symbolic test checking openYieldStreamUsingPermit updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L60) | Y | Y |
| 3 | [Checks closeYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L86) | Y | Y |
| 4 | [Symbolic test checking claimYield transfers correct asset amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L111) | Y | Y |
| 5 | [Checks claimYieldInShares transfers correct share amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L150) | Y | Y |

## Revertable Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 6 | [Checks that constructing YieldStreaming with a zero vault address reverts](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L178) | Y | Y |
| 7 | [Checks that openYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L183) | Y | Y |
| 8 | [Checks that openYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L201) | Y | Y |
| 9 | [Checks that openYieldStream should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L218) | Y | Y |
| 10 | [Checks that openYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L236) | Y | Y |
| 11 | [Checks that openYieldStream should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L254) | Y | Y |
| 12 | [Checks that openYieldStreamUsingPermit should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L272) | Y | Y |
| 13 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L287) | Y | Y |
| 14 | [Checks that openYieldStreamUsingPermit should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L302) | Y | Y |
| 15 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L317) | Y | Y |
| 16 | [Checks that openYieldStreamUsingPermit should revert when the deadline parameter is less than the current block timestamp](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L332) | Y | Y |
| 17 | [Checks that openYieldStreamUsingPermit should revert when the vault allowance for the contract is less than the _shares amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L347) | Y | Y |
| 18 | [Checks that openYieldStreamUsingPermit should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L362) | Y | Y |
| 19 | [Checks that closeYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L377) | Y | Y |
| 20 | [Checks that closeYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L392) | Y | Y |
| 21 | [Checks that closeYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L407) | Y | Y |
| 22 | [Checks that closeYieldStream should revert when previewCloseYieldStream returns 0 principal](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L422) | Y | Y |
| 23 | [Checks that claimYield should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L437) | Y | Y |
| 24 | [Checks that claimYield should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L457) | Y | Y |
| 25 | [Checks that claimYield should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L477) | Y | Y |
| 26 | [Checks that claimYield should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L497) | Y | Y |
| 27 | [Checks that claimYield should revert when the vault token balance is less than the yield share amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L517) | Y | Y |
| 28 | [Checks that claimYieldInShares should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L537) | Y | Y |
| 29 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L553)  | Y | Y |
| 30 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L569) | Y | Y |
| 31 | [Checks that claimYieldInShares should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L585) | Y | Y |