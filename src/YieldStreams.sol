// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

import {CommonErrors} from "./common/CommonErrors.sol";

/**
 * @title YieldStreams
 * @notice Implements a yield streaming system where streams are represented as ERC721 tokens and uses ERC4626 vaults for yield generation.
 * @dev Each yield stream is uniquely identified by an ERC721 token, allowing for transparent tracking and management of individual streams.
 * This contract enables users to create, top-up, transfer, and close yield streams, as well as facilitating the flow of yield from appreciating assets to designated beneficiaries (receivers).
 * It leverages the ERC4626 standard for tokenized vault interactions, assuming that these tokens appreciate over time, generating yield for their holders.
 *
 * ## Key Features
 * - **Stream Management:** Allows users to open, top-up, transfer, and close yield streams represented by ERC721 tokens.
 * - **Yield Generation:** Utilizes ERC4626 vaults for generating yield on deposited assets.
 * - **Ownership and Transferability:** Uses ERC721 standard for ownership and transferability of yield streams.
 * - **Multicall Support:** Supports batched execution of multiple functions in a single transaction for gas optimization and convenience.
 *
 * ## External Integrations
 * - **ERC4626 Vault:** Manages the underlying asset and generates yield.
 * - **ERC20 Token:** Acts as the underlying asset for the ERC4626 vault.
 *
 * ## Security Considerations
 * - **Input Validation:** Ensures all input parameters are valid and within acceptable ranges.
 * - **Ownership and Transferability:** Uses ERC721 standard to ensure only approved operators can manage yield streams.
 * - **Use of Safe Libraries:** Utilizes SafeTransferLib and other safety libraries to prevent overflows and other potential issues.
 * - **Non-Upgradeable:** The contract is designed to be non-upgradeable to simplify security and maintainability.
 *
 * ## Usage
 * Users can open and manage yield streams using both direct interactions and ERC20 permit-based approvals. Each stream is represented as an ERC721 token, enabling easy tracking and management of individual investments. The contract also supports multicall functionality, allowing users to execute multiple operations in a single transaction for enhanced efficiency.
 */
