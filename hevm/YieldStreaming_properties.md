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
| 1 | [Checks that constructing YieldStreaming with a zero vault address reverts](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L31) | Y | Y |
| 2 | [Checks that constructing YieldStreaming with a zero owner address reverts](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L37) | Y | Y |
| 3 | [Checks that setLossTolerancePercent fails if called by someone other than the owner](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L42) | Y | Y |
| 4 | [Checks that setLossTolerancePercent fails if trying to set above the maximum](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L49) | Y | Y |
| 5 | [Checks that setLossTolerancePercent updates lossTolerancePercent](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L55) | Y | Y |
| 6 | [Auxiliary function for the symbolic test prove_integrity_of_openYieldStream below. Checks loss on open is within tolerance](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L63) | Y | Y |
| 7 | [Symbolic test checking that openYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L73) | Y | Y |
| 8 | [Symbolic test checking openYieldStreamUsingPermit updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L100) | Y | Y |
| 9 | [Checks closeYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L125) | Y | Y |
| 10 | [Symbolic test checking claimYield transfers correct asset amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L151) | Y | Y |
| 11 | [Checks claimYieldInShares transfers correct share amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L190) | Y | Y |

## Revertable Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 1 | [Checks that openYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L218) | Y | Y |
| 2 | [Checks that openYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L237) | Y | Y |
| 3 | [Checks that openYieldStream should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L256) | Y | Y |  
| 4 | [Checks that openYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L275) | Y | Y |
| 5 | [Checks that openYieldStream should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L294) | Y | Y |
| 6 | [Checks that openYieldStreamUsingPermit should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L314) | Y | Y |
| 7 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L333) | Y | Y |  
| 8 | [Checks that openYieldStreamUsingPermit should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L352) | Y | Y |
| 9 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L371) | Y | Y |
| 10 | [Checks that openYieldStreamUsingPermit should revert when the deadline parameter is less than the current block timestamp](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L390) | Y | Y |
| 11 | [Checks that openYieldStreamUsingPermit should revert when the vault allowance for the contract is less than the _shares amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L409) | Y | Y |
| 12 | [Checks that openYieldStreamUsingPermit should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L428) | Y | Y |  
| 13 | [Checks that closeYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L447) | Y | Y |
| 14 | [Checks that closeYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L466) | Y | Y |
| 15 | [Checks that closeYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L485) | Y | Y |
| 16 | [Checks that closeYieldStream should revert when previewCloseYieldStream returns 0 principal](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L504) | Y | Y |
| 17 | [Checks that claimYield should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L523) | Y | Y | 
| 18 | [Checks that claimYield should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L542) | Y | Y |
| 19 | [Checks that claimYield should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L561) | Y | Y |
| 20 | [Checks that claimYield should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L580) | Y | Y |
| 21 | [Checks that claimYield should revert when the vault token balance is less than the yield share amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L599) | Y | Y |
| 22 | [Checks that claimYieldInShares should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L618) | Y | Y |
| 23 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L637) | Y | Y |
| 24 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L656) | Y | Y | 
| 25 | [Checks that claimYieldInShares should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming_FV.sol#L675) | Y | Y |