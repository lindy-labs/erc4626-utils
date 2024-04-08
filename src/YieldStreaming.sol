// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {StreamingBase} from "./common/StreamingBase.sol";

// TODO: update docs
/**
 * @title YieldStreaming
 * @dev Manages yield streams between senders and receivers using the underlying ERC4626 tokens.
 * This contract enables users to create, top-up, and close yield streams,
 * facilitating the flow of yield from appreciating assets to designated beneficiaries.
 * It assumes ERC4626 tokens (vault tokens) appreciate over time, generating yield for their holders.
 */
contract YieldStreaming is StreamingBase, ERC721 {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;
    using SafeERC20 for IERC20;

    error NoYieldToClaim();
    error LossToleranceExceeded();
    error CallerNotOwner();

    event OpenYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event TopUpYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event CloseYieldStream(
        uint256 indexed tokenId, address indexed streamer, address indexed receiver, uint256 shares, uint256 principal
    );

    /// @dev identifier for the next token to be minted
    uint256 public nextTokenId = 1;

    /// @dev receiver addresses to the number of shares they are entitled to as yield beneficiaries
    mapping(address => uint256) public receiverShares;

    /// @dev receiver addresses to the total principal amount allocated, not claimable as yield
    mapping(address => uint256) public receiverTotalPrincipal;

    /// @dev receiver addresses to the principal amount allocated from a specific stream
    mapping(address => mapping(uint256 => uint256)) public receiverPrincipal;

    /// @dev token id to receiver
    mapping(uint256 => address) public tokenIdToReceiver;

    constructor(IERC4626 _vault)
        ERC721(string.concat("Yield Streaming - ", _vault.name()), string.concat("YST-", _vault.symbol()))
    {
        _checkZeroAddress(address(_vault));

        token = address(_vault);
    }

    /**
     * @dev Opens or tops up a yield stream for a specific receiver with a given number of shares.
     * If the receiver is currently in debt, the sender incurs an immediate loss proportional to the debt.
     * The debt is calculated as the difference between the current value of the receiver's streams and their total allocated principal.
     * This loss is recovered over time as the yield is generated by the receiver's streams thus restoring the sender's principal.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     * @param _maxLossOnOpenTolerancePercent Maximum tolerated loss percentage for opening the stream.
     */
    function openYieldStream(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent)
        public
        returns (uint256 tokenId)
    {
        uint256 principal = previewOpenYieldStream(msg.sender, _receiver, _shares, _maxLossOnOpenTolerancePercent);

        tokenId = nextTokenId++;

        _mint(msg.sender, tokenId);
        tokenIdToReceiver[tokenId] = _receiver;

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][tokenId] += principal;

        emit OpenYieldStream(tokenId, msg.sender, _receiver, _shares, principal);

        IERC20(token).safeTransferFrom(msg.sender, address(this), _shares);
    }

    // TODO: add comments
    function previewOpenYieldStream(
        address _streamer,
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerancePercent
    ) public view returns (uint256 principal) {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkBalance(_streamer, _shares);

        principal = _convertToAssets(_shares);

        _checkImmediateLossOnOpen(_receiver, principal, _maxLossOnOpenTolerancePercent);
    }

    // TODO: add comments
    function topUpYieldStream(uint256 _shares, uint256 _tokenId) public returns (uint256 principal) {
        _checkBalance(msg.sender, _shares);
        _checkIsOwner(_tokenId);

        address _receiver = tokenIdToReceiver[_tokenId];

        principal = _convertToAssets(_shares);

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][_tokenId] += principal;

        emit TopUpYieldStream(_tokenId, msg.sender, _receiver, _shares, principal);

        IERC20(token).safeTransferFrom(msg.sender, address(this), _shares);
    }

    /**
     * @dev Opens or tops up a yield stream for a specific receiver with a given number of shares using the ERC20 permit functionality to obtain the necessary allowance.
     * If the receiver is currently in debt, the sender incurs an immediate loss proportional to the debt.
     * The debt is calculated as the difference between the current value of the receiver's streams and their total allocated principal.
     * This loss is recovered over time as the yield is generated by the receiver's streams thus restoring the sender's principal.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     * @param _maxLossOnOpenTolerancePercent The maximum loss tolerance percentage when opening a stream to a receiver which is in debt.
     * @param deadline The deadline timestamp for the permit signature.
     * @param v The recovery byte of the permit signature.
     * @param r The first 32 bytes of the permit signature.
     * @param s The second 32 bytes of the permit signature.
     */
    function openYieldStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerancePercent,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (uint256 tokenId) {
        IERC2612(address(token)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        tokenId = openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    /**
     * @dev Closes a yield stream for a specific receiver, recovering remaining shares allocated to them.
     * This action does not automatically claim any generated yield; it must be claimed by the receiver separately via `claimYield` or `claimYieldInShares`.
     * @return shares The number of shares recovered by closing the stream.
     */
    function closeYieldStream(uint256 _tokenId) public returns (uint256 shares) {
        _checkIsOwner(_tokenId);

        address receiver = tokenIdToReceiver[_tokenId];

        uint256 principal;
        (shares, principal) = _previewCloseYieldStream(receiver, _tokenId);

        _burn(_tokenId);

        // update state and transfer shares
        delete tokenIdToReceiver[_tokenId];
        delete receiverPrincipal[receiver][_tokenId];
        receiverTotalPrincipal[receiver] -= principal;
        receiverShares[receiver] -= shares;

        emit CloseYieldStream(_tokenId, msg.sender, receiver, shares, principal);

        IERC20(token).safeTransfer(msg.sender, shares);
    }

    /**
     * @dev Provides a preview of the amount of shares that would be recovered by closing a yield stream for a specific receiver.
     * @return shares The number of shares that would be recovered by closing the stream.
     */
    function previewCloseYieldStream(uint256 _tokenId) public view returns (uint256 shares) {
        (shares,) = _previewCloseYieldStream(tokenIdToReceiver[_tokenId], _tokenId);
    }

    function _previewCloseYieldStream(address _receiver, uint256 _tokenId)
        internal
        view
        returns (uint256 shares, uint256 principal)
    {
        principal = _getPrincipal(_receiver, _tokenId);

        if (principal == 0) return (0, 0);

        // asset amount of equivalent shares
        uint256 ask = _convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];
        // the maximum amount of shares that can be attributed to the sender
        uint256 have = receiverShares[_receiver].mulDivDown(principal, totalPrincipal);

        // if there was a loss, return amount of shares as the percentage of the
        // equivalent to the sender share of the total principal
        shares = ask > have ? have : ask;
    }

    /**
     * @dev Claims the yield generated from all streams for the caller and transfers it to the specified address.
     * The yield is the difference between the current value of shares and the principal.
     * @param _sendTo The address to receive the claimed yield.
     * @return assets The total amount of assets (tokens) claimed as yield.
     */
    function claimYield(address _sendTo) external returns (uint256 assets) {
        _checkZeroAddress(_sendTo);

        uint256 yieldInShares = previewClaimYieldInShares(msg.sender);

        if (yieldInShares == 0) revert NoYieldToClaim();

        receiverShares[msg.sender] -= yieldInShares;

        assets = IERC4626(token).redeem(yieldInShares, _sendTo, address(this));

        emit ClaimYield(msg.sender, _sendTo, yieldInShares, assets);
    }

    /**
     * @dev Calculates the yield available to be claimed by a given receiver, expressed in the vault's asset units.
     * @param _receiver The address of the receiver for whom to calculate the yield.
     * @return yield The calculated yield available for claim, in assets. Returns 0 if no yield or negative yield (receiver is in debt).
     */
    function previewClaimYield(address _receiver) public view returns (uint256 yield) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        // if vault made a loss, there is no yield
        yield = currentValue > principal ? currentValue - principal : 0;
    }

    /**
     * @dev Claims the yield generated from all streams for the caller and transfers it as shares to the specified address.
     * @param _sendTo The address to receive the claimed yield in shares.
     * @return shares The total number of shares claimed as yield.
     */
    function claimYieldInShares(address _sendTo) external returns (uint256 shares) {
        _checkZeroAddress(_sendTo);

        shares = previewClaimYieldInShares(msg.sender);

        if (shares == 0) revert NoYieldToClaim();

        receiverShares[msg.sender] -= shares;

        emit ClaimYieldInShares(msg.sender, _sendTo, shares);

        IERC20(token).safeTransfer(_sendTo, shares);
    }

    /**
     * @dev Calculates the yield for a given receiver as claimable shares.
     * @param _receiver The address of the receiver for whom to calculate the yield in shares.
     * @return yieldInShares The calculated yield available for claim, in shares. Returns 0 if no yield or negative yield (receiver is in debt).
     */
    function previewClaimYieldInShares(address _receiver) public view returns (uint256 yieldInShares) {
        uint256 principalInShares = _convertToShares(receiverTotalPrincipal[_receiver]);
        uint256 shares = receiverShares[_receiver];

        // if vault made a loss, there is no yield
        yieldInShares = shares > principalInShares ? shares - principalInShares : 0;
    }

    /**
     * @dev Calculates the total debt for a given receiver, where debt is defined as the negative yield across all streams.
     * A receiver is in debt if the total value of their streams is less than the principal allocated to them.
     * @param _receiver The address of the receiver for whom to calculate the debt.
     * @return The total calculated debt, in asset units. Returns 0 if there is no debt or if the yield is not negative.
     */
    function debtFor(address _receiver) public view returns (uint256) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        return currentValue < principal ? principal - currentValue : 0;
    }

    /**
     * @dev Retrieves the principal amount allocated to a specific stream.
     * @param _tokenId The token ID of the stream.
     * @return principal The principal amount allocated to the stream, in asset units.
     */
    function getPrincipal(uint256 _tokenId) public view returns (uint256) {
        address receiver = tokenIdToReceiver[_tokenId];

        return _getPrincipal(receiver, _tokenId);
    }

    function _getPrincipal(address _receiver, uint256 _tokenId) internal view returns (uint256) {
        return receiverPrincipal[_receiver][_tokenId];
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
        // this loss occurs due to inability of the accounting logic to differentiate between pricipal amounts allocated from different streams to same receiver.
        uint256 lossOnOpen = debt.mulDivUp(_principal, receiverTotalPrincipal[_receiver] + _principal);

        if (lossOnOpen > _principal.mulWadUp(_lossTolerancePercent)) revert LossToleranceExceeded();
    }

    function _checkIsOwner(uint256 _tokenId) internal view {
        if (ownerOf(_tokenId) != msg.sender) revert CallerNotOwner();
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return IERC4626(token).convertToAssets(_shares);
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        return IERC4626(token).convertToShares(_assets);
    }
}
