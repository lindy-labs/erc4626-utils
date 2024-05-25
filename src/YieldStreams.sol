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
 * @dev Implements a yield streaming system where streams are represented as ERC721 tokens and uses ERC4626 vaults for yield generation.
 * Each yield stream is uniquely identified by an ERC721 token, allowing for transparent tracking and management of individual streams.
 * This approach enables users to create, top-up, transfer, and close yield streams as well as facilitating the flow of yield from appreciating assets to designated beneficiaries (receivers).
 * It leverages the ERC4626 standard for tokenized vault interactions, assuming that these tokens appreciate over time, generating yield for their holders.
 */
contract YieldStreams is ERC721, Multicall {
    using CommonErrors for uint256;
    using CommonErrors for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    /**
     * @notice Emitted when a new yield stream is opened between a streamer and a receiver.
     * @param streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * @param streamer The address of the streamer who opened the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param shares The number of shares allocated to the new yield stream.
     * @param principal The principal amount in asset units, i.e. the value of the shares at the time of opening the stream.
     */
    event StreamOpened(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );

    /**
     * @notice Emitted when more shares are added to an existing yield stream.
     * @param streamId The unique identifier of the yield stream (ERC721 token) to which shares are added.
     * @param streamer The address of the streamer who added the shares to the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param shares The number of additional shares added to the yield stream.
     * @param principal The principal amount in asset units, i.e. the value of the shares at the time of the addition.
     */
    event StreamToppedUp(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );

    /**
     * @notice Emitted when the yield generated from a stream is claimed by the receiver and transferred to a specified address.
     * Either assetsClaimed or sharesClaimed will be non-zero depending on the type of yield claimed.
     * @param receiver The address of the receiver for the yield stream.
     * @param claimedTo The address where the claimed yield is sent.
     * @param assetsClaimed The total amount of assets claimed as realized yield, set to zero if yield is claimed in shares.
     * @param sharesClaimed The total amount of shares claimed as realized yield, set to zero if yield is claimed in assets.
     */
    event YieldClaimed(
        address indexed receiver, address indexed claimedTo, uint256 assetsClaimed, uint256 sharesClaimed
    );

    /**
     * @notice Emitted when a yield stream is closed, returning the remaining shares to the streamer.
     * @param streamId The unique identifier of the yield stream that is being closed, represented by an ERC721 token.
     * @param streamer The address of the streamer who is closing the yield stream.
     * @param receiver The address of the receiver for the yield stream.
     * @param shares The number of shares returned to the streamer upon closing the yield stream.
     * @param principal The principal amount in asset units, i.e. the value of the shares at the time of closing the stream.
     */
    event StreamClosed(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );

    // Errors
    error NoYieldToClaim();
    error LossToleranceExceeded();
    error InputArraysLengthMismatch(uint256 length1, uint256 length2);

    /// @notice the underlying ERC4626 vault
    IERC4626 public immutable vault;
    /// @notice the underlying ERC20 asset of the ERC4626 vault
    IERC20 public immutable asset;

    /// @notice receiver addresses to the total shares amount allocated to their streams
    mapping(address => uint256) public receiverTotalShares;
    /// @notice receiver addresses to the total principal amount allocated to their streams
    mapping(address => uint256) public receiverTotalPrincipal;
    /// @notice receiver addresses to the principal amount allocated to each stream (receiver => (streamId => principal))
    mapping(address => mapping(uint256 => uint256)) public receiverPrincipal;
    /// @notice stream ID to receiver address
    mapping(uint256 => address) public streamIdToReceiver;

    /// @notice identifier of the next stream to be opened (ERC721 token ID)
    uint256 public nextStreamId = 1;

    // ERC721 name and symbol
    string private name_;
    string private symbol_;

    /**
     * @notice Creates a new YieldStreams contract, initializing the ERC721 token with custom names and setting the vault address.
     * @dev The constructor initializes an ERC721 token with a dynamic name and symbol derived from the underlying vault's characteristics.
     * @param _vault Address of the ERC4626 vault
     */
    constructor(IERC4626 _vault) {
        address(_vault).checkIsZero();

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

    /// @inheritdoc ERC721
    function tokenURI(uint256 id) public view virtual override returns (string memory) {}

    /**
     * @notice Opens a new yield stream between the caller (streamer) and a receiver, represented by an ERC721 token.
     * The streamer allocates a specified number of ERC4626 shares to the stream, which are used to generate yield for the receiver.
     * Yield is defined as the difference between the current value of the shares in asset units and the value of the shares at the time of opening the stream (principal).
     * @dev When a new stream is opened, an ERC721 token is minted to the streamer, uniquely identifying the stream.
     * This token represents the ownership of the yield stream (and principal allocated to it) and can be held, transferred, or utilized in other contracts.
     * The function calculates the principal amount based on the shares provided, updating the total principal allocated to the receiver.
     * If the receiver is in debt (where the total value of their streams is less than the allocated principal),
     * the function assesses if the new shares would incur an immediate loss exceeding the streamer's specified tolerance.
     * Emits an Open event upon successful stream creation.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of shares to allocate to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * This parameter is crucial if the receiver is in debt, affecting the feasibility of opening the stream.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     */
    function open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance)
        public
        returns (uint256 streamId)
    {
        uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

        streamId = _openStream(_receiver, _shares, principal);

        _vaultTransferFrom(msg.sender, _shares);
    }

    /**
     * @notice Provides a preview of the shares that would be allocated upon opening a new yield stream and reverts if the operation would fail.
     *
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum loss percentage tolerated by the sender.
     * @return principal The principal amount in asset units (ie shares value at open)
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
     * @notice Opens a new yield stream with ERC4626 vault shares for a specified receiver using ERC4626 permit for setting the allowance.
     * @dev This function allows opening of a new yield stream without requiring a separate approval transaction, by utilizing the "permit" functionality.
     * It enables a seamless user experience by allowing approval and stream creation in a single transaction.
     * The function mints a new ERC721 token to represent the yield stream, assigning ownership to the streamer.
     * Emits an Open event upon successful stream creation.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of ERC4626 vault shares to allocate to the new yield stream. These shares are transferred from the streamer to the contract as part of the stream setup.
     * @param _maxLossOnOpenTolerance The maximum loss percentage that the streamer is willing to tolerate upon opening the yield stream.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * This token encapsulates the stream's details and ownership, enabling further interactions and management.
     */
    function openUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 streamId) {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        streamId = open(_receiver, _shares, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens multiple yield streams between the caller (streamer) and multiple receivers, represented by ERC721 tokens.
     * The streamer allocates a specified number of ERC4626 shares to each stream, which are used to generate yield for the respective receivers.
     * Only shares that are allocated to the streams are transferred to the contract.
     * @dev When new streams are opened, ERC721 tokens are minted to the streamer, uniquely identifying each stream.
     * These tokens represent the ownership of the yield streams (and principal allocated to them) and can be held, transferred, or utilized in other contracts.
     * If a receiver is in debt (where the total value of their streams is less than the allocated principal),
     * the function assesses if the new shares would incur an immediate loss exceeding the streamer's specified tolerance.
     * Emits an Open event for each successful stream creation.
     *
     * @param _shares The total number of shares to allocate to yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * This parameter is crucial if the receiver is in debt, affecting the feasibility of opening a stream.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     */
    function openMultiple(
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) public returns (uint256[] memory streamIds) {
        _shares.checkIsZero();

        uint256 principal = vault.convertToAssets(_shares);
        uint256 totalSharesAllocated;
        (totalSharesAllocated, streamIds) =
            _openStreams(_shares, principal, _receivers, _allocations, _maxLossOnOpenTolerance);

        _vaultTransferFrom(msg.sender, totalSharesAllocated);
    }

    /**
     * @notice Opens multiple yield streams between the caller (streamer) and multiple receivers using ERC4626 permit for setting the allowance.
     * Only shares that are allocated to the streams are transferred to the contract.
     * @dev This function allows opening of multiple yield streams without requiring separate approval transactions, by utilizing the "permit" functionality.
     * The function mints new ERC721 tokens to represent the yield streams, assigning ownership to the streamer.
     * Emits an Open event for each successful stream creation.
     *
     * @param _shares The total number of shares to allocate to yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver.
     * @param _maxLossOnOpenTolerance The maximum loss percentage tolerated by the sender.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     */
    function openMultipleUsingPermit(
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[] memory streamIds) {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        streamIds = openMultiple(_shares, _receivers, _allocations, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens a new yield stream between the caller (streamer) and a receiver, represented by an ERC721 token.
     * The streamer allocates a specified number of the vault's underlying ERC20 asset to the stream, representing the principal amount.
     * This amount is then deposited to the ERC4626 vault to obtan the corresponding shares, which are used to generate yield for the receiver.
     * Yield is defined as the difference between the current value of the shares in asset units and the value of the shares at the time of opening the stream (principal).
     * @dev When a new stream is opened, an ERC721 token is minted to the streamer, uniquely identifying the stream.
     * This token represents the ownership of the yield stream (and principal allocated to it) and can be held, transferred, or utilized in other contracts.
     * The function calculates the principal amount based on the shares provided, updating the total principal allocated to the receiver.
     * If the receiver is in debt (where the total value of their streams is less than the allocated principal),
     * the function assesses if the new shares would incur an immediate loss exceeding the streamer's specified tolerance.
     * Emits an Open event upon successful stream creation.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * This parameter is crucial if the receiver is in debt, affecting the feasibility of opening the stream.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * This token encapsulates the stream's details and ownership, enabling further interactions and management.
     */
    function depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance)
        public
        returns (uint256 streamId)
    {
        uint256 shares = _depositToVault(_principal);

        _canOpenStream(_receiver, shares, _principal, _maxLossOnOpenTolerance);

        streamId = _openStream(_receiver, shares, _principal);
    }

    /**
     * @notice Provides a preview of the shares that would be allocated upon opening a new yield stream with the specified principal amount,
     * and reverts if the operation would fail.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * @return shares The estimated number of shares that would be allocated to the receiver upon opening the yield stream.
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
     * @notice Opens a new yield stream with ERC4626 vault's underlying ERC20 asset for a specified receiver using ERC20 permit for setting the allowance.
     * @dev This function allows opening of a new yield stream without requiring a separate approval transaction, by utilizing the "permit" functionality.
     * It enables a seamless user experience by allowing approval and stream creation in a single transaction.
     * The function mints a new ERC721 token to represent the yield stream, assigning ownership to the streamer.
     * Emits an Open event upon successful stream creation.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _principal The principal amount in asset units to be allocated to the new yield stream.
     * @param _maxLossOnOpenTolerance The maximum loss percentage tolerated by the sender.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * This token encapsulates the stream's details and ownership, enabling further interactions and management.
     */
    function depositAndOpenUsingPermit(
        address _receiver,
        uint256 _principal,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 streamId) {
        IERC20Permit(vault.asset()).permit(msg.sender, address(this), _principal, deadline, v, r, s);

        streamId = depositAndOpen(_receiver, _principal, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Opens multiple yield streams between the caller (streamer) and multiple receivers, represented by ERC721 tokens.
     * The streamer allocates a specified amount of the vault's underlying ERC20 asset to each stream, representing the principal amount.
     * This amount is then deposited to the ERC4626 vault to obtain the corresponding shares, which are used to generate yield for the respective receivers.
     * Any unallocated shares are returned to the streamer.
     * @dev When new streams are opened, ERC721 tokens are minted to represent each stream, uniquely identifying them.
     * These tokens represent the ownership of the yield streams (and principal allocated to them) and can be held, transferred, or utilized in other contracts.
     * If a receiver is in debt (where the total value of their streams is less than the allocated principal),
     * the function assesses if the new shares would incur an immediate loss exceeding the streamer's specified tolerance.
     * Emits an Open event for each successful stream creation.
     *
     * @param _principal The total principal amount in asset units to be allocated to new yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver.
     * @param _maxLossOnOpenTolerance The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * This parameter is crucial if the receiver is in debt, affecting the feasibility of opening the stream.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     */
    function depositAndOpenMultiple(
        uint256 _principal,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) public returns (uint256[] memory streamIds) {
        _principal.checkIsZero();

        uint256 shares = _depositToVault(_principal);
        uint256 totalSharesAllocated;
        (totalSharesAllocated, streamIds) =
            _openStreams(shares, _principal, _receivers, _allocations, _maxLossOnOpenTolerance);

        // let this revert on underflow
        _vaultTransferTo(msg.sender, shares - totalSharesAllocated);
    }

    /**
     * @notice Opens multiple yield streams between the caller (streamer) and multiple receivers using ERC20 permit for setting the allowance.
     * Any unallocated shares are returned to the streamer.
     * @dev This function allows opening of multiple yield streams without requiring separate approval transactions, by utilizing the "permit" functionality.
     * The function mints new ERC721 tokens to represent the yield streams, assigning ownership to the streamer.
     * Emits an Open event for each successful stream creation.
     *
     * @param _principal The total principal amount in asset units to be allocated to new yield streams.
     * @param _receivers The addresses of the receivers for the yield streams.
     * @param _allocations The percentage of shares to allocate to each receiver.
     * @param _maxLossOnOpenTolerance The maximum loss percentage tolerated by the sender.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return streamIds The unique identifiers for the newly opened yield streams, represented by ERC721 tokens.
     */
    function depositAndOpenMultipleUsingPermit(
        uint256 _principal,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[] memory streamIds) {
        IERC20Permit(address(asset)).permit(msg.sender, address(this), _principal, deadline, v, r, s);

        streamIds = depositAndOpenMultiple(_principal, _receivers, _allocations, _maxLossOnOpenTolerance);
    }

    /**
     * @notice Adds additional shares to an existing yield stream, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     * Emits a TopUp event upon successful addition of shares to the stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _shares The number of additional shares to be added to the yield stream.
     * @return principal The added principal amount in asset units.
     */
    function topUp(uint256 _streamId, uint256 _shares) public returns (uint256 principal) {
        _shares.checkIsZero();
        _checkApprovedOrOwner(_streamId);

        principal = vault.convertToAssets(_shares);

        _topUpStream(_streamId, _shares, principal);

        _vaultTransferFrom(msg.sender, _shares);
    }

    /**
     * @notice Adds additional shares to an existing yield stream, increasing the principal allocated to the receiver using ERC20 permit for token allowance.
     * @dev It uses the ERC20 permit function to approve the token transfer and top-up the yield stream in a single transaction.
     * The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     * Emits a TopUp event upon successful addition of shares to the stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _shares The number of additional shares to be added to the yield stream.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return principal The added principal amount in asset units.
     */
    function topUpUsingPermit(uint256 _streamId, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 principal)
    {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        principal = topUp(_streamId, _shares);
    }

    /**
     * @notice Adds additional principal to an existing yield stream, increasing the principal allocated to the receiver.
     * @dev The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     * Emits a TopUp event upon successful addition of shares to the stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _principal The additional principal amount in asset units to be added to the yield stream.
     * @return shares The added number of shares to the yield stream.
     */
    function depositAndTopUp(uint256 _streamId, uint256 _principal) public returns (uint256 shares) {
        _principal.checkIsZero();
        _checkApprovedOrOwner(_streamId);

        shares = _depositToVault(_principal);

        _topUpStream(_streamId, shares, _principal);
    }

    /**
     * @notice Adds additional principal to an existing yield stream, increasing the principal allocated to the receiver using ERC20 permit for token allowance.
     * @dev It uses the ERC20 permit function to approve the token transfer and top-up the yield stream in a single transaction.
     * The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     * Emits a TopUp event upon successful addition of shares to the stream.
     *
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param _principal The additional principal amount in asset units to be added to the yield stream.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return shares The added number of shares to the yield stream.
     */
    function depositAndTopUpUsingPermit(
        uint256 _streamId,
        uint256 _principal,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        IERC20Permit(address(vault.asset())).permit(msg.sender, address(this), _principal, deadline, v, r, s);

        shares = depositAndTopUp(_streamId, _principal);
    }

    /**
     * @notice Closes an existing yield stream identified by the ERC721 token, returning the remaining shares to the streamer. Any outstanding yield is not automatically claimed.
     * @dev This function allows the streamer to terminate an existing yield stream.
     * Upon closure, the function calculates and returns the remaining shares to the streamer,
     * after which the ERC721 token representing the yield stream is burned to ensure it cannot be reused or transferred.
     * This action effectively removes the stream from the contract's tracking, settling any allocated principal and shares back to the streamer.
     * Emits a Close event upon successful stream closure.
     *
     * @param _streamId The unique identifier of the yield stream to be closed, represented by an ERC721 token. This token must be owned by the caller.
     * @return shares The number of shares returned to the streamer upon closing the yield stream.
     * This represents the balance of shares not attributed to generated yield, effectively the remaining principal.
     */
    function close(uint256 _streamId) external returns (uint256 shares) {
        _checkApprovedOrOwner(_streamId);

        address receiver = streamIdToReceiver[_streamId];

        uint256 principal;
        (shares, principal) = _previewClose(_streamId, receiver);

        _burn(_streamId);

        // update state and transfer shares
        delete streamIdToReceiver[_streamId];
        delete receiverPrincipal[receiver][_streamId];
        
        // possible to underflow because of rounding errors
        receiverTotalPrincipal[receiver] -= principal;
        receiverTotalShares[receiver] -= shares;

        emit StreamClosed(_streamId, msg.sender, receiver, shares, principal);

        _vaultTransferTo(msg.sender, shares);
    }

    /**
     * @notice Provides a preview of the shares that would be returned upon closing a yield stream identified by an ERC721 token.
     * @dev This function calculates and returns the number of shares that would be credited back to the streamer upon closing the stream.
     *
     * @param _streamId The unique identifier associated with an active yield stream.
     * @return shares The estimated number of shares that would be returned to the streamer representing the principal in share terms.
     */
    function previewClose(uint256 _streamId) public view returns (uint256 shares) {
        (shares,) = _previewClose(_streamId, streamIdToReceiver[_streamId]);
    }

    /**
     * @notice Claims the generated yield from all streams for the caller and transfers it to a specified address.
     * @dev This function calculates the total yield generated for the caller across all yield streams where they are the designated receiver.
     * This function redeems the shares representing the generated yield, converting them into the underlying asset and transferring the resultant assets to a specified address.
     * Note that this function operates on all yield streams associated with the caller, aggregating the total yield available.
     * Reverts if the total yield is zero or the receiver is currently in debt (i.e., the value of their allocated shares is less than the principal).
     * Emits a ClaimYield event upon successful yield claim.
     *
     * @param _sendTo The address where the claimed yield should be sent. This can be the caller's address or another specified recipient.
     * @return assets The total amount of assets claimed as realized yield from all streams.
     */
    function claimYield(address _sendTo) external returns (uint256 assets) {
        _sendTo.checkIsZero();

        uint256 yieldInShares = previewClaimYieldInShares(msg.sender);

        if (yieldInShares == 0) revert NoYieldToClaim();

        unchecked {
            // impossible to underflow because total shares are always > yield
            receiverTotalShares[msg.sender] -= yieldInShares;
        }

        assets = vault.redeem(yieldInShares, _sendTo, address(this));

        emit YieldClaimed(msg.sender, _sendTo, assets, 0);
    }

    /**
     * @notice Provides an estimation of the yield available to be claimed by the specified receiver.
     * @dev Calculates the total yield that can be claimed by the receiver across all their yield streams.
     * The yield is determined by the difference between the current value of the shares allocated to the receiver and their total principal.
     *
     * @param _receiver The address of the receiver for whom the yield preview is being requested.
     * @return yield The estimated amount of yield available to be claimed by the receiver, expressed in the underlying asset units.
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
     * @notice Claims the generated yield from all streams for the caller and transfers it in shares to a specified address.
     * @dev This function enables receivers to claim the yield generated across all their yield streams in the form of shares, rather than the underlying asset.
     * It calculates the total yield in shares that the caller can claim, then transfers those shares to the specified address.
     * The operation is based on the difference between the current share value allocated to the receiver and the total principal in share terms.
     * Emits a ClaimYieldInShares event upon successful yield claim.
     *
     * Unlike `claimYield`, which redeems shares for the underlying asset and transfers the assets, `claimYieldInShares` directly transfers the shares,
     * keeping the yield within the same asset class. This might be preferable for receivers looking to maintain their position in the underlying vault.
     *
     * @param _sendTo The address where the claimed yield shares should be sent. This can be the caller's address or another specified recipient.
     * @return yieldInShares The total number of shares claimed as yield and transferred to the `_sendTo` address.
     */
    function claimYieldInShares(address _sendTo) external returns (uint256 yieldInShares) {
        _sendTo.checkIsZero();

        yieldInShares = previewClaimYieldInShares(msg.sender);

        if (yieldInShares == 0) revert NoYieldToClaim();

        unchecked {
            // impossible to underflow because total shares are always > yield
            receiverTotalShares[msg.sender] -= yieldInShares;
        }

        emit YieldClaimed(msg.sender, _sendTo, 0, yieldInShares);

        _vaultTransferTo(_sendTo, yieldInShares);
    }

    /**
     * @notice Provides an estimation of the yield available to be claimed by the specified receiver in share terms.
     * @dev Calculates the total yield that can be claimed by the receiver across all their yield streams.
     * The yield is determined by the difference between the current value of the shares allocated to the receiver and their total principal in share terms.
     *
     * @param _receiver The address of the receiver for whom the yield preview is being requested.
     * @return yieldInShares The estimated amount of yield available to be claimed by the receiver, expressed in shares.
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
     * @notice Calculates the total debt for a given receiver across all yield streams.
     * @dev  The debt is calculated by comparing the current total asset value of the receiver's shares against the total principal.
     * If the asset value exceeds the principal, indicating a positive yield, the function returns zero, as there is no debt.
     * Conversely, if the principal exceeds the asset value, the function returns the difference, quantifying the receiver's debt.
     *
     * @param _receiver The address of the receiver for whom the debt is being calculated.
     * @return debt The total calculated debt for the receiver, expressed in the underlying asset units.
     * If the receiver has no debt or a positive yield, the function returns zero.
     */
    function debtFor(address _receiver) public view returns (uint256) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 shares = receiverTotalShares[_receiver];
        uint256 sharePrice = vault.convertToAssets(shares).divWadUp(shares);

        return _calculateDebt(shares, principal, sharePrice);
    }

    /**
     * @dev Retrieves the principal amount allocated to a specific stream.
     * @param _streamId The token ID of the stream.
     * @return principal The principal amount allocated to the stream, in asset units.
     */
    /**
     * @notice Retrieves the principal amount allocated to a specific yield stream, identified by the ERC721 token ID.
     *
     * @param _streamId The unique identifier of the yield stream for which the principal is being queried, represented by an ERC721 token.
     * @return principal The principal amount in asset units initially allocated to the yield stream identified by the given token ID.
     */
    function getPrincipal(uint256 _streamId) external view returns (uint256) {
        address receiver = streamIdToReceiver[_streamId];

        return _getPrincipal(_streamId, receiver);
    }

    function isOwnerOrApproved(uint256 _streamId) external view returns (bool) {
        return _isApprovedOrOwner(msg.sender, _streamId);
    }

    /* 
    * =======================================================
    *                   INTERNAL FUNCTIONS
    * =======================================================
    */

    // accounting logic for opening a new stream
    function _openStream(address _receiver, uint256 _shares, uint256 _principal) internal returns (uint256 streamId) {
        unchecked {
            // id's are not going to overflow
            streamId = nextStreamId++;

            _mint(msg.sender, streamId);
            streamIdToReceiver[streamId] = _receiver;

            // not realistic to overflow
            receiverTotalShares[_receiver] += _shares;
            receiverTotalPrincipal[_receiver] += _principal;
            receiverPrincipal[_receiver][streamId] = _principal;
        }

        emit StreamOpened(streamId, msg.sender, _receiver, _shares, _principal);
    }

    // accounting logic for opening multiple streams
    function _openStreams(
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
            streamIds[i] = _openStream(receiver, sharesAllocation, principalAllocation);

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

        emit StreamToppedUp(_streamId, msg.sender, _receiver, _shares, _principal);
    }

    function _previewClose(uint256 _streamId, address _receiver)
        internal
        view
        returns (uint256 shares, uint256 principal)
    {
        principal = _getPrincipal(_streamId, _receiver);

        if (principal == 0) return (0, 0);

        // asset amount of equivalent shares
        uint256 ask = vault.convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];

        // calculate the maximum amount of shares that can be attributed to the sender as a percentage of the sender's share of the total principal.
        uint256 have = receiverTotalShares[_receiver].mulDiv(principal, totalPrincipal);

        // true if there was a loss (negative yield)
        shares = ask > have ? have : ask;
    }

    function _depositToVault(uint256 _amount) internal returns (uint256 shares) {
        address(asset).safeTransferFrom(msg.sender, address(this), _amount);

        shares = vault.deposit(_amount, address(this));
    }

    function _getPrincipal(uint256 _streamId, address _receiver) internal view returns (uint256) {
        return receiverPrincipal[_receiver][_streamId];
    }

    function _canOpenStream(address _receiver, uint256 _shares, uint256 _principal, uint256 _maxLossOnOpenTolerance)
        internal
        view
    {
        _receiver.checkIsZero();
        _principal.checkIsZero();

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
        if (_receivers.length != _allocations.length) {
            revert InputArraysLengthMismatch(_receivers.length, _allocations.length);
        }
    }

    function _checkApprovedOrOwner(uint256 _positionId) internal view {
        if (!_isApprovedOrOwner(msg.sender, _positionId)) revert ERC721.NotOwnerNorApproved();
    }

    function _vaultTransferFrom(address _from, uint256 _shares) internal {
        address(vault).safeTransferFrom(_from, address(this), _shares);
    }

    function _vaultTransferTo(address _to, uint256 _shares) internal {
        address(vault).safeTransfer(_to, _shares);
    }
}