contract YieldStreams is ERC721, Multicall {
    using CommonErrors for uint256;
    using CommonErrors for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    /**
     * @notice Emitted when a new yield stream is opened between a streamer and a receiver.
     * @param caller The address of the caller who initiated the stream opening.
     * @param owner The address that owns the ERC721 token representing the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * @param shares The number of shares allocated to the new yield stream.
     * @param principal The principal amount in asset units, i.e., the value of the shares at the time of opening the stream.
     */
    event StreamOpened(
        address caller,
        address indexed owner,
        address indexed receiver,
        uint256 indexed streamId,
        uint256 shares,
        uint256 principal
    );

    /**
     * @notice Emitted when more shares are added to an existing yield stream.
     * @param caller The address of the caller who initiated the top-up.
     * @param owner The address that owns the ERC721 token representing the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param streamId The unique identifier of the yield stream (ERC721 token) to which shares are added.
     * @param shares The number of additional shares added to the yield stream.
     * @param principal The principal amount in asset units, i.e., the value of the shares at the time of the addition.
     */
    event StreamToppedUp(
        address caller,
        address indexed owner,
        address indexed receiver,
        uint256 indexed streamId,
        uint256 shares,
        uint256 principal
    );

    /**
     * @notice Emitted when a yield stream is closed, returning the remaining shares to the streamer.
     * @param caller The address of the caller who initiated the stream closure.
     * @param owner The address that owns the ERC721 token representing the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param streamId The unique identifier of the yield stream that is being closed, represented by an ERC721 token.
     * @param shares The number of shares returned to the owner upon closing the yield stream.
     * @param principal The principal amount in asset units, i.e., the value of the shares at the time of closing the stream.
     */
    event StreamClosed(
        address caller,
        address indexed owner,
        address indexed receiver,
        uint256 indexed streamId,
        uint256 shares,
        uint256 principal
    );

    /**
     * @notice Emitted when the yield generated from a stream is claimed by the receiver and transferred to a specified address.
     * @param caller The address of the caller who initiated the yield claim.
     * @param receiver The address of the receiver for the yield stream.
     * @param claimedTo The address where the claimed yield is sent.
     * @param assetsClaimed The total amount of assets claimed as realized yield, set to zero if yield is claimed in shares.
     * @param sharesClaimed The total amount of shares claimed as realized yield, set to zero if yield is claimed in assets.
     */
    event YieldClaimed(
        address indexed caller,
        address indexed receiver,
        address indexed claimedTo,
        uint256 assetsClaimed,
        uint256 sharesClaimed
    );

    /**
     * @notice Emitted when the CID (Content Identifier) is updated for a token.
     * @param caller The address of the caller who updated the CID.
     * @param owner The address that owns the token.
     * @param tokenId The ID of the token for which the CID was updated.
     * @param cid The new CID associated with the token.
     */
    event TokenCIDUpdated(address indexed caller, address indexed owner, uint256 indexed tokenId, string cid);

    // Errors
    error OwnerZeroAddress();
    error ReceiverZeroAddress();
    error NoYieldToClaim();
    error LossToleranceExceeded();
    error InputArrayEmpty();
    error InputArraysLengthMismatch(uint256 length1, uint256 length2);
    error NotReceiverNorApprovedClaimer();
    error EmptyCID();

    /// @notice the underlying ERC4626 vault
    IERC4626 public immutable vault;
    /// @notice the underlying ERC20 asset of the ERC4626 vault
    IERC20 public immutable asset;

    /**
     * @notice Mapping of receiver addresses to the total shares amount allocated to their streams.
     * @dev This mapping tracks the total number of shares allocated to each receiver across all their yield streams.
     */
    mapping(address => uint256) public receiverTotalShares;

    /**
     * @notice Mapping of receiver addresses to the total principal amount allocated to their streams.
     * @dev This mapping tracks the total principal amount allocated to each receiver across all their yield streams, expressed in asset units.
     */
    mapping(address => uint256) public receiverTotalPrincipal;

    /**
     * @notice Mapping of receiver addresses to the principal amount allocated to each stream.
     * @dev This mapping tracks the principal amount allocated to each yield stream for a given receiver, represented as (receiver => (streamId => principal)).
     */
    mapping(address => mapping(uint256 => uint256)) public receiverPrincipal;

    /**
     * @notice Mapping of stream ID to receiver address.
     * @dev This mapping tracks the receiver address associated with each yield stream, identified by the ERC721 token ID.
     */
    mapping(uint256 => address) public streamIdToReceiver;

    /**
     * @notice Mapping of receiver addresses to approved claimers.
     * @dev This mapping allows receivers to approve specific addresses to claim yield on their behalf.
     */
    mapping(address => mapping(address => bool)) public receiverToApprovedClaimers;

    /**
     * @notice Mapping from token ID to IPFS CID (Content Identifier).
     * @dev This mapping stores the IPFS CID associated with each token ID.
     * The CID is used to generate the tokenURI.
     */
    mapping(uint256 => string) public tokenCIDs;

    /**
     * @notice Identifier of the next stream to be opened (ERC721 token ID).
     * @dev This variable holds the identifier for the next yield stream to be opened, ensuring unique ERC721 token IDs for each stream.
     */
    uint256 public nextStreamId = 1;

    // ERC721 name and symbol
    string private name_;
    string private symbol_;

    /**
     * @notice Initializes the YieldStreams contract by setting up the ERC721 token with custom names and linking it to the specified ERC4626 vault.
     * @dev The constructor initializes the ERC721 token's name and symbol based on the underlying vault's characteristics. It also sets up the vault and asset references, and grants maximum approval for the vault to manage the asset.
     * @param _vault The address of the ERC4626 vault that will be used for yield generation. This vault manages the underlying asset and facilitates yield generation through its tokenized structure.
     */
    constructor(IERC4626 _vault) {
        address(_vault).revertIfZero();

        name_ = string.concat("Yield Stream - ", _vault.name());
        symbol_ = string.concat("YS-", _vault.symbol());

        vault = _vault;
        asset = IERC20(_vault.asset());

        address(asset).safeApprove(address(vault), type(uint256).max);
    }

    /*
    * =======================================================
    *                   EXTERNAL FUNCTIONS
    * =======================================================
    */

    /// @inheritdoc ERC721
    function name() public view override returns (string memory) {
        return name_;
    }

    /// @inheritdoc ERC721
    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    /**
     * @notice Returns the URI for a given token ID.
     * @dev This function returns the full IPFS URL based on the CID stored for the token.
     * If the CID is not set, it returns an empty string.
     * @param _tokenId The ID of the token to get the URI for.
     * @return The full IPFS URL for the token's metadata, or an empty string if no CID is set.
     *
     * @custom:requirements
     * - The `_tokenId` must represent an existing token.
     *
     * @custom:reverts
     * - `ERC721.TokenDoesNotExist` if the `_tokenId` does not represent an existing token.
     */
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        if (!_exists(_tokenId)) revert ERC721.TokenDoesNotExist();

        string memory cid = tokenCIDs[_tokenId];

        if (bytes(cid).length == 0) return "";

        return string(abi.encodePacked("ipfs://", cid));
    }

    /**
     * @notice Sets the IPFS CID (Content Identifier) for a given token ID.
     * @dev This function allows the owner or an approved operator to set the CID for a token.
     * The CID is used to generate the tokenURI.
     * @param _tokenId The ID of the token to set the CID for.
     * @param _cid The CID to be associated with the token.
     *
     * @custom:requirements
     * - The `_cid` must not be an empty string.
     * - The caller must be the owner or an approved operator of the `_tokenId`.
     *
     * @custom:reverts
     * - `EmptyCID` if the `_cid` is an empty string.
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {TokenCIDUpdated} event upon successful CID update.
     */
    function setTokenCID(uint256 _tokenId, string memory _cid) public {
        bytes(_cid).length.revertIfZero(EmptyCID.selector);
        _checkOwnerOrApproved(_tokenId);

        tokenCIDs[_tokenId] = _cid;

        emit TokenCIDUpdated(msg.sender, _ownerOf(_tokenId), _tokenId, _cid);
    }

    /**
     * @notice Opens a new yield stream between the caller (streamer) and a receiver, represented by an ERC721 token.
     * @dev When a new stream is opened, an ERC721 token is minted to the specified owner address, uniquely identifying the stream.
     * This token represents the ownership of the yield stream and can be held, transferred, or utilized in other contracts.
     * The function calculates the principal amount based on the shares provided and updates the total principal allocated to the receiver.
     * If the receiver is in debt (where the total value of their streams is less than the allocated principal), the function checks if the new shares would cause an immediate loss exceeding the specified tolerance.
     *
     * @param _owner The address that will own the ERC721 token representing the yield stream. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of shares to allocate to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_shares` amount must be greater than zero.
     * - The new shares allocated to the receiver must not cause the streamer's tolerated loss, due to the receiver's existing debt, to be exceeded.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event upon successful stream creation.
     */
    function open(address _owner, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance)
        public
        returns (uint256 streamId)
    {
        _owner.revertIfZero(OwnerZeroAddress.selector);

        uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

        streamId = _openStream(_owner, _receiver, _shares, principal);

        _vaultTransferFrom(msg.sender, _shares);
    }

    /**
     * @notice Provides a preview of the principal amount based on the shares to be allocated and verifies if the receiver's existing debt would cause an immediate loss exceeding the specified tolerance.
     * @dev This function checks if the operation to open a new yield stream would exceed the specified loss tolerance for the streamer by considering the receiver's existing debt.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of shares to allocate to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return principal The principal amount in asset units, i.e., the value of the shares at the time of opening the stream.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     * - The `_shares` amount must be greater than zero.
     * - The loss incurred by the new shares, due to the receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     */
    function previewOpen(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance)
        public
        view
        returns (uint256 principal)
    {
        principal = vault.convertToAssets(_shares);

        _canOpenStream(_receiver, _shares, principal, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens a new yield stream for a specified receiver using ERC4626 permit for setting the allowance.
     * @dev This function allows opening of a new yield stream without requiring a separate approval transaction, by utilizing the "permit" functionality.
     * It enables a seamless user experience by allowing approval and stream creation in a single transaction.
     * The function mints a new ERC721 token to represent the yield stream, assigning ownership to the specified owner.
     *
     * @param _owner The address that will own the ERC721 token representing the yield stream. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of ERC4626 vault shares to allocate to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_shares` amount must be greater than zero.
     * - The loss incurred by the new shares, due to the receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event upon successful stream creation.
     */
    function openUsingPermit(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerance,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 streamId) {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, _deadline, v, r, s);

        streamId = open(_owner, _receiver, _shares, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens multiple yield streams between a specified owner and multiple receivers, represented by ERC721 tokens.
     * @dev When new streams are opened, ERC721 tokens are minted to the specified owner address, uniquely identifying each stream.
     * These tokens represent the ownership of the yield streams and can be held, transferred, or utilized in other contracts.
     * The function calculates the principal amount based on the shares provided and verifies if the receiver's existing debt would cause an immediate loss exceeding the specified tolerance.
     * If a receiver is in debt, the new shares will share the existing loss proportionally.
     *
     * @param _owner The address that will own the ERC721 tokens representing the yield streams. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _shares The total number of shares to allocate to the yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver (in WAD format, e.g., 0.1e18 for 10%).
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening each stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_shares` amount must be greater than zero.
     * - The lengths of `_receivers` and `_allocations` arrays must be equal and greater than zero.
     * - The sum of `_allocations` must not exceed `1e18` (100% in WAD format).
     * - The loss incurred by the new shares, due to each receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage for any receiver.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     * - `InputArrayEmpty` if the `_receivers` array is empty.
     * - `InputArraysLengthMismatch` if the lengths of `_receivers` and `_allocations` arrays do not match.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event for each successful stream creation.
     */
    function openMultiple(
        address _owner,
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) public returns (uint256[] memory streamIds) {
        _owner.revertIfZero(OwnerZeroAddress.selector);
        _shares.revertIfZero();

        uint256 principal = vault.convertToAssets(_shares);
        uint256 totalSharesAllocated;
        (totalSharesAllocated, streamIds) =
            _openStreams(_owner, _shares, principal, _receivers, _allocations, _maxLossOnOpenTolerance);

        _vaultTransferFrom(msg.sender, totalSharesAllocated);
    }

    /**
     * @notice Opens multiple yield streams between a specified owner and multiple receivers using ERC4626 permit for setting the allowance.
     * @dev This function allows opening of multiple yield streams without requiring separate approval transactions, by utilizing the "permit" functionality.
     * The function mints new ERC721 tokens to represent the yield streams, assigning ownership to the specified owner.
     *
     * @param _owner The address that will own the ERC721 tokens representing the yield streams. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _shares The total number of shares to allocate to the yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver (in WAD format, e.g., 0.1e18 for 10%).
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening each stream (in WAD format, e.g., 0.01e18 for 1%).
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_shares` amount must be greater than zero.
     * - The lengths of `_receivers` and `_allocations` arrays must be equal and greater than zero.
     * - The sum of `_allocations` must not exceed `1e18` (100% in WAD format).
     * - The loss incurred by the new shares, due to each receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage for any receiver.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     * - `InputArrayEmpty` if the `_receivers` array is empty.
     * - `InputArraysLengthMismatch` if the lengths of `_receivers` and `_allocations` arrays do not match.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event for each successful stream creation.
     */
    function openMultipleUsingPermit(
        address _owner,
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[] memory streamIds) {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, _deadline, v, r, s);

        streamIds = openMultiple(_owner, _shares, _receivers, _allocations, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens a new yield stream between a specified owner and a receiver, represented by an ERC721 token.
     * @dev The specified principal amount of the vault's underlying ERC20 asset is deposited to obtain corresponding shares,
     * which are used to generate yield for the receiver. When a new stream is opened, an ERC721 token is minted to the specified owner address,
     * uniquely identifying the stream. This token represents the ownership of the yield stream and can be held, transferred, or utilized in other contracts.
     *
     * @param _owner The address that will own the ERC721 token representing the yield stream. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_principal` amount must be greater than zero.
     * - The loss incurred by the new shares, due to the receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event upon successful stream creation.
     */
    function depositAndOpen(address _owner, address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance)
        public
        returns (uint256 streamId)
    {
        _owner.revertIfZero(OwnerZeroAddress.selector);

        uint256 shares = _depositToVault(msg.sender, _principal);

        _canOpenStream(_receiver, shares, _principal, _maxLossOnOpenTolerance);

        streamId = _openStream(_owner, _receiver, shares, _principal);
    }

    /**
     * @notice Provides a preview of the shares that would be allocated upon opening a new yield stream with the specified principal amount.
     * @dev This function calculates the number of shares that would be obtained by depositing the given principal amount into the ERC4626 vault.
     * It also checks if opening the stream would exceed the specified loss tolerance due to the receiver's existing debt.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return shares The estimated number of shares that would be allocated to the receiver upon opening the yield stream.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     * - The `_principal` amount must be greater than zero.
     * - The loss incurred by the new shares, due to the receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     */
    function previewDepositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance)
        public
        view
        returns (uint256 shares)
    {
        shares = vault.convertToShares(_principal);

        _canOpenStream(_receiver, shares, _principal, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens a new yield stream for a specified receiver using the vault's underlying ERC20 asset and ERC20 permit for setting the allowance.
     * @dev This function allows opening of a new yield stream without requiring a separate approval transaction, by utilizing the "permit" functionality.
     * It enables a seamless user experience by allowing approval and stream creation in a single transaction.
     * The function mints a new ERC721 token to represent the yield stream, assigning ownership to the specified owner.
     * The specified principal amount of the vault's underlying ERC20 asset is deposited to obtain corresponding shares,
     * which are used to generate yield for the receiver.
     *
     * @param _owner The address that will own the ERC721 token representing the yield stream. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream (in WAD format, e.g., 0.01e18 for 1%).
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_principal` amount must be greater than zero.
     * - The loss incurred by the new shares, due to the receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event upon successful stream creation.
     */
    function depositAndOpenUsingPermit(
        address _owner,
        address _receiver,
        uint256 _principal,
        uint256 _maxLossOnOpenTolerance,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 streamId) {
        IERC20Permit(address(vault.asset())).permit(msg.sender, address(this), _principal, _deadline, v, r, s);

        streamId = depositAndOpen(_owner, _receiver, _principal, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens multiple yield streams between a specified owner and multiple receivers, represented by ERC721 tokens.
     * @dev The streamer allocates a specified amount of the vault's underlying ERC20 asset to each stream, representing the principal amount.
     * This amount is then deposited to the ERC4626 vault to obtain the corresponding shares, which are used to generate yield for the respective receivers.
     * Any unallocated shares are returned to the streamer.
     * The function mints new ERC721 tokens to represent each yield stream, assigning ownership to the specified owner.
     *
     * @param _owner The address that will own the ERC721 tokens representing the yield streams. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _principal The total principal amount in asset units to be allocated to new yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver (in WAD format, e.g., 0.1e18 for 10%).
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening each stream (in WAD format, e.g., 0.01e18 for 1%).
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_principal` amount must be greater than zero.
     * - The lengths of `_receivers` and `_allocations` arrays must be equal and greater than zero.
     * - The sum of `_allocations` must not exceed `1e18` (100% in WAD format).
     * - The loss incurred by the new shares, due to each receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage for any receiver.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     * - `InputArrayEmpty` if the `_receivers` array is empty.
     * - `InputArraysLengthMismatch` if the lengths of `_receivers` and `_allocations` arrays do not match.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event for each successful stream creation.
     */
    function depositAndOpenMultiple(
        address _owner,
        uint256 _principal,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) public returns (uint256[] memory streamIds) {
        _owner.revertIfZero(OwnerZeroAddress.selector);
        _principal.revertIfZero();

        uint256 shares = _depositToVault(msg.sender, _principal);
        uint256 totalSharesAllocated;
        (totalSharesAllocated, streamIds) =
            _openStreams(_owner, shares, _principal, _receivers, _allocations, _maxLossOnOpenTolerance);

        // let this revert on underflow
        _vaultTransferTo(msg.sender, shares - totalSharesAllocated);
    }

    /**
     * @notice Opens multiple yield streams for a specified owner and multiple receivers using the vault's underlying ERC20 asset and ERC20 permit for setting the allowance.
     * @dev This function allows opening multiple yield streams without requiring separate approval transactions, by utilizing the "permit" functionality.
     * It enables a seamless user experience by allowing approval and stream creation in a single transaction.
     * The function mints new ERC721 tokens to represent each yield stream, assigning ownership to the specified owner.
     * The specified principal amount of the vault's underlying ERC20 asset is deposited to obtain corresponding shares,
     * which are used to generate yield for the respective receivers. Any unallocated shares are returned to the streamer.
     *
     * @param _owner The address that will own the ERC721 tokens representing the yield streams. If the owner is a contract, it must implement IERC721Receiver-onERC721Received.
     * @param _principal The total principal amount in asset units to be allocated to new yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver (in WAD format, e.g., 0.1e18 for 10%).
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening each stream (in WAD format, e.g., 0.01e18 for 1%).
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     *
     * @custom:requirements
     * - The `_owner` address must not be the zero address.
     * - If the `_owner` address is a contract, it must implement `IERC721Receiver-onERC721Received`.
     * - The `_principal` amount must be greater than zero.
     * - The lengths of `_receivers` and `_allocations` arrays must be equal and greater than zero.
     * - The sum of `_allocations` must not exceed `1e18` (100% in WAD format).
     * - The loss incurred by the new shares, due to each receiver's existing debt, must not exceed the `_maxLossOnOpenTolerance` percentage for any receiver.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `OwnerZeroAddress` if the `_owner` address is the zero address.
     * - `LossToleranceExceeded` if the loss incurred by the new shares exceeds the specified tolerance.
     * - `InputArrayEmpty` if the `_receivers` array is empty.
     * - `InputArraysLengthMismatch` if the lengths of `_receivers` and `_allocations` arrays do not match.
     *
     * @custom:emits
     * - Emits a {StreamOpened} event for each successful stream creation.
     */
    function depositAndOpenMultipleUsingPermit(
        address _owner,
        uint256 _principal,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[] memory streamIds) {
        IERC20Permit(address(asset)).permit(msg.sender, address(this), _principal, _deadline, v, r, s);

        streamIds = depositAndOpenMultiple(_owner, _principal, _receivers, _allocations, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Adds additional shares to an existing yield stream, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is either the owner or an approved operator of the ERC721 token associated with the yield stream.
     * The specified number of shares are transferred from the owner's balance to the contract, and the corresponding principal amount is added to the yield stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _shares The number of additional shares to be added to the yield stream.
     * @return principal The added principal amount in asset units.
     *
     * @custom:requirements
     * - The `_shares` amount must be greater than zero.
     * - The caller must be the owner or an approved operator of the specified `_streamId`.
     *
     * @custom:reverts
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {StreamToppedUp} event upon successful addition of shares to the stream.
     */
    function topUp(uint256 _streamId, uint256 _shares) public returns (uint256 principal) {
        _shares.revertIfZero();
        _checkOwnerOrApproved(_streamId);

        principal = vault.convertToAssets(_shares);

        _topUpStream(_streamId, _shares, principal);

        _vaultTransferFrom(_ownerOf(_streamId), _shares);
    }

    /**
     * @notice Adds additional shares to an existing yield stream using ERC20 permit for setting the allowance, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is either the owner or an approved operator of the ERC721 token associated with the yield stream.
     * It uses the ERC20 permit function to approve the token transfer and top-up the yield stream in a single transaction.
     * The specified number of shares are transferred from the owner's balance to the contract, and the corresponding principal amount is added to the yield stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _shares The number of additional shares to be added to the yield stream.
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return principal The added principal amount in asset units.
     *
     * @custom:requirements
     * - The `_shares` amount must be greater than zero.
     * - The caller must be the owner or an approved operator of the specified `_streamId`.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {StreamToppedUp} event upon successful addition of shares to the stream.
     */
    function topUpUsingPermit(uint256 _streamId, uint256 _shares, uint256 _deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 principal)
    {
        IERC20Permit(address(vault)).permit(_ownerOf(_streamId), address(this), _shares, _deadline, v, r, s);

        principal = topUp(_streamId, _shares);
    }

    /**
     * @notice Adds additional principal to an existing yield stream, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is either the owner or an approved operator of the ERC721 token associated with the yield stream.
     * The specified principal amount of the vault's underlying ERC20 asset is deposited to obtain the corresponding shares,
     * which are then added to the yield stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _principal The additional principal amount in asset units to be added to the yield stream.
     * @return shares The added number of shares to the yield stream.
     *
     * @custom:requirements
     * - The `_principal` amount must be greater than zero.
     * - The caller must be the owner or an approved operator of the specified `_streamId`.
     *
     * @custom:reverts
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {StreamToppedUp} event upon successful addition of principal to the stream.
     */
    function depositAndTopUp(uint256 _streamId, uint256 _principal) public returns (uint256 shares) {
        _principal.revertIfZero();
        _checkOwnerOrApproved(_streamId);

        shares = _depositToVault(_ownerOf(_streamId), _principal);

        _topUpStream(_streamId, shares, _principal);
    }

    /**
     * @notice Adds additional principal to an existing yield stream using ERC20 permit for setting the allowance, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is either the owner or an approved operator of the ERC721 token associated with the yield stream.
     * It uses the ERC20 permit function to approve the token transfer and top-up the yield stream in a single transaction.
     * The specified principal amount of the vault's underlying ERC20 asset is deposited to obtain the corresponding shares,
     * which are then added to the yield stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _principal The additional principal amount in asset units to be added to the yield stream.
     * @param _deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return shares The added number of shares to the yield stream.
     *
     * @custom:requirements
     * - The `_principal` amount must be greater than zero.
     * - The caller must be the owner or an approved operator of the specified `_streamId`.
     * - The permit must be valid and signed correctly.
     *
     * @custom:reverts
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {StreamToppedUp} event upon successful addition of principal to the stream.
     */
    function depositAndTopUpUsingPermit(
        uint256 _streamId,
        uint256 _principal,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        IERC20Permit(address(vault.asset())).permit(_ownerOf(_streamId), address(this), _principal, _deadline, v, r, s);

        shares = depositAndTopUp(_streamId, _principal);
    }

    /**
     * @notice Closes an existing yield stream identified by the ERC721 token, returning the remaining shares to the streamer. Any outstanding yield is not automatically claimed.
     * @dev The function requires that the caller is either the owner or an approved operator of the ERC721 token associated with the yield stream.
     * Upon closure, the function calculates and returns the remaining shares to the streamer,
     * after which the ERC721 token representing the yield stream is burned to ensure it cannot be reused or transferred.
     * This action effectively removes the stream from the contract's tracking, settling any allocated principal and shares back to the streamer.
     *
     * @param _streamId The unique identifier of the yield stream to be closed, represented by an ERC721 token.
     * @return shares The number of shares returned to the streamer upon closing the yield stream.
     * This represents the balance of shares not attributed to generated yield, effectively the remaining principal.
     *
     * @custom:requirements
     * - The caller must be the owner or an approved operator of the specified `_streamId`.
     *
     * @custom:reverts
     * - `ERC721.NotOwnerNorApproved` if the caller is not the owner or an approved operator.
     *
     * @custom:emits
     * - Emits a {StreamClosed} event upon successful stream closure.
     */
    function close(uint256 _streamId) external returns (uint256 shares) {
        _checkOwnerOrApproved(_streamId);

        uint256 principal;
        (shares, principal) = previewClose(_streamId);
        address owner = _ownerOf(_streamId);
        address receiver = streamIdToReceiver[_streamId];

        _burn(_streamId);

        // update state and transfer shares
        delete streamIdToReceiver[_streamId];
        delete receiverPrincipal[receiver][_streamId];

        // TODO: address this if possible
        // possible to underflow because of rounding errors
        receiverTotalPrincipal[receiver] -= principal;
        receiverTotalShares[receiver] -= shares;

        emit StreamClosed(msg.sender, owner, receiver, _streamId, shares, principal);

        _vaultTransferTo(owner, shares);
    }

    /**
     * @notice Provides a preview of the shares that would be returned upon closing a yield stream identified by an ERC721 token.
     * @dev This function calculates and returns the number of shares and respected value in asset units (i.e. principal) that would be credited back to the streamer upon closing the stream.
     * Note that if closing a stream while receiver is in debt, the principal value returned is greater than the actual shares value.
     *
     * @param _streamId The unique identifier associated with an active yield stream.
     * @return shares The estimated number of shares that would be returned to the streamer, representing the principal in share terms.
     * @return principal The expected value of returned shares in asset units, representing the remaining principal.
     *
     * @custom:requirements
     * - The `_streamId` must represent an existing yield stream.
     */
    function previewClose(uint256 _streamId) public view returns (uint256 shares, uint256 principal) {
        address receiver = streamIdToReceiver[_streamId];
        principal = _getPrincipal(_streamId, receiver);

        if (principal == 0) return (0, 0);

        // asset amount of equivalent shares
        uint256 ask = vault.convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[receiver];

        // calculate the maximum amount of shares that can be attributed to the sender as a percentage of the sender's share of the total principal.
        uint256 have = receiverTotalShares[receiver].mulDiv(principal, totalPrincipal);

        // true if there was a loss (negative yield)
        shares = ask > have ? have : ask;
    }

    /**
     * @notice Claims the generated yield from all streams for the specified receiver and transfers it to a specified address.
     * @dev This function calculates the total yield generated for the receiver across all yield streams where they are the designated receiver.
     * This function redeems the shares representing the generated yield, converting them into the underlying asset and transferring the resultant assets to a specified address.
     * Note that this function operates on all yield streams associated with the receiver, aggregating the total yield available.
     *
     * @param _receiver The address of the receiver for whom the yield is being claimed.
     * @param _sendTo The address where the claimed yield should be sent. This can be the caller's address or another specified recipient.
     * @return assets The total amount of assets claimed as realized yield from all streams.
     *
     * @custom:requirements
     * - The `_sendTo` address must not be the zero address.
     * - The caller must be an approved claimer or the receiver.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     * - `NotReceiverNorApprovedClaimer` if the caller is not an approved claimer or the receiver.
     * - `NoYieldToClaim` if there is no yield to claim.
     *
     * @custom:emits
     * - Emits a {YieldClaimed} event with `sharesClaimed` set to `0` upon successful yield claim, as the yield is claimed in the form of assets.
     */
    function claimYield(address _receiver, address _sendTo) external returns (uint256 assets) {
        _sendTo.revertIfZero();

        uint256 yieldInShares = _claim(_receiver);

        assets = vault.redeem(yieldInShares, _sendTo, address(this));

        emit YieldClaimed(msg.sender, _receiver, _sendTo, assets, 0);
    }

    /**
     * @notice Provides an estimation of the yield available to be claimed by the specified receiver.
     * @dev Calculates the total yield that can be claimed by the receiver across all their yield streams.
     * The yield is determined by the difference between the current value of the shares allocated to the receiver and their total principal.
     *
     * @param _receiver The address of the receiver for whom the yield preview is being requested.
     * @return yield The estimated amount of yield available to be claimed by the receiver, expressed in the underlying asset units.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     */
    function previewClaimYield(address _receiver) public view returns (uint256 yield) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = vault.convertToAssets(receiverTotalShares[_receiver]);

        // if vault made a loss, there is no yield
        unchecked {
            yield = currentValue > principal ? currentValue - principal : 0;
        }
    }

    /**
     * @notice Claims the generated yield from all streams for the specified receiver and transfers it in shares to a specified address.
     * @dev This function enables receivers to claim the yield generated across all their yield streams in the form of shares, rather than the underlying asset.
     * It calculates the total yield in shares that the caller can claim, then transfers those shares to the specified address.
     * The operation is based on the difference between the current share value allocated to the receiver and the total principal in share terms.
     *
     * Unlike `claimYield`, which redeems shares for the underlying asset and transfers the assets, `claimYieldInShares` directly transfers the shares,
     * keeping the yield within the same asset class. This might be preferable for receivers looking to maintain their position in the underlying vault.
     *
     * @param _receiver The address of the receiver for whom the yield is being claimed.
     * @param _sendTo The address where the claimed yield shares should be sent. This can be the caller's address or another specified recipient.
     * @return yieldInShares The total number of shares claimed as yield and transferred to the `_sendTo` address.
     *
     * @custom:requirements
     * - The `_sendTo` address must not be the zero address.
     * - The caller must be an approved claimer or the receiver.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     * - `NotReceiverNorApprovedClaimer` if the caller is not an approved claimer or the receiver.
     * - `NoYieldToClaim` if there is no yield to claim.
     *
     * @custom:emits
     * - Emits a {YieldClaimed} event with `assetsClaimed` set to `0` upon successful yield claim, as the yield is claimed in the form of shares.
     */
    function claimYieldInShares(address _receiver, address _sendTo) external returns (uint256 yieldInShares) {
        _sendTo.revertIfZero();

        yieldInShares = _claim(_receiver);

        emit YieldClaimed(msg.sender, _receiver, _sendTo, 0, yieldInShares);

        _vaultTransferTo(_sendTo, yieldInShares);
    }

    /**
     * @notice Provides an estimation of the yield available to be claimed by the specified receiver in share terms.
     * @dev Calculates the total yield that can be claimed by the receiver across all their yield streams.
     * The yield is determined by the difference between the current value of the shares allocated to the receiver and their total principal in share terms.
     *
     * @param _receiver The address of the receiver for whom the yield preview is being requested.
     * @return yieldInShares The estimated amount of yield available to be claimed by the receiver, expressed in shares.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     */
    function previewClaimYieldInShares(address _receiver) public view returns (uint256 yieldInShares) {
        uint256 principalInShares = vault.convertToShares(receiverTotalPrincipal[_receiver]);
        uint256 shares = receiverTotalShares[_receiver];

        unchecked {
            // if vault made a loss, there is no yield
            yieldInShares = shares > principalInShares ? shares - principalInShares : 0;
        }
    }

    /**
     * @notice Approves a specified address to claim yield on behalf of the receiver.
     * @dev This function allows the receiver to authorize another address to claim yield from their streams.
     *
     * @param _claimer The address to be approved for claiming yield on behalf of the receiver.
     *
     * @custom:requirements
     * - The caller must be the receiver authorizing the claim.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     */
    function approveClaimer(address _claimer) external {
        _claimer.revertIfZero();

        receiverToApprovedClaimers[msg.sender][_claimer] = true;
    }

    /**
     * @notice Revokes approval for a specified address to claim yield on behalf of the receiver.
     * @dev This function allows the receiver to revoke the authorization for another address to claim yield from their streams.
     *
     * @param _claimer The address whose approval is being revoked.
     *
     * @custom:requirements
     * - The caller must be the receiver revoking the claim approval.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     */
    function revokeClaimer(address _claimer) external {
        _claimer.revertIfZero();

        receiverToApprovedClaimers[msg.sender][_claimer] = false;
    }

    /**
     * @notice Checks if a specified address is an approved claimer for the receiver.
     * @dev This function verifies if the specified address is authorized to claim yield on behalf of the receiver.
     *
     * @param _claimer The address to check for claim approval.
     * @param _receiver The address of the receiver whose approval is being checked.
     * @return bool True if the `_claimer` is approved to claim yield on behalf of the `_receiver`, false otherwise.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     */
    function isApprovedClaimer(address _claimer, address _receiver) public view returns (bool) {
        if (_claimer == _receiver) return true;

        return receiverToApprovedClaimers[_receiver][_claimer];
    }

    /**
     * @notice Calculates the total debt for a given receiver across all yield streams.
     * @dev The debt is calculated by comparing the current total asset value of the receiver's shares against the total principal.
     * If the asset value exceeds the principal, indicating a positive yield, the function returns zero, as there is no debt.
     * Conversely, if the principal exceeds the asset value, the function returns the difference, quantifying the receiver's debt.
     *
     * @param _receiver The address of the receiver for whom the debt is being calculated.
     * @return debt The total calculated debt for the receiver, expressed in the underlying asset units.
     * If the receiver has no debt or a positive yield, the function returns zero.
     *
     * @custom:requirements
     * - The `_receiver` address must not be the zero address.
     *
     * @custom:reverts
     * - `ReceiverZeroAddress` if the `_receiver` address is the zero address.
     */
    function debtFor(address _receiver) public view returns (uint256) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 shares = receiverTotalShares[_receiver];
        uint256 sharePrice = vault.convertToAssets(shares).divWadUp(shares);

        return _calculateDebt(shares, principal, sharePrice);
    }

    /**
     * @notice Retrieves the principal amount allocated to a specific yield stream, identified by the ERC721 token ID.
     * @dev This function returns the principal amount in asset units that was initially allocated to the yield stream.
     *
     * @param _streamId The unique identifier of the yield stream for which the principal is being queried, represented by an ERC721 token.
     * @return principal The principal amount in asset units initially allocated to the yield stream identified by the given token ID.
     *
     * @custom:requirements
     * - The `_streamId` must represent an existing yield stream.
     */
    function getPrincipal(uint256 _streamId) external view returns (uint256) {
        return _getPrincipal(_streamId, streamIdToReceiver[_streamId]);
    }

    /**
     * @notice Checks if the specified account is the owner or an approved operator of the given yield stream.
     * @dev This function verifies ownership or approval status for the specified ERC721 token representing the yield stream.
     *
     * @param _account The address of the account to check for ownership or approval.
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to check.
     * @return bool True if the `_account` is the owner or an approved operator of the `_streamId`, false otherwise.
     *
     * @custom:requirements
     * - The `_streamId` must represent an existing yield stream.
     */
    function isOwnerOrApproved(address _account, uint256 _streamId) external view returns (bool) {
        return _isApprovedOrOwner(_account, _streamId);
    }

    /* 
    * =======================================================
    *                   INTERNAL FUNCTIONS
    * =======================================================
    */

    // accounting logic for opening a new stream
    function _openStream(address _owner, address _receiver, uint256 _shares, uint256 _principal)
        internal
        returns (uint256 streamId)
    {
        unchecked {
            // id's are not going to overflow
            streamId = nextStreamId++;

            _safeMint(_owner, streamId);
            streamIdToReceiver[streamId] = _receiver;

            // not realistic to overflow
            receiverTotalShares[_receiver] += _shares;
            receiverTotalPrincipal[_receiver] += _principal;
            receiverPrincipal[_receiver][streamId] = _principal;
        }

        emit StreamOpened(msg.sender, _owner, _receiver, streamId, _shares, _principal);
    }

    // accounting logic for opening multiple streams
    function _openStreams(
        address _owner,
        uint256 _shares,
        uint256 _principal,
        address[] memory _receivers,
        uint256[] memory _allocations,
        uint256 _maxLossOnOpenTolerance
    ) internal returns (uint256 totalSharesAllocated, uint256[] memory streamIds) {
        _checkInputArraysLength(_receivers, _allocations);

        streamIds = new uint256[](_receivers.length);

        address receiver;
        uint256 allocation;
        uint256 sharesAllocation;
        uint256 principalAllocation;

        for (uint256 i = 0; i < _receivers.length;) {
            receiver = _receivers[i];
            allocation = _allocations[i];
            sharesAllocation = _shares.mulWad(allocation);
            principalAllocation = _principal.mulWad(allocation);

            _canOpenStream(receiver, sharesAllocation, principalAllocation, _maxLossOnOpenTolerance);
            streamIds[i] = _openStream(_owner, receiver, sharesAllocation, principalAllocation);

            unchecked {
                totalSharesAllocated += sharesAllocation;

                i++;
            }
        }
    }

    // accounting logic for topping up a stream
    function _topUpStream(uint256 _streamId, uint256 _shares, uint256 _principal) internal {
        address _receiver = streamIdToReceiver[_streamId];

        //  not realsitic to overflow
        unchecked {
            receiverTotalShares[_receiver] += _shares;
            receiverTotalPrincipal[_receiver] += _principal;
            receiverPrincipal[_receiver][_streamId] += _principal;
        }

        emit StreamToppedUp(msg.sender, _ownerOf(_streamId), _receiver, _streamId, _shares, _principal);
    }

    // accounting logic for claiming yield
    function _claim(address _receiver) internal returns (uint256 yieldInShares) {
        _receiver.revertIfZero(ReceiverZeroAddress.selector);
        _checkReceiverOrApprovedClaimer(msg.sender, _receiver);

        yieldInShares = previewClaimYieldInShares(_receiver);
        yieldInShares.revertIfZero(NoYieldToClaim.selector);

        unchecked {
            // impossible to underflow because total shares are always > yield
            receiverTotalShares[_receiver] -= yieldInShares;
        }
    }

    function _depositToVault(address _from, uint256 _amount) internal returns (uint256 shares) {
        address(asset).safeTransferFrom(_from, address(this), _amount);

        shares = vault.deposit(_amount, address(this));
    }

    function _getPrincipal(uint256 _streamId, address _receiver) internal view returns (uint256) {
        return receiverPrincipal[_receiver][_streamId];
    }

    function _canOpenStream(address _receiver, uint256 _shares, uint256 _principal, uint256 _maxLossOnOpenTolerance)
        internal
        view
    {
        _receiver.revertIfZero(ReceiverZeroAddress.selector);
        _principal.revertIfZero();

        // when opening a new stream from sender, check if the receiver is in debt
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];
        uint256 sharePrice = _principal.divWadUp(_shares);
        uint256 debt = _calculateDebt(receiverTotalShares[_receiver], totalPrincipal, sharePrice);

        if (debt == 0) return;

        // if the receiver is in debt, check if the sender is willing to take the immediate loss when opening a new stream.
        // the immediate loss is calculated as the percentage of the debt that the sender is taking as his share of the total principal allocated to the receiver.
        // acceptable loss is defined by the loss tolerance percentage param passed to the open function.
        // this loss occurs due to inability of the accounting logic to differentiate between principal amounts allocated from different streams to same receiver.
        unchecked {
            totalPrincipal = totalPrincipal + _principal;
        }

        uint256 lossOnOpen = debt.mulDivUp(_principal, totalPrincipal);
        uint256 maxLoss = _principal.mulWadUp(_maxLossOnOpenTolerance);

        if (lossOnOpen > maxLoss) revert LossToleranceExceeded();
    }

    function _calculateDebt(uint256 _totalShares, uint256 _totalPrincipal, uint256 _sharePrice)
        internal
        pure
        returns (uint256 debt)
    {
        uint256 currentValue = _totalShares.mulWadUp(_sharePrice);

        unchecked {
            debt = currentValue < _totalPrincipal ? _totalPrincipal - currentValue : 0;
        }
    }

    function _checkInputArraysLength(address[] memory _receivers, uint256[] memory _allocations) internal pure {
        _receivers.length.revertIfZero(InputArrayEmpty.selector);

        if (_receivers.length != _allocations.length) {
            revert InputArraysLengthMismatch(_receivers.length, _allocations.length);
        }
    }

    function _checkOwnerOrApproved(uint256 _positionId) internal view {
        if (!_isApprovedOrOwner(msg.sender, _positionId)) revert ERC721.NotOwnerNorApproved();
    }

    function _checkReceiverOrApprovedClaimer(address _claimer, address _receiver) internal view {
        if (!isApprovedClaimer(_claimer, _receiver)) revert NotReceiverNorApprovedClaimer();
    }

    function _vaultTransferFrom(address _from, uint256 _shares) internal {
        address(vault).safeTransferFrom(_from, address(this), _shares);
    }

    function _vaultTransferTo(address _to, uint256 _shares) internal {
        address(vault).safeTransfer(_to, _shares);
    }
}
