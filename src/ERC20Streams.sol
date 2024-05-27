// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {CommonErrors} from "./common/CommonErrors.sol";

/**
 * @title This contract facilitates the streaming of ERC20 tokens with unique stream IDs per streamer-receiver pair.
 * @notice This contract allows users to open, top up, claim from, and close streams. Note that the receiver can only claim from one stream at a time or use multicall as workaround.
 */
contract ERC20Streams is Multicall {
    using CommonErrors for uint256;
    using CommonErrors for address;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    struct Stream {
        uint256 amount;
        uint256 ratePerSecond;
        uint128 startTime;
        uint128 lastClaimTime;
    }

    event StreamOpened(address indexed streamer, address indexed receiver, uint256 amount, uint256 duration);
    event TokensClaimed(address indexed streamer, address indexed receiver, uint256 claimed);
    event StreamClosed(address indexed streamer, address indexed receiver, uint256 remaining, uint256 claimed);
    event StreamToppedUp(address indexed streamer, address indexed receiver, uint256 added, uint256 addedDuration);

    error ZeroDuration();
    error CannotOpenStreamToSelf();
    error StreamAlreadyExists();
    error StreamExpired();
    error RatePerSecondDecreased();
    error NoTokensToClaim();
    error StreamDoesNotExist();

    IERC20 public immutable token;

    mapping(uint256 => Stream) public streams;

    constructor(IERC20 _token) {
        address(_token).revertIfZero();

        token = _token;
    }

    /*
    * =======================================================
    *                   EXTERNAL FUNCTIONS
    * =======================================================
    */

    /**
     * @notice Calculates the stream ID for a given streamer and receiver
     * @param _streamer The address of the streamer
     * @param _receiver The address of the receiver
     * @return The calculated stream ID
     */
    function getStreamId(address _streamer, address _receiver) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_streamer, _receiver)));
    }

    /**
     * @notice Retrieves the stream information for a given stream ID
     * @param _streamId The ID of the stream
     * @return The Stream struct containing all the stream information
     */
    function getStream(uint256 _streamId) public view returns (Stream memory) {
        return streams[_streamId];
    }

    /**
     * @notice Opens a new token stream from the sender to a specified receiver
     * @param _receiver The address of the receiver
     * @param _amount The number of tokens to stream
     * @param _duration The duration of the stream in seconds
     */
    function open(address _receiver, uint256 _amount, uint256 _duration) public {
        _receiver.revertIfZero();
        _checkOpenStreamToSelf(_receiver);
        _amount.revertIfZero();
        _checkZeroDuration(_duration);

        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream storage stream = streams[streamId];

        if (stream.amount > 0) {
            // If the stream already exists and isn't expired, revert
            if (block.timestamp < stream.startTime + stream.amount.divWadUp(stream.ratePerSecond)) {
                revert StreamAlreadyExists();
            }

            // if is expired, transfer unclaimed tokens to receiver & emit close event
            emit StreamClosed(msg.sender, _receiver, 0, stream.amount);

            IERC20(token).safeTransfer(_receiver, stream.amount);
        }

        uint256 ratePerSecond = _amount.divWadUp(_duration);

        stream.amount = _amount;
        stream.ratePerSecond = ratePerSecond;
        stream.startTime = uint128(block.timestamp);
        stream.lastClaimTime = uint128(block.timestamp);

        emit StreamOpened(msg.sender, _receiver, stream.amount, _duration);

        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Opens a new token stream using EIP-2612 permit for allowance
     * @param _receiver The address of the receiver
     * @param _amount The number of tokens to stream
     * @param _duration The duration of the stream in seconds
     * @param _deadline Expiration time of the permit
     * @param _v The recovery byte of the signature
     * @param _r Half of the ECDSA signature pair
     * @param _s Half of the ECDSA signature pair
     */
    function openUsingPermit(
        address _receiver,
        uint256 _amount,
        uint256 _duration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(token)).permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s);

        open(_receiver, _amount, _duration);
    }

    /**
     * @notice Tops up an existing token stream with additional tokens and/or duration
     * @param _receiver The address of the receiver
     * @param _additionalAmount The additional number of tokens to add to the stream
     * @param _additionalDuration The additional duration to add to the stream in seconds
     */
    function topUp(address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        _receiver.revertIfZero();
        _additionalAmount.revertIfZero();

        Stream storage stream = streams[getStreamId(msg.sender, _receiver)];

        _checkNonExistingStream(stream);

        uint256 timeRemaining = stream.amount.divWadDown(stream.ratePerSecond);

        if (block.timestamp > stream.lastClaimTime + timeRemaining) revert StreamExpired();

        stream.amount += _additionalAmount;

        uint256 newRatePerSecond = stream.amount.divWadUp(timeRemaining + _additionalDuration);

        if (newRatePerSecond < stream.ratePerSecond) revert RatePerSecondDecreased();

        stream.ratePerSecond = newRatePerSecond;

        emit StreamToppedUp(msg.sender, _receiver, _additionalAmount, _additionalDuration);

        IERC20(token).safeTransferFrom(msg.sender, address(this), _additionalAmount);
    }

    /**
     * @notice Tops up an existing token stream using EIP-2612 permit for allowance
     * @param _receiver The address of the receiver
     * @param _additionalAmount The additional number of tokens to add to the stream
     * @param _additionalDuration The additional duration to add to the stream in seconds
     * @param _deadline Expiration time of the permit
     * @param _v The recovery byte of the signature
     * @param _r Half of the ECDSA signature pair
     * @param _s Half of the ECDSA signature pair
     */
    function topUpUsingPermit(
        address _receiver,
        uint256 _additionalAmount,
        uint256 _additionalDuration,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(token)).permit(msg.sender, address(this), _additionalAmount, _deadline, _v, _r, _s);

        topUp(_receiver, _additionalAmount, _additionalDuration);
    }

    /**
     * @notice Claims tokens from an open stream
     * @param _streamer The address of the streamer
     * @param _sendTo The address to send the claimed tokens to
     * @return claimed The number of tokens claimed
     */
    function claim(address _streamer, address _sendTo) public returns (uint256 claimed) {
        _sendTo.revertIfZero();

        uint256 streamId = getStreamId(_streamer, msg.sender);
        Stream storage stream = streams[streamId];

        claimed = _previewClaim(stream);

        if (claimed == 0) revert NoTokensToClaim();

        if (claimed == stream.amount) {
            delete streams[streamId];

            // emit with 0s to indicate that the stream was closed during the claim
            emit StreamClosed(_streamer, msg.sender, 0, 0);
        } else {
            stream.lastClaimTime = uint128(block.timestamp);
            stream.amount -= claimed;
        }

        emit TokensClaimed(_streamer, msg.sender, claimed);

        IERC20(token).safeTransfer(_sendTo, claimed);
    }

    /**
     * @notice Previews the amount of tokens claimable from a stream
     * @param _streamer The address of the streamer
     * @param _receiver The address of the receiver
     * @return claimable The number of tokens that can be claimed
     */
    function previewClaim(address _streamer, address _receiver) public view returns (uint256 claimable) {
        return _previewClaim(streams[getStreamId(_streamer, _receiver)]);
    }

    /**
     * @notice Closes an existing token stream and distributes the tokens accordingly
     * @param _receiver The address of the receiver
     * @return remaining The number of tokens returned to the streamer
     * @return streamed The number of tokens transferred to the receiver
     */
    function close(address _receiver) external returns (uint256 remaining, uint256 streamed) {
        uint256 streamId = getStreamId(msg.sender, _receiver);
        Stream memory stream = streams[streamId];

        (remaining, streamed) = _previewClose(stream);

        delete streams[streamId];

        emit StreamClosed(msg.sender, _receiver, remaining, streamed);

        if (remaining != 0) IERC20(token).safeTransfer(msg.sender, remaining);

        if (streamed != 0) IERC20(token).safeTransfer(_receiver, streamed);
    }

    /**
     * @notice Previews the outcome of closing a stream without actually closing it
     * @param _streamer The address of the streamer
     * @param _receiver The address of the receiver
     * @return remaining The number of tokens that would be returned to the streamer
     * @return streamed The number of tokens that would be transferred to the receiver
     */
    function previewClose(address _streamer, address _receiver)
        public
        view
        returns (uint256 remaining, uint256 streamed)
    {
        Stream memory stream = streams[getStreamId(_streamer, _receiver)];

        return _previewClose(stream);
    }

    /* 
    * =======================================================
    *                   INTERNAL FUNCTIONS
    * =======================================================
    */

    function _previewClaim(Stream memory _stream) internal view returns (uint256 claimable) {
        _checkNonExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        claimable = elapsedTime.mulWadUp(_stream.ratePerSecond);

        // Cap the claimalbe amount to the max available amount
        if (claimable > _stream.amount) claimable = _stream.amount;
    }

    function _previewClose(Stream memory _stream) internal view returns (uint256 remaining, uint256 streamed) {
        _checkNonExistingStream(_stream);

        uint256 elapsedTime = block.timestamp - _stream.lastClaimTime;
        streamed = elapsedTime.mulWadUp(_stream.ratePerSecond);

        if (streamed > _stream.amount) streamed = _stream.amount;

        remaining = _stream.amount - streamed;

        return (remaining, streamed);
    }

    function _checkOpenStreamToSelf(address _receiver) internal view {
        if (_receiver == msg.sender) revert CannotOpenStreamToSelf();
    }

    function _checkZeroDuration(uint256 _duration) internal pure {
        if (_duration == 0) revert ZeroDuration();
    }

    function _checkNonExistingStream(Stream memory _stream) internal pure {
        if (_stream.amount == 0) revert StreamDoesNotExist();
    }
}
