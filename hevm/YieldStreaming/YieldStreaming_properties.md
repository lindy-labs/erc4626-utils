# Properties of YieldStreaming

## Overview of the YieldStreaming

The YieldStreaming contract streamlines the administration of yield exchanges between individuals sending and receiving ERC4626 tokens. It enables users to initiate yield streams, collect yields from these streams, and terminate streams to retrieve any remaining shares. The contract operates under the assumption that ERC4626 tokens are appreciating assets, thereby indicating that the value of each share grows over time, generating yields.

* `receiverShares` (type `mapping(address => uint256)`), receiver to number of shares it is entitled to as the yield beneficiary;
* `receiverTotalPrincipal` (type `mapping(address => uint256)`), receiver to total amount of assets (principal)---not claimable;
* `receiverPrincipal` (type `mapping(address => mapping(address => uint256))`), receiver to total amount of assets (principal) allocated from a single address.

The YieldStreaming has the following external/public functions that change state variables:

* `function openYieldStream(address _receiver, uint256 _shares) public returns (uint256 principal)`, Opens a yield stream for a specific receiver with a given number of shares. If stream already exists, it will be topped up. When opening a new stream for a receiver who is in debt, the sender is taking a small amount of immediate loss. Acceptable loss amount is defined by the loss tolerance percentage configuration field;
* `openYieldStreamUsingPermit(address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public returns (uint256 principal)`, Opens a yield stream for a specific receiver with a given number of shares using the ERC20 permit functionality to obtain the necessary allowance. When opening a new stream, the sender is taking an immediate loss if the receiver is in debt. Acceptable loss is defined by the loss tolerance percentage configured for the contract;
* `function depositAndOpenYieldStream(address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public returns (uint256 shares)`, Deposits assets (principal) into the underlying vault and opens or tops up a yield stream for a specific receiver (****);
* `function depositAndOpenYieldStreamUsingPermit(address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 shares)`, Deposits assets (principal) into the underlying vault and opens or tops up a yield stream for a specific receiver using the ERC20 permit functionality to obtain the necessary allowance (****);
* `function closeYieldStream(address _receiver) public returns (uint256 shares)`, Closes a yield stream for a specific receiver. If there is any yield to claim for the stream, it will remain unclaimed until the receiver calls `claimYield` function;
* `function closeYieldStreamAndWithdraw(address _receiver) external returns (uint256 principal)`, Closes a yield stream for a specific receiver and withdraws the principal amount (****);
* `function claimYield(address _sendTo) external returns (uint256 assets)`, Claims the yield from all streams for the sender and transfers it to the specified receiver address;
* `function claimYieldInShares(address _sendTo) external returns (uint256 shares)`, Claims the yield from all streams for the sender and transfers it to the specified receiver address as shares;

It has the following external/public functions that are view only and change nothing:
* `function previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares)`, Calculates the amount of shares that would be recovered by closing a yield stream for a specific receiver;
* `function _previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares, uint256 principal)`;
* `function previewClaimYield(address _receiver) public view returns (uint256 yield)`, Calculates the yield for a given receiver;
* `function previewClaimYieldInShares(address _receiver) public view returns (uint256 yieldInShares)`, Calculates the yield for a given receiver as claimable shares;
* `function debtFor(address _receiver) public view returns (uint256)`, Calculates the debt for a given receiver. The receiver is in debt all streams he is entitled to have negative yield in total;


## Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 1 | [Symbolic test checking that openYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L32) | Y | Y |
| 2 | [Symbolic test checking openYieldStreamUsingPermit updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L60) | Y | Y |  
| 3 | [Symbolic test checking depositAndOpenYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L86) | Y | Y |
| 4 | [Symbolic test checking depositAndOpenYieldStreamUsingPermit updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L113) | Y | Y |
| 5 | [Checks closeYieldStream updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L140) | Y | Y |
| 6 | [Checks that opening and closing the same yield stream does not change shares and total principal (they are complementary operations)](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L165) | Y | Y |
| 7 | [Checks closeYieldStreamAndWithdraw updates receiver state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L165) | Y | Y | 
| 8 | [Checks that deposit and opening and closing with withdraw the same yield stream does not change shares and total principal (they are complementary operations)](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L165) | Y | Y |
| 9 | [Symbolic test checking claimYield transfers correct asset amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L190) | Y | Y |
| 10 | [Checks claimYieldInShares transfers correct share amount and updates state](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L229) | Y | Y |
## Revertable Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 9 | [Checks that constructing YieldStreaming with a zero vault address reverts](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L254) | Y | Y |
| 10 | [Checks that openYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L258) | Y | Y |  
| 11 | [Checks that openYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L276) | Y | Y |
| 12 | [Checks that openYieldStream should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L294) | Y | Y |
| 13 | [Checks that openYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L312) | Y | Y |
| 14 | [Checks that openYieldStream should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L330) | Y | Y |
| 15 | [Checks that openYieldStreamUsingPermit should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L348) | Y | Y |
| 16 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L366) | Y | Y |
| 17 | [Checks that openYieldStreamUsingPermit should revert when the _shares amount parameter is 0](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L384) | Y | Y |
| 18 | [Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L402) | Y | Y |
| 19 | [Checks that openYieldStreamUsingPermit should revert when the deadline parameter is less than the current block timestamp](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L420) | Y | Y |
| 20 | [Checks that openYieldStreamUsingPermit should revert when the vault allowance for the contract is less than the _shares amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L438) | Y | Y |
| 21 | [Checks that openYieldStreamUsingPermit should revert when the receiver has no existing debt](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L456) | Y | Y |
| 22 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L474) | Y | Y |
| 23 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the _receiver is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L492) | Y | Y |  
| 24 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the msg.sender equals _receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L510) | Y | Y |
| 25 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the _amount equals zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L528) | Y | Y |
| 26 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the allowance is less than _amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L546) | Y | Y | 
| 27 | [Checks that openYieldSdepositAndOpenYieldStreamtream should revert when principal equals zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L564) | Y | Y |
| 28 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when msg.sender equals the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L582) | Y | Y |
| 29 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when _receiver equals the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L600) | Y | Y |
| 30 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when msg.sender equals _receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L618) | Y | Y |
| 31 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when _amount equals zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L636) | Y | Y |  
| 32 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when allowance is less than _amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L654) | Y | Y |
| 33 | [Checks that depositAndOpenYieldStreamUsingPermit should revert when principal equals zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L672) | Y | Y |
| 34 | [Checks that closeYieldStream should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L690) | Y | Y | 
| 35 | [Checks that closeYieldStream should revert when the _receiver address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L708) | Y | Y |
| 36 | [Checks that closeYieldStream should revert when the _receiver address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L726) | Y | Y |
| 37 | [Checks that closeYieldStream should revert when previewCloseYieldStream returns 0 principal](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L744) | Y | Y |
| 38 | [Checks that closeYieldStreamAndWithdraw should revert when msg.sender equals the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L762) | Y | Y |
| 39 | [Checks that closeYieldStreamAndWithdraw should revert when _receiver equals the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L780) | Y | Y |
| 40 | [Checks that closeYieldStreamAndWithdraw should revert when msg.sender equals _receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L798) | Y | Y |
| 41 | [Checks that closeYieldStreamAndWithdraw should revert when principal equals zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L816) | Y | Y |
| 42 | [Checks that claimYield should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L834) | Y | Y |
| 43 | [Checks that claimYield should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L852) | Y | Y |
| 44 | [Checks that claimYield should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L870) | Y | Y |
| 45 | [Checks that claimYield should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L888) | Y | Y |
| 46 | [Checks that claimYield should revert when the vault token balance is less than the yield share amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L906) | Y | Y |
| 47 | [Checks that claimYieldInShares should revert when the msg.sender is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L924) | Y | Y | 
| 48 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L942) | Y | Y |
| 49 | [Checks that claimYieldInShares should revert when the _sendTo address parameter is the same as the msg.sender](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L960) | Y | Y |
| 50 | [Checks that claimYieldInShares should revert when previewClaimYieldInShares returns 0 shares](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/YieldStreaming/YieldStreaming_FV.sol#L978) | Y | Y |
