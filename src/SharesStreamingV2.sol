// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/draft-IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// idea: all streams are separate and receiver can only claim from one stream at a time
contract SharesStreamingV2 is Multicall {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    IERC4626 public immutable vault;

    constructor(IERC4626 _vault) {
        vault = _vault;
    }

    struct Stream {
        uint256 shares;
        uint256 ratePerSecond;
        uint256 startTime;
        uint256 lastClaimTime;
    }

    error AddressZero();
    error ZeroDuration();
    error ZeroShares();
    error NotEnoughShares();
    error StreamAlreadyExists();
    error CannotOpenStreamToSelf();
    error StreamDoesNotExist();
    error StreamExpired();
    error StreamRatePerSecondMustNotDecrease();
    error NoSharesToClaim();

    mapping(uint256 => Stream) public streamsById;

    event OpenSharesStream(address indexed streamer, address indexed receiver, uint256 shares, uint256 duration);
    event ClaimShares(address indexed streamer, address indexed receiver, uint256 claimedShares);
    event CloseShareStream(
        address indexed streamer, address indexed receiver, uint256 remainingShares, uint256 claimedShares
    );
    event TopUpSharesStream(
        address indexed streamer, address indexed receiver, uint256 addedShares, uint256 addedDuration
    );

    function getStreamId(address _streamer, address _receiver) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_streamer, _receiver)));
    }

    function getStream(uint256 streamId) public view returns (Stream memory) {
        return streamsById[streamId];
    }

    function openStream(address _receiver, uint256 _shares, uint256 _duration) public {
        _openStream(msg.sender, _receiver, _shares, _duration);
    }

    function openStreamUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _duration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        _openStream(msg.sender, _receiver, _shares, _duration);
    }

    function _openStream(address _streamer, address _receiver, uint256 _shares, uint256 _duration) internal {
        _checkAddress(_receiver);
        _checkOpenStreamToSelf(_receiver);
        _checkShares(_streamer, _shares);
        _checkDuration(_duration);

        uint256 streamId = getStreamId(_streamer, _receiver);
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

        vault.safeTransferFrom(_streamer, address(this), _shares);

        emit OpenSharesStream(_streamer, _receiver, stream.shares, _duration);
    }

    function topUpStream(address _receiver, uint256 _additionalShares, uint256 _additionalDuration) external {
        _checkAddress(_receiver);
        _checkShares(msg.sender, _additionalShares);

        Stream storage stream = streamsById[getStreamId(msg.sender, _receiver)];

        _checkExistingStream(stream);

        uint256 timeRemaining = stream.shares / stream.ratePerSecond;

        if (block.timestamp > stream.lastClaimTime + timeRemaining) revert StreamExpired();

        stream.shares += _additionalShares;

        uint256 newRatePerSecond = stream.shares / (timeRemaining + _additionalDuration);

        if (newRatePerSecond < stream.ratePerSecond) revert StreamRatePerSecondMustNotDecrease();

        stream.ratePerSecond = newRatePerSecond;

        vault.safeTransferFrom(msg.sender, address(this), _additionalShares);

        emit TopUpSharesStream(msg.sender, _receiver, _additionalShares, _additionalDuration);
    }

    function claim(address _streamer) public returns (uint256) {
        uint256 streamId = getStreamId(_streamer, msg.sender);
        Stream storage stream = streamsById[streamId];

        uint256 sharesToClaim = _previewClaim(stream);

        if (sharesToClaim == 0) revert NoSharesToClaim();

        // Cap the claimable shares at the total allocated shares
        if (sharesToClaim == stream.shares) {
            // delete stream because it expired?
            delete streamsById[streamId];

            // emit event?
        } else {
            stream.lastClaimTime = block.timestamp;
            stream.shares -= sharesToClaim;
        }

        vault.safeTransfer(msg.sender, sharesToClaim);

        emit ClaimShares(_streamer, msg.sender, sharesToClaim);

        return sharesToClaim;
    }

    function previewClaim(address _streamer, address _receiver) public view returns (uint256) {
        return _previewClaim(streamsById[getStreamId(_streamer, _receiver)]);
    }

    function _previewClaim(Stream memory _stream) internal view returns (uint256) {
        _checkExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimableShares = elapsedTime * _stream.ratePerSecond;

        // Cap the shares to claim to the total allocated shares
        if (claimableShares > _stream.shares) claimableShares = _stream.shares;

        return claimableShares;
    }

    function closeStream(address _receiver) external returns (uint256 remainingShares, uint256 streamedShares) {
        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream memory stream = streamsById[streamId];

        (remainingShares, streamedShares) = _previewCloseStream(stream);

        delete streamsById[streamId];

        if (remainingShares != 0) vault.safeTransfer(msg.sender, remainingShares);

        if (streamedShares != 0) vault.safeTransfer(_receiver, streamedShares);

        emit CloseShareStream(msg.sender, _receiver, remainingShares, streamedShares);
    }

    function previewCloseStream(address _streamer, address _receiver)
        public
        view
        returns (uint256 remainingShares, uint256 streamedShares)
    {
        Stream memory stream = streamsById[getStreamId(_streamer, _receiver)];

        return _previewCloseStream(stream);
    }

    function _previewCloseStream(Stream memory _stream)
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

    function _checkAddress(address _receiver) internal pure {
        if (_receiver == address(0)) revert AddressZero();
    }

    function _checkShares(address _streamer, uint256 _shares) internal view {
        if (_shares == 0) revert ZeroShares();

        if (vault.allowance(_streamer, address(this)) < _shares) revert NotEnoughShares();
    }

    function _checkDuration(uint256 _duration) internal pure {
        if (_duration == 0) revert ZeroDuration();
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }

    function _checkExistingStream(Stream memory _stream) internal pure {
        if (_stream.shares == 0) revert StreamDoesNotExist();
    }
}
