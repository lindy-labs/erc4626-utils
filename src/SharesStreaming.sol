// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./common/Errors.sol";
import "./common/StreamingBase.sol";

/// @title A contract for streaming shares with unique stream IDs per streamer-receiver pair
/// @notice This contract allows users to open, top up, claim from, and close share streams. Receiver can only claim from one stream at a time or use multicall.
/// @dev Inherits from Multicall and uses SafeERC20 for token interactions
contract SharesStreaming is StreamingBase {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;

    error ZeroDuration();
    error StreamAlreadyExists();
    error StreamExpired();
    error StreamRatePerSecondMustNotDecrease();
    error NoSharesToClaim();

    event OpenSharesStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseSharesStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpSharesStream(
        address indexed streamer, address indexed receiver, uint256 addedShares, uint256 addedDuration
    );

    struct Stream {
        uint256 shares;
        uint256 ratePerSecond;
        uint256 startTime;
        uint256 lastClaimTime;
    }

    mapping(uint256 => Stream) public streamsById;

    constructor(IERC4626 _vault) {
        _checkZeroAddress(address(_vault));

        vault = _vault;
    }

    /// @notice Calculates the stream ID for a given streamer and receiver
    /// @param _streamer The address of the streamer
    /// @param _receiver The address of the receiver
    /// @return The calculated stream ID
    function getSharesStreamId(address _streamer, address _receiver) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_streamer, _receiver)));
    }

    /// @notice Retrieves the stream information for a given stream ID
    /// @param streamId The ID of the stream
    /// @return The Stream struct containing all the stream information
    function getSharesStream(uint256 streamId) public view returns (Stream memory) {
        return streamsById[streamId];
    }

    /// @notice Opens a new share stream from the sender to a specified receiver
    /// @param _receiver The address of the receiver
    /// @param _shares The number of shares to stream
    /// @param _duration The duration of the stream in seconds
    function openSharesStream(address _receiver, uint256 _shares, uint256 _duration) public {
        _openSharesStream(msg.sender, _receiver, _shares, _duration);
    }

    /// @notice Opens a new share stream using EIP-2612 permit for allowance
    /// @param _receiver The address of the receiver
    /// @param _shares The number of shares to stream
    /// @param _duration The duration of the stream in seconds
    /// @param _deadline Expiration time of the permit
    /// @param _v The recovery byte of the signature
    /// @param _r Half of the ECDSA signature pair
    /// @param _s Half of the ECDSA signature pair
    function openSharesStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _duration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        _openSharesStream(msg.sender, _receiver, _shares, _duration);
    }

    function _openSharesStream(address _streamer, address _receiver, uint256 _shares, uint256 _duration) internal {
        _checkZeroAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkShares(_streamer, _shares);
        _checkDuration(_duration);

        uint256 streamId = getSharesStreamId(_streamer, _receiver);
        Stream storage stream = streamsById[streamId];

        if (stream.shares > 0) {
            // If the stream already exists and isn't expired, revert
            if (block.timestamp < stream.startTime + stream.shares / stream.ratePerSecond) {
                revert StreamAlreadyExists();
            }

            // if is expired, transfer unclaimed shares to receiver
            vault.safeTransfer(_receiver, stream.shares);
        }

        uint256 _ratePerSecond = _shares / _duration;

        stream.shares = _shares;
        stream.ratePerSecond = _ratePerSecond;
        stream.startTime = block.timestamp;
        stream.lastClaimTime = block.timestamp;

        emit OpenSharesStream(_streamer, _receiver, stream.shares, _duration);

        vault.safeTransferFrom(_streamer, address(this), _shares);
    }

    /// @notice Tops up an existing share stream with additional shares and/or duration
    /// @param _receiver The address of the receiver
    /// @param _additionalShares The additional number of shares to add to the stream
    /// @param _additionalDuration The additional duration to add to the stream in seconds
    function topUpSharesStream(address _receiver, uint256 _additionalShares, uint256 _additionalDuration) public {
        _checkZeroAddress(_receiver);
        _checkShares(msg.sender, _additionalShares);

        Stream storage stream = streamsById[getSharesStreamId(msg.sender, _receiver)];

        _checkExistingStream(stream);

        uint256 timeRemaining = stream.shares / stream.ratePerSecond;

        if (block.timestamp > stream.lastClaimTime + timeRemaining) revert StreamExpired();

        stream.shares += _additionalShares;

        uint256 newRatePerSecond = stream.shares / (timeRemaining + _additionalDuration);

        if (newRatePerSecond < stream.ratePerSecond) revert StreamRatePerSecondMustNotDecrease();

        stream.ratePerSecond = newRatePerSecond;

        emit TopUpSharesStream(msg.sender, _receiver, _additionalShares, _additionalDuration);

        vault.safeTransferFrom(msg.sender, address(this), _additionalShares);
    }

    /// @notice Tops up an existing share stream using EIP-2612 permit for allowance
    /// @dev Emits a TopUpSharesStream event
    /// @param _receiver The address of the receiver
    /// @param _additionalShares The additional number of shares to add to the stream
    /// @param _additionalDuration The additional duration to add to the stream in seconds
    /// @param _deadline Expiration time of the permit
    /// @param _v The recovery byte of the signature
    /// @param _r Half of the ECDSA signature pair
    /// @param _s Half of the ECDSA signature pair
    function topUpSharesStreamUsingPermit(
        address _receiver,
        uint256 _additionalShares,
        uint256 _additionalDuration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(vault)).permit(msg.sender, address(this), _additionalShares, _deadline, _v, _r, _s);

        topUpSharesStream(_receiver, _additionalShares, _additionalDuration);
    }

    /// @notice Claims shares from an open stream
    /// @param _streamer The address of the streamer
    /// @return The number of shares claime
    function claimShares(address _streamer) public returns (uint256) {
        uint256 streamId = getSharesStreamId(_streamer, msg.sender);
        Stream storage stream = streamsById[streamId];

        uint256 sharesToClaim = _previewClaimShares(stream);

        if (sharesToClaim == 0) revert NoSharesToClaim();

        if (sharesToClaim == stream.shares) {
            // TODO: delete stream because it expired? reconsider this
            delete streamsById[streamId];

            // TODO: emit event?
        } else {
            stream.lastClaimTime = block.timestamp;
            stream.shares -= sharesToClaim;
        }

        emit ClaimShares(_streamer, msg.sender, sharesToClaim);

        vault.safeTransfer(msg.sender, sharesToClaim);

        return sharesToClaim;
    }

    /// @notice Previews the amount of shares claimable from a stream
    /// @param _streamer The address of the streamer
    /// @param _receiver The address of the receiver
    /// @return The number of shares that can be claimed
    function previewClaimShares(address _streamer, address _receiver) public view returns (uint256) {
        return _previewClaimShares(streamsById[getSharesStreamId(_streamer, _receiver)]);
    }

    function _previewClaimShares(Stream memory _stream) internal view returns (uint256 claimableShares) {
        _checkExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        claimableShares = elapsedTime * _stream.ratePerSecond;

        // Cap the shares to claim to the total allocated shares
        if (claimableShares > _stream.shares) claimableShares = _stream.shares;
    }

    /// @notice Closes an existing share stream and distributes the shares accordingly
    /// @dev Emits a CloseShareStream event
    /// @param _receiver The address of the receiver
    /// @return remainingShares The number of shares returned to the streamer
    /// @return streamedShares The number of shares transferred to the receiver
    function closeSharesStream(address _receiver) external returns (uint256 remainingShares, uint256 streamedShares) {
        uint256 streamId = getSharesStreamId(msg.sender, _receiver);
        Stream memory stream = streamsById[streamId];

        (remainingShares, streamedShares) = _previewCloseSharesStream(stream);

        delete streamsById[streamId];

        emit CloseSharesStream(msg.sender, _receiver, remainingShares, streamedShares);

        if (remainingShares != 0) vault.safeTransfer(msg.sender, remainingShares);

        if (streamedShares != 0) vault.safeTransfer(_receiver, streamedShares);
    }

    /// @notice Previews the outcome of closing a stream without actually closing it
    /// @param _streamer The address of the streamer
    /// @param _receiver The address of the receiver
    /// @return remainingShares The number of shares that would be returned to the streamer
    /// @return streamedShares The number of shares that would be transferred to the receiver
    function previewCloseSharesStream(address _streamer, address _receiver)
        public
        view
        returns (uint256 remainingShares, uint256 streamedShares)
    {
        Stream memory stream = streamsById[getSharesStreamId(_streamer, _receiver)];

        return _previewCloseSharesStream(stream);
    }

    function _previewCloseSharesStream(Stream memory _stream)
        internal
        view
        returns (uint256 remainingShares, uint256 streamedShares)
    {
        _checkExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        streamedShares = elapsedTime * _stream.ratePerSecond;

        if (streamedShares > _stream.shares) streamedShares = _stream.shares;

        remainingShares = _stream.shares - streamedShares;

        return (remainingShares, streamedShares);
    }

    function _checkDuration(uint256 _duration) internal pure {
        if (_duration == 0) revert ZeroDuration();
    }

    function _checkExistingStream(Stream memory _stream) internal pure {
        if (_stream.shares == 0) revert StreamDoesNotExist();
    }
}
