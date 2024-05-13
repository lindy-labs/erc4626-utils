# Properties of YieldStreams

## Overview of the YieldStreams

The smart contract YieldStreams introduces a unique method for yield streaming, utilizing ERC721 tokens to represent individual streams and integrating ERC4626 vaults for yield generation. Each yield stream is uniquely identified by an ERC721 token, allowing for transparent tracking and management. Users can easily create, replenish, transfer, and close yield streams, while also directing generated yield to designated beneficiaries. Leveraging the ERC4626 standard for tokenized vault interactions, the system ensures that these tokens appreciate over time, generating yield for their holders. This cohesive approach combines the benefits of ERC721 streams and ERC4626 vaults, providing a robust framework for managing and profiting from yield streams.

It has mainly the following state variables:
* `vault` (type `IERC4626`), The ERC4626 vault contract used for yield generation.
* `asset` (type `IERC20`), The underlying ERC20 asset of the ERC4626 vault.
* `receiverTotalShares` (type `mapping(address => uint256)`), A mapping that tracks the total number of shares allocated to each receiver across all their yield streams.
* `receiverTotalPrincipal` (type `mapping(address => uint256)`), A mapping that tracks the total principal amount (in asset units) allocated to each receiver across all their yield streams.
* `receiverPrincipal` (type `mapping(address => mapping(uint256 => uint256))`), A nested mapping that tracks the principal amount (in asset units) allocated to each individual yield stream for each receiver.
* `streamIdToReceiver` (type `mapping(uint256 => address)`), A mapping that associates each yield stream ID (ERC721 token ID) with the receiver's address.
* `nextStreamId` (type `uint256`), A counter that keeps track of the next available ID for a new yield stream (ERC721 token).
* `name_` (type `string`), The name of the ERC721 token representing the yield streams.
* `symbol_` (type `string`), The symbol of the ERC721 token representing the yield streams.

It has the following external/functions that change state variables:
* `open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) public returns (uint256 streamId)`, Opens a new yield stream between the caller (streamer) and a receiver, allocating ERC4626 shares as principal.
* `openUsingPermit(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 streamId)`, Opens a new yield stream using ERC4626 permit for approval.
* `openMultiple(uint256 _shares, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance) public returns (uint256[] memory streamIds)`, Opens multiple yield streams between the caller and multiple receivers, allocating ERC4626 shares as principal.
* `openMultipleUsingPermit(uint256 _shares, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256[] memory streamIds)`, Opens multiple yield streams using ERC4626 permit for approval.
* `depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) public returns (uint256 streamId)`, Opens a new yield stream between the caller and a receiver, allocating the underlying ERC20 asset as principal.
* `depositAndOpenUsingPermit(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 streamId)`, Opens a new yield stream using ERC20 permit for approval, allocating the underlying asset as principal.
* `depositAndOpenMultiple(uint256 _principal, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance) public returns (uint256[] memory streamIds)`, Opens multiple yield streams between the caller and multiple receivers, allocating the underlying ERC20 asset as principal.
* `depositAndOpenMultipleUsingPermit(uint256 _principal, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256[] memory streamIds)`, Opens multiple yield streams using ERC20 permit for approval, allocating the underlying asset as principal.
* `topUp(uint256 _streamId, uint256 _shares) public returns (uint256 principal)`, Adds additional ERC4626 shares to an existing yield stream, increasing the principal allocated to the receiver.
* `topUpUsingPermit(uint256 _streamId, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 principal)`, Adds additional ERC4626 shares to an existing yield stream using permit for approval.
* `depositAndTopUp(uint256 _streamId, uint256 _principal) public returns (uint256 shares)`, Adds additional principal (underlying ERC20 asset) to an existing yield stream, increasing the allocated principal.
* `depositAndTopUpUsingPermit(uint256 _streamId, uint256 _principal, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256 shares)`, Adds additional principal (underlying ERC20 asset) to an existing yield stream using permit for approval.
* `close(uint256 _streamId) external returns (uint256 shares)`, Closes an existing yield stream, returning the remaining shares (principal) to the streamer.
* `claimYield(address _sendTo) external returns (uint256 assets)`, Claims the generated yield from all streams for the caller and transfers it as the underlying asset to a specified address.
* `claimYieldInShares(address _sendTo) external returns (uint256 yieldInShares)`, Claims the generated yield from all streams for the caller and transfers it as ERC4626 shares to a specified address.

It has the following view functions, which do not change state:
* `name() public view override returns (string memory)`, Inherited from ERC721, returns the name of the ERC721 token.
* `symbol() public view override returns (string memory)`, Inherited from ERC721, returns the symbol of the ERC721 token.
* `tokenURI(uint256 id) public view virtual override returns (string memory)`, Inherited from ERC721, returns the URI for a given token ID.
* `previewOpen(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) public view returns (uint256 principal)`, Previews the principal amount that would be allocated when opening a new stream with shares.
* `previewDepositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) public view returns (uint256 shares)`, Previews the shares that would be allocated when opening a new stream with the underlying ERC20 asset as principal.
* `previewClose(uint256 _streamId) public view returns (uint256 shares)`, Previews the shares that would be returned upon closing a yield stream.
* `previewClaimYield(address _receiver) public view returns (uint256 yield)`, Provides an estimation of the yield available to be claimed by the specified receiver in asset units.
* `previewClaimYieldInShares(address _receiver) public view returns (uint256 yieldInShares)`, Provides an estimation of the yield available to be claimed by the specified receiver in share units.
* `debtFor(address _receiver) public view returns (uint256)`, Calculates the total debt for a given receiver across all yield streams.
* `getPrincipal(uint256 _streamId) external view returns (uint256)`, Retrieves the principal amount allocated to a specific yield stream.


## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
| | `open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance)` should create a new yield stream with the correct parameters and update the contract state accordingly, regardless of the caller | high level | high | N | N | [Link]() |
| | `openMultiple(uint256 _shares, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance)` should create multiple new yield streams with the correct parameters and update the contract state accordingly, regardless of the caller | high level | high | N | N | [Link]() |
| | `depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance)` should create a new yield stream with the correct parameters, deposit the specified principal amount, and update the contract state accordingly, regardless of the caller | high level | high | N | N | [Link]() |
| | `depositAndOpenMultiple(uint256 _principal, address[] calldata _receivers, uint256[] calldata _allocations, uint256 _maxLossOnOpenTolerance)` should create multiple new yield streams with the correct parameters, deposit the specified principal amount, and update the contract state accordingly, regardless of the caller | high level | high | N | N | [Link]() |
| | `topUp(uint256 _streamId, uint256 _shares)` should add the specified shares to the existing yield stream and update the contract state accordingly, if the caller is the owner of the stream | high level | high | N | N | [Link]() |
| | `depositAndTopUp(uint256 _streamId, uint256 _principal)` should add the specified principal amount to the existing yield stream, deposit the principal, and update the contract state accordingly, if the caller is the owner of the stream | high level | high | N | N | [Link]() |
| | `close(uint256 _streamId)` should close the specified yield stream, return the remaining shares to the caller (if the caller is the owner), and update the contract state accordingly | high level | high | N | N | [Link]() |
| | `claimYield(address _sendTo)` should calculate and transfer the total yield generated for the caller across all their yield streams to the specified address, and update the contract state accordingly | high level | high | N | N | [Link]() |
| | `claimYieldInShares(address _sendTo)` should calculate and transfer the total yield generated for the caller across all their yield streams in the form of shares to the specified address, and update the contract state accordingly | high level | high | N | N | [Link]() |
