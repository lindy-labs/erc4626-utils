// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {AddressZero, AmountZero, CannotOpenStreamToSelf} from "./common/Errors.sol";

/**
 * @title YieldStreaming
 * @dev Manages yield streams between senders and receivers using ERC4626 tokens and incorporates ERC721 for stream identification and management.
 * Each yield stream is uniquely identified by an ERC721 token, allowing for transparent tracking and management of individual streams.
 * This approach enables users to create, top-up, transfer, and close yield streams as well as facilitating the flow of yield from appreciating assets to designated beneficiaries.
 * It leverages the ERC4626 standard for tokenized vault interactions, assuming that these tokens appreciate over time, generating yield for their holders.
 */
contract YieldStreaming is ERC721, Multicall {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;

    error NoYieldToClaim();
    error LossToleranceExceeded();
    error CallerNotOwner();

    event Open(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event TopUp(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event Close(
        uint256 indexed streamId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );

    /// @dev underlying ERC4646 vault
    IERC4626 public vault;

    /// @dev identifier for the next stream opened (ERC721 token ID)
    uint256 public nextStreamId = 1;

    /// @dev receiver addresses to the number of shares they are entitled to as yield beneficiaries
    mapping(address => uint256) public receiverShares;

    /// @dev receiver addresses to the total principal amount allocated, not claimable as yield
    mapping(address => uint256) public receiverTotalPrincipal;

    /// @dev receiver addresses to the principal amount allocated from a specific stream
    mapping(address => mapping(uint256 => uint256)) public receiverPrincipal;

    /// @dev token id to receiver
    mapping(uint256 => address) public streamIdToReceiver;

    constructor(IERC4626 _vault)
        ERC721(string.concat("Yield Streaming - ", _vault.name()), string.concat("YST-", _vault.symbol()))
    {
        _checkZeroAddress(address(_vault));

        vault = _vault;
    }

    /**
     * @notice Opens a new yield stream between the caller (streamer) and a receiver, represented by an ERC721 token.
     * @dev When a new stream is opened, an ERC721 token is minted to the streamer, uniquely identifying the stream.
     * This token represents the ownership of the yield stream and can be held, transferred, or utilized in other contracts.
     * The function calculates the principal amount based on the shares provided, updating the total principal allocated to the receiver.
     * If the receiver is in debt (where the total value of their streams is less than the allocated principal),
     * the function assesses if the new shares would incur an immediate loss exceeding the streamer's specified tolerance.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of shares to allocate to the new yield stream. Shares represent a portion of the underlying ERC4626 vault tokens.
     * @param _maxLossOnOpenTolerancePercent The maximum percentage of loss on the principal that the streamer is willing to tolerate upon opening the stream.
     * This parameter is crucial if the receiver is in debt, affecting the feasibility of opening the stream.
     * @return streamId The unique identifier for the newly opened yield stream, represented by an ERC721 token.
     * This token encapsulates the stream's details and ownership, enabling further interactions and management.
     */
    function open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent)
        public
        returns (uint256 streamId)
    {
        uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerancePercent);

        streamId = nextStreamId++;

        _mint(msg.sender, streamId);
        streamIdToReceiver[streamId] = _receiver;

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][streamId] += principal;

        emit Open(streamId, msg.sender, _receiver, _shares, principal);

        vault.safeTransferFrom(msg.sender, address(this), _shares);
    }

    /**
     * @notice Provides a preview of the principal amount for opening yield stream and reverts if the operation would fail.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares involved in the operation.
     * @param _maxLossOnOpenTolerancePercent The maximum loss percentage tolerated by the sender.
     * @return principal The principal amount in asset units that would be allocated for the shares.
     */
    function previewOpen(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent)
        public
        view
        returns (uint256 principal)
    {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkZeroAmount(_shares);

        principal = _convertToAssets(_shares);

        _checkImmediateLossOnOpen(_receiver, principal, _maxLossOnOpenTolerancePercent);
    }

    /**
     * @notice Opens a new yield stream with ERC4626 vault shares for a specified receiver using ERC20 permit for token allowance.
     * @dev This function allows the opening of a new yield stream without requiring a separate transaction for token allowance, using the ERC20 permit function.
     * It enables a seamless user experience by allowing token approval and yield stream creation in a single transaction.
     * The function mints a new ERC721 token to represent the yield stream, assigning ownership to the streamer.
     *
     * @param _receiver The address of the receiver for the yield stream.
     * @param _shares The number of ERC4626 vault shares to allocate to the new yield stream. These shares are transferred from the streamer to the contract as part of the stream setup.
     * @param _maxLossOnOpenTolerancePercent The maximum loss percentage that the streamer is willing to tolerate upon opening the yield stream.
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
        uint256 _maxLossOnOpenTolerancePercent,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 streamId) {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        streamId = open(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    /**
     * @notice Adds additional shares to an existing yield stream, increasing the principal allocated to the receiver.
     * @dev This function allows a streamer to add more shares to a yield stream represented by a specific ERC721 token.
     * The additional shares increase the principal amount allocated to the receiver, potentially altering the yield generation rate of the stream.
     * The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     *
     * @param _shares The number of additional shares to be added to the yield stream.
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @return principal The added principal amount in asset units.
     */
    function topUp(uint256 _shares, uint256 _streamId) public returns (uint256 principal) {
        _checkZeroAmount(_shares);
        _checkIsOwner(_streamId);

        address _receiver = streamIdToReceiver[_streamId];

        principal = _convertToAssets(_shares);

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][_streamId] += principal;

        emit TopUp(_streamId, msg.sender, _receiver, _shares, principal);

        vault.safeTransferFrom(msg.sender, address(this), _shares);
    }

    /**
     * @notice Adds additional shares to an existing yield stream, increasing the principal allocated to the receiver using ERC20 permit for token allowance.
     * @dev This function allows the streamer to add more shares to an existing yield stream without requiring a separate transaction for token allowance.
     * It uses the ERC20 permit function to approve the token transfer and top-up the yield stream in a single transaction.
     * The function requires that the caller is the owner of the ERC721 token associated with the yield stream.
     *
     * @param _shares The number of additional shares to be added to the yield stream.
     * @param _streamId The unique identifier of the yield stream (ERC721 token) to be topped up.
     * @param deadline The timestamp by which the permit must be used, ensuring the permit does not remain valid indefinitely.
     * @param v The recovery byte of the signature, a part of the permit approval process.
     * @param r The first 32 bytes of the signature, another component of the permit.
     * @param s The second 32 bytes of the signature, completing the permit approval requirements.
     * @return principal The added principal amount in asset units.
     */
    function topUpUsingPermit(uint256 _shares, uint256 _streamId, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 principal)
    {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        principal = topUp(_shares, _streamId);
    }

    /**
     * @notice Closes an existing yield stream identified by the ERC721 token, returning the remaining shares to the streamer. Any outstanding yield is not automatically claimed.
     * @dev This function allows the streamer to terminate an existing yield stream.
     * Upon closure, the function calculates and returns the remaining shares to the streamer,
     * after which the ERC721 token representing the yield stream is burned to ensure it cannot be reused or transferred.
     * This action effectively removes the stream from the contract's tracking, settling any allocated principal and shares back to the streamer.
     *
     * @param _streamId The unique identifier of the yield stream to be closed, represented by an ERC721 token. This token must be owned by the caller.
     * @return shares The number of shares returned to the streamer upon closing the yield stream.
     * This represents the balance of shares not attributed to generated yield, effectively the remaining principal.
     */
    function close(uint256 _streamId) external returns (uint256 shares) {
        _checkIsOwner(_streamId);

        address receiver = streamIdToReceiver[_streamId];

        uint256 principal;
        (shares, principal) = _previewClose(receiver, _streamId);

        _burn(_streamId);

        // update state and transfer shares
        delete streamIdToReceiver[_streamId];
        delete receiverPrincipal[receiver][_streamId];
        receiverTotalPrincipal[receiver] -= principal;
        receiverShares[receiver] -= shares;

        emit Close(_streamId, msg.sender, receiver, shares, principal);

        vault.safeTransfer(msg.sender, shares);
    }

    /**
     * @notice Provides a preview of the shares that would be returned upon closing a yield stream identified by an ERC721 token.
     * @dev This function calculates and returns the number of shares that would be credited back to the streamer upon closing the stream.
     *
     * @param _streamId The unique identifier associated with an active yield stream.
     * @return shares The estimated number of shares that would be returned to the streamer representing the principal in share terms.
     */
    function previewClose(uint256 _streamId) public view returns (uint256 shares) {
        (shares,) = _previewClose(streamIdToReceiver[_streamId], _streamId);
    }

    function _previewClose(address _receiver, uint256 _streamId)
        internal
        view
        returns (uint256 shares, uint256 principal)
    {
        principal = _getPrincipal(_receiver, _streamId);

        if (principal == 0) return (0, 0);

        // asset amount of equivalent shares
        uint256 ask = _convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];

        // calculate the maximum amount of shares that can be attributed to the sender as a percentage of the sender's share of the total principal.
        uint256 have = receiverShares[_receiver].mulDivDown(principal, totalPrincipal);

        // true if there was a loss (negative yield)
        shares = ask > have ? have : ask;
    }

    /**
     * @notice Claims the generated yield from all streams for the caller and transfers it to a specified address.
     * @dev This function calculates the total yield generated for the caller across all yield streams where they are the designated receiver.
     * This function redeems the shares representing the generated yield, converting them into the underlying asset and transferring the resultant assets to a specified address.
     * Note that this function operates on all yield streams associated with the caller, aggregating the total yield available.
     * Reverts if the total yield is zero or the receiver is currently in debt (i.e., the value of their allocated shares is less than the principal).
     *
     * @param _sendTo The address where the claimed yield should be sent. This can be the caller's address or another specified recipient.
     * @return assets The total amount of assets claimed as yield realized from all streams.
     */
    function claimYield(address _sendTo) external returns (uint256 assets) {
        _checkZeroAddress(_sendTo);

        uint256 yieldInShares = previewClaimYieldInShares(msg.sender);

        if (yieldInShares == 0) revert NoYieldToClaim();

        receiverShares[msg.sender] -= yieldInShares;

        assets = vault.redeem(yieldInShares, _sendTo, address(this));

        emit ClaimYield(msg.sender, _sendTo, yieldInShares, assets);
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
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        // if vault made a loss, there is no yield
        yield = currentValue > principal ? currentValue - principal : 0;
    }

    /**
     * @notice Claims the generated yield from all streams for the caller and transfers it in shares to a specified address.
     * @dev This function enables receivers to claim the yield generated across all their yield streams in the form of shares, rather than the underlying asset.
     * It calculates the total yield in shares that the caller can claim, then transfers those shares to the specified address.
     * The operation is based on the difference between the current share value allocated to the receiver and the total principal in share terms.
     *
     * Unlike `claimYield`, which redeems shares for the underlying asset and transfers the assets, `claimYieldInShares` directly transfers the shares,
     * keeping the yield within the same asset class. This might be preferable for receivers looking to maintain their position in the underlying vault.
     *
     * @param _sendTo The address where the claimed yield shares should be sent. This can be the caller's address or another specified recipient.
     * @return shares The total number of shares claimed as yield and transferred to the `_sendTo` address.
     */
    function claimYieldInShares(address _sendTo) external returns (uint256 shares) {
        _checkZeroAddress(_sendTo);

        shares = previewClaimYieldInShares(msg.sender);

        if (shares == 0) revert NoYieldToClaim();

        receiverShares[msg.sender] -= shares;

        emit ClaimYieldInShares(msg.sender, _sendTo, shares);

        vault.safeTransfer(_sendTo, shares);
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
        uint256 principalInShares = _convertToShares(receiverTotalPrincipal[_receiver]);
        uint256 shares = receiverShares[_receiver];

        // if vault made a loss, there is no yield
        yieldInShares = shares > principalInShares ? shares - principalInShares : 0;
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
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        return currentValue < principal ? principal - currentValue : 0;
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

        return _getPrincipal(receiver, _streamId);
    }

    function _getPrincipal(address _receiver, uint256 _streamId) internal view returns (uint256) {
        return receiverPrincipal[_receiver][_streamId];
    }

    function _checkImmediateLossOnOpen(address _receiver, uint256 _principal, uint256 _lossTolerancePercent)
        internal
        view
    {
        // when opening a new stream from sender, check if the receiver is in debt
        uint256 debt = debtFor(_receiver);

        if (debt == 0) return;

        // if the receiver is in debt, check if the sender is willing to take the immediate loss when opening a new stream.
        // the immediate loss is calculated as the percentage of the debt that the sender is taking as his share of the total principal allocated to the receiver.
        // acceptable loss is defined by the loss tolerance percentage param passed to the open function.
        // this loss occurs due to inability of the accounting logic to differentiate between principal amounts allocated from different streams to same receiver.
        uint256 lossOnOpen = debt.mulDivUp(_principal, receiverTotalPrincipal[_receiver] + _principal);

        if (lossOnOpen > _principal.mulWadUp(_lossTolerancePercent)) revert LossToleranceExceeded();
    }

    function _checkZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert AddressZero();
    }

    function _checkZeroAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }

    function _checkIsOwner(uint256 _streamId) internal view {
        if (ownerOf(_streamId) != msg.sender) revert CallerNotOwner();
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return vault.convertToAssets(_shares);
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        return vault.convertToShares(_assets);
    }
}
