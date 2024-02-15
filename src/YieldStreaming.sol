// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {StreamDoesNotExist} from "./common/Errors.sol";
import {StreamingBase} from "./common/StreamingBase.sol";

/**
 * @title YieldStreaming
 * @dev Manages yield streams between senders and receivers using ERC4626 tokens.
 * This contract enables users to create, top-up, and close yield streams,
 * facilitating the flow of yield from appreciating assets to designated beneficiaries.
 * It assumes ERC4626 tokens (vault tokens) appreciate over time, generating yield for their holders.
 */
contract YieldStreaming is StreamingBase {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;
    using SafeERC20 for IERC20;

    error NoYieldToClaim();
    error LossToleranceExceeded();

    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event ClaimYieldInShares(address indexed receiver, address indexed claimedTo, uint256 yieldInShares);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);

    // receiver addresses to the number of shares they are entitled to as yield beneficiaries
    mapping(address => uint256) public receiverShares;

    // receiver addresses to the total principal amount allocated, not claimable as yield
    mapping(address => uint256) public receiverTotalPrincipal;

    // receiver addresses to the principal amount allocated from a specific address
    mapping(address => mapping(address => uint256)) public receiverPrincipal;

    constructor(IERC4626 _vault) {
        _checkZeroAddress(address(_vault));

        token = address(_vault);
        IERC20(IERC4626(token).asset()).approve(address(_vault), type(uint256).max);
    }

    /**
     * @dev Opens or tops up a yield stream for a specific receiver with a given number of shares.
     * If the receiver is currently in debt, the sender incurs an immediate loss proportional to the debt.
     * The debt is calculated as the difference between the current value of the receiver's streams and their total allocated principal.
     * This loss is recovered over time as the yield is generated by the receiver's streams thus restoring the sender's principal.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     * @param _maxLossOnOpenTolerancePercent Maximum tolerated loss percentage for opening the stream.
     * @return principal The amount of assets (tokens) allocated to the stream.
     */
    function openYieldStream(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent)
        public
        returns (uint256 principal)
    {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkAmount(_shares);

        principal = _convertToAssets(_shares);

        _openYieldStream(_receiver, _shares, principal, _maxLossOnOpenTolerancePercent);

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
     * @return principal The amount of assets (tokens) allocated to the stream.
     */
    function openYieldStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerancePercent,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 principal) {
        IERC2612(address(token)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        principal = openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    /**
     * @dev Deposits assets (principal) into the underlying vault and opens or tops up a yield stream for a specific receiver.
     * @param _receiver The address of the receiver.
     * @param _amount The amount of assets (principal) to deposit and allocate to the yield stream.
     * @param _maxLossOnOpenTolerancePercent The maximum loss tolerance percentage when opening a stream to a receiver which is in debt.
     */
    function depositAndOpenYieldStream(address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent)
        public
        returns (uint256 shares)
    {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkAmount(_amount);

        IERC20 underlying = IERC20(IERC4626(token).asset());

        underlying.safeTransferFrom(msg.sender, address(this), _amount);

        shares = IERC4626(token).deposit(_amount, address(this));

        _openYieldStream(_receiver, shares, _amount, _maxLossOnOpenTolerancePercent);
    }

    /**
     * @dev Deposits assets (principal) into the underlying vault and opens or tops up a yield stream for a specific receiver using the ERC20 permit functionality to obtain the necessary allowance..
     * @param _receiver The address of the receiver.
     * @param _amount The amount of assets (principal) to deposit and allocate to the yield stream.
     * @param _maxLossOnOpenTolerancePercent The maximum loss tolerance percentage when opening a stream to a receiver which is in debt.
     * @param deadline The deadline timestamp for the permit signature.
     * @param v The recovery byte of the permit signature.
     * @param r The first 32 bytes of the permit signature.
     * @param s The second 32 bytes of the permit signature.
     * @return shares The amount of underlying vault shares allocated to the stream.
     */
    function depositAndOpenYieldStreamUsingPermit(
        address _receiver,
        uint256 _amount,
        uint256 _maxLossOnOpenTolerancePercent,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        IERC2612(address(IERC4626(token).asset())).permit(msg.sender, address(this), _amount, deadline, v, r, s);

        shares = depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    function _openYieldStream(
        address _receiver,
        uint256 _shares,
        uint256 _principal,
        uint256 _maxLossOnOpenTolerancePercent
    ) internal {
        _checkImmediateLossOnOpen(_receiver, msg.sender, _principal, _maxLossOnOpenTolerancePercent);

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += _principal;
        receiverPrincipal[_receiver][msg.sender] += _principal;

        emit OpenYieldStream(msg.sender, _receiver, _shares, _principal);
    }

    /**
     * @dev Closes a yield stream for a specific receiver, recovering remaining shares allocated to them.
     * This action does not automatically claim any generated yield; it must be claimed by the receiver separately via `claimYield` or `claimYieldInShares`.
     * @param _receiver The address of the receiver.
     * @return shares The number of shares recovered by closing the stream.
     */
    function closeYieldStream(address _receiver) public returns (uint256 shares) {
        uint256 principal;
        (shares, principal) = _closeYieldStream(_receiver);

        IERC20(token).safeTransfer(msg.sender, shares);
    }

    /**
     * @dev Closes a yield stream for a specific receiver and withdraws the principal amount.
     * @param _receiver The address of the receiver.
     * @return principal The amount of assets (tokens) recovered by closing the stream.
     */
    function closeYieldStreamAndWithdraw(address _receiver) external returns (uint256 principal) {
        uint256 shares;
        (shares, principal) = _closeYieldStream(_receiver);

        return IERC4626(token).redeem(shares, msg.sender, address(this));
    }

    function _closeYieldStream(address _receiver) internal returns (uint256 shares, uint256 principal) {
        (shares, principal) = previewCloseYieldStream(_receiver, msg.sender);

        if (principal == 0) revert StreamDoesNotExist();

        // update state and transfer
        receiverPrincipal[_receiver][msg.sender] = 0;
        receiverTotalPrincipal[_receiver] -= principal;
        receiverShares[_receiver] -= shares;

        emit CloseYieldStream(msg.sender, _receiver, shares, principal);
    }

    /**
     * @dev Provides a preview of the amount of shares that would be recovered by closing a yield stream for a specific receiver.
     * @param _receiver The address of the receiver.
     * @param _streamer The address of the streamer attempting to close the yield stream.
     * @return shares The number of shares that would be recovered by closing the stream.
     * @return principal The amount of assets that would be recovered by closing the stream.
     */
    function previewCloseYieldStream(address _receiver, address _streamer)
        public
        view
        returns (uint256 shares, uint256 principal)
    {
        principal = receiverPrincipal[_receiver][_streamer];

        if (principal == 0) return (0, 0);

        // asset amount of equivalent shares
        uint256 ask = _convertToShares(principal);
        uint256 totalPrincipal = receiverTotalPrincipal[_receiver];
        // the maximum amount of shares that can be attributed to the sender
        uint256 have = receiverShares[_receiver].mulDivDown(principal, totalPrincipal);

        // if there was a loss, return amount of shares as the percentage of the
        // equivalent to the sender share of the total principal
        if (ask > have) {
            shares = have;
            principal = principal.mulDivDown(shares, ask);
        } else {
            shares = ask;
        }
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

    function _checkImmediateLossOnOpen(
        address _receiver,
        address _streamer,
        uint256 _principal,
        uint256 _lossTolerancePercent
    ) internal view {
        // check wheather the streamer already has an existing stream/s open for receiver
        // if it does then we are considering this as a top up to an existing stream and ignore if there is a loss
        if (receiverPrincipal[_receiver][_streamer] != 0) return;

        // when opening a new stream from sender, check if the receiver is in debt
        uint256 debt = debtFor(_receiver);

        if (debt == 0) return;

        // if the receiver is in debt, check if the sender is willing to take the immediate loss when opening a new stream
        // the immediate loss is calculated as the percentage of the debt that the sender is taking as his share of the total principal allocated to the receiver
        // acceptable loss is defined by the loss tolerance percentage configured for the contract
        uint256 lossOnOpen = debt.mulDivUp(_principal, receiverTotalPrincipal[_receiver] + _principal);

        if (lossOnOpen > _principal.mulWadUp(_lossTolerancePercent)) revert LossToleranceExceeded();
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return IERC4626(token).convertToAssets(_shares);
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        return IERC4626(token).convertToShares(_assets);
    }
}
