// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./common/Errors.sol";
import {StreamingBase} from "./common/StreamingBase.sol";

/**
 * @title YieldStreaming
 * @notice This contract facilitates the management of yield streams between senders and receivers for ERC4626 tokens.
 * It allows users to open yield streams, claim yield from streams, and close streams to withdraw remaining shares.
 * The contract assumes that ERC4626 tokens are appreciating assets, meaning that the value of a single share increases over time, ie generates yield.
 */
contract YieldStreaming is StreamingBase {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;

    event OpenYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);
    event ClaimYield(address indexed receiver, address indexed claimedTo, uint256 sharesRedeemed, uint256 yield);
    event CloseYieldStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 principal);

    error NoYieldToClaim();
    error LossToleranceExceeded();

    // the maximum loss tolerance percentage when opening a stream to a receiver which is in debt
    // a receiver is in debt if his existing streams have negative yield
    // TODO: should this be configurable?
    uint256 public immutable lossTolerancePercent = 0.01e18; // 1%

    // receiver to number of shares it is entitled to as the yield beneficiary
    mapping(address => uint256) public receiverShares;

    // receiver to total amount of assets (principal) - not claimable
    mapping(address => uint256) public receiverTotalPrincipal;

    // receiver to total amount of assets (principal) allocated from a single address
    mapping(address => mapping(address => uint256)) public receiverPrincipal;

    constructor(IERC4626 _vault) {
        _checkZeroAddress(address(_vault));

        vault = _vault;
    }

    /**
     * @dev Opens a yield stream for a specific receiver with a given number of shares. If stream already exists, it will be topped up.
     * When opening a new stream, the sender is taking an immediate loss if the receiver is in debt. Acceptable loss is defined by the loss tolerance percentage configured for the contract.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     * @return principal The amount of assets (tokens) allocated to the stream.
     */
    function openYieldStream(address _receiver, uint256 _shares) public returns (uint256 principal) {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkShares(msg.sender, _shares);

        principal = _convertToAssets(_shares);

        _checkImmediateLossOnOpen(_receiver, msg.sender, principal);

        receiverShares[_receiver] += _shares;
        receiverTotalPrincipal[_receiver] += principal;
        receiverPrincipal[_receiver][msg.sender] += principal;

        emit OpenYieldStream(msg.sender, _receiver, _shares, principal);

        vault.safeTransferFrom(msg.sender, address(this), _shares);
    }

    /**
     * @dev Opens a yield stream for a specific receiver with a given number of shares using the ERC20 permit functionality to obtain the necessary allowance.
     * When opening a new stream, the sender is taking an immediate loss if the receiver is in debt. Acceptable loss is defined by the loss tolerance percentage configured for the contract.
     * @param _receiver The address of the receiver.
     * @param _shares The number of shares to allocate for the yield stream.
     * @param deadline The deadline timestamp for the permit signature.
     * @param v The recovery byte of the permit signature.
     * @param r The first 32 bytes of the permit signature.
     * @param s The second 32 bytes of the permit signature.
     * @return principal The amount of assets (tokens) allocated to the stream.
     */
    function openYieldStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (uint256 principal) {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, deadline, v, r, s);

        principal = openYieldStream(_receiver, _shares);
    }

    /**
     * @dev Closes a yield stream for a specific receiver.
     * If there is any yield to claim for the stream, it will remain unclaimed until the receiver calls `claimYield` function.
     * @param _receiver The address of the receiver.
     * @return shares The amount of shares that were recovered by closing the stream.
     */
    function closeYieldStream(address _receiver) public returns (uint256 shares) {
        uint256 principal;
        (shares, principal) = _previewCloseYieldStream(_receiver, msg.sender);

        if (principal == 0) revert StreamDoesNotExist();

        // update state and transfer
        receiverPrincipal[_receiver][msg.sender] = 0;
        receiverTotalPrincipal[_receiver] -= principal;
        receiverShares[_receiver] -= shares;

        emit CloseYieldStream(msg.sender, _receiver, shares, principal);

        vault.safeTransfer(msg.sender, shares);
    }

    /**
     * @dev Calculates the amount of shares that would be recovered by closing a yield stream for a specific receiver.
     * @param _receiver The address of the receiver.
     * @return shares The amount of shares that would be recovered by closing the stream.
     */
    function previewCloseYieldStream(address _receiver, address _streamer) public view returns (uint256 shares) {
        (shares,) = _previewCloseYieldStream(_receiver, _streamer);
    }

    function _previewCloseYieldStream(address _receiver, address _streamer)
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
        shares = ask > have ? have : ask;
    }

    /**
     * @dev Claims the yield from all streams for the sender and transfers it to the specified receiver address.
     * @param _to The address to receive the claimed yield.
     * @return assets The amount of assets (tokens) claimed as yield.
     */
    function claimYield(address _to) external returns (uint256 assets) {
        _checkZeroAddress(_to);

        uint256 yieldInSHares = yieldForInShares(msg.sender);

        if (yieldInSHares == 0) revert NoYieldToClaim();

        receiverShares[msg.sender] -= yieldInSHares;

        assets = vault.redeem(yieldInSHares, _to, address(this));

        emit ClaimYield(msg.sender, _to, yieldInSHares, assets);
    }

    /**
     * @dev Calculates the yield for a given receiver.
     * @param _receiver The address of the receiver.
     * @return yield The calculated yield, 0 if there is no yield or yield is negative.
     */
    function yieldFor(address _receiver) public view returns (uint256 yield) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        // if vault made a loss, there is no yield
        yield = currentValue > principal ? currentValue - principal : 0;
    }

    /**
     * @dev Calculates the yield for a given receiver as claimable shares.
     * @param _receiver The address of the receiver.
     * @return yieldInShares The calculated yield in shares, 0 if there is no yield or yield is negative.
     */
    function yieldForInShares(address _receiver) public view returns (uint256 yieldInShares) {
        uint256 principalInShares = _convertToShares(receiverTotalPrincipal[_receiver]);
        uint256 shares = receiverShares[_receiver];

        // if vault made a loss, there is no yield
        yieldInShares = shares > principalInShares ? shares - principalInShares : 0;
    }

    /**
     * @dev Calculates the debt for a given receiver. The receiver is in debt if the yield is on all his streams is negative.
     * @param _receiver The address of the receiver.
     * @return The calculated debt, 0 if there is no debt or yield is not negative.
     */
    function debtFor(address _receiver) public view returns (uint256) {
        uint256 principal = receiverTotalPrincipal[_receiver];
        uint256 currentValue = _convertToAssets(receiverShares[_receiver]);

        return currentValue < principal ? principal - currentValue : 0;
    }

    function _checkImmediateLossOnOpen(address _receiver, address _streamer, uint256 _principal) internal view {
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

        if (lossOnOpen > _principal.mulWadUp(lossTolerancePercent)) revert LossToleranceExceeded();
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return vault.convertToAssets(_shares);
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        return vault.convertToShares(_assets);
    }
}
