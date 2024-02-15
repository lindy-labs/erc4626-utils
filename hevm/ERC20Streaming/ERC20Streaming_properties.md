# Properties of ERC20Streaming

## Overview of the ERC20Streaming

The ERC20Streaming contract enables the seamless streaming of ERC20 tokens, assigning distinct stream IDs to each streamer-receiver duo. Within this contract, users can initiate, replenish, withdraw from, and terminate streams. It's important to highlight that receivers are limited to claiming from one stream at a time, although they can leverage multicall functionality as a workaround if needed.

The ERC20Streaming has the following state variables:
* `streamById` (type `mapping(uint256 => Stream)`), mapping of `Stream`s;
* `token` (type `address`), token address.

The ERC20Streaming has the following external/public functions that change state variables:

* `function openStream(address _receiver, uint256 _amount, uint256 _duration) public`, Opens a new token stream from the sender to a specified receiver;
* `function openStreamUsingPermit(address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external`, Opens a new token stream using EIP-2612 permit for allowance;
* `function topUpStream(address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public`, Tops up an existing token stream with additional tokens and/or duration;
* `function topUpStreamUsingPermit(address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) external`, Tops up an existing token stream using EIP-2612 permit for allowance;
* `function claim(address _streamer, address _sendTo) public returns (uint256 claimed)`, Claims tokens from an open stream;
* `function closeStream(address _receiver) external returns (uint256 remaining, uint256 streamed)`, Closes an existing token stream and distributes the tokens accordingly.

It has the following external/public functions that are view only and change nothing:
* `function getStreamId(address _streamer, address _receiver) public pure returns (uint256)`, Calculates the stream ID for a given streamer and receiver;
* `function getStream(uint256 _streamId) public view returns (Stream memory)`, Retrieves the stream information for a given stream ID;
* `function previewClaim(address _streamer, address _receiver) public view returns (uint256 claimable)`, Previews the amount of tokens claimable from a stream;
* `function previewCloseStream(address _streamer, address _receiver) public view returns (uint256 remaining, uint256 streamed)`, Previews the outcome of closing a stream without actually closing it.


## Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
| 1 | [Symbolic test checking that openStream updates stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L31) | Y | Y |
| 2 | [Symbolic test checking that openStreamUsingPermit updates stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L54) | Y | Y |
| 3 | [Symbolic test checking that topUpStream updates stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L77) | Y | Y |  
| 4 | [Symbolic test checking that topUpStreamUsingPermit updates stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L98) | Y | Y |
| 5 | [Symbolic test checking that claim updates stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L125) | Y | Y |
| 6 | [Symbolic test checking that closeStream deletes stream state properly](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L149) | Y | Y |

## Revertable Properties

| No. | Property  | Specified | Verified |
| ---- | --------  | -------- | -------- |
Here are the markdown table entries for the negative tests, with links pointing to the first line of each function signature:

| S. No. | Description | Spec | Impl |
|-|-|-|-|
| 7 | [openStream reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L163) | Y | Y |
| 8 | [openStream reverts when receiver is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L179) | Y | Y |  
| 9 | [openStream reverts when sender equals receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L195) | Y | Y |
| 10 | [openStream reverts when amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L211) | Y | Y |  
| 11 | [openStream reverts when allowance less than amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L227) | Y | Y |
| 12 | [openStream reverts when duration is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L243) | Y | Y |
| 13 | [openStream reverts when stream exists but time passed](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L259) | Y | Y |
| 14 | [openStreamUsingPermit reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L275) | Y | Y |
| 15 | [openStreamUsingPermit reverts when receiver is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L291) | Y | Y |
| 16 | [openStreamUsingPermit reverts when sender equals receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L307) | Y | Y |
| 17 | [openStreamUsingPermit reverts when amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L323) | Y | Y |
| 18 | [openStreamUsingPermit reverts when allowance less than amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L339) | Y | Y |
| 19 | [openStreamUsingPermit reverts when duration is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L355) | Y | Y |
| 20 | [openStreamUsingPermit reverts when stream exists but time passed](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L371) | Y | Y |
| 21 | [topUpStream reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L387) | Y | Y |
| 22 | [topUpStream reverts when receiver is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L404) | Y | Y |
| 23 | [topUpStream reverts when sender equals receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L421) | Y | Y |
| 24 | [topUpStream reverts when additional amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L438) | Y | Y |
| 25 | [topUpStream reverts when allowance less than additional amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L455) | Y | Y | 
| 26 | [topUpStream reverts when receiver stream amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L472) | Y | Y |
| 27 | [topUpStream reverts when last claim time passed](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L489 | Y | Y |
| 28 | [topUpStream reverts when new rate per second less](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L506) | Y | Y |
| 29 | [topUpStreamUsingPermit reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L523) | Y | Y |
| 30 | [topUpStreamUsingPermit reverts when receiver is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L540) | Y | Y |
| 31 | [topUpStreamUsingPermit reverts when sender equals receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L557) | Y | Y |
| 32 | [topUpStreamUsingPermit reverts when additional amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L574) | Y | Y |
| 33 | [topUpStreamUsingPermit reverts when allowance less than additional amount](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L591) | Y | Y |
| 34 | [topUpStreamUsingPermit reverts when receiver stream amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L608) | Y | Y | 
| 35 | [topUpStreamUsingPermit reverts when last claim time passed](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L625) | Y | Y |
| 36 | [topUpStreamUsingPermit reverts when new rate per second less](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L642) | Y | Y |
| 37 | [claim reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L660) | Y | Y |
| 38 | [claim reverts when sendTo is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L677) | Y | Y |
| 39 | [claim reverts when sender equals sendTo](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L694)  | Y | Y |
| 40 | [claim reverts when stream amount is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L711) | Y | Y |
| 41 | [claim reverts when claimable is zero](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L728) | Y | Y |
| 42 | [closeStream reverts when sender is zero address](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L745) | Y | Y |
| 43 | [closeStream reverts when sender equals receiver](https://github.com/lindy-labs/erc4626-utils/blob/FormalVerification/hevm/ERC20Streaming/ERC20Streaming_FV.sol#L754) | Y | Y |