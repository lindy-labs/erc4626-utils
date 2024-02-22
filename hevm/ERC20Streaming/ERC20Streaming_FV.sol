// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "../src/common/Errors.sol";
import {ERC20Streaming} from "../src/ERC20Streaming.sol";

contract ERC20Streaming_FV is Test {
    using FixedPointMathLib for uint256;

    MockERC20 public asset;
    MockERC4626 public vault;
    ERC20Streaming public streaming;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        streaming = new ERC20Streaming(IERC4626(address(vault)));
    }

    // Tests that openStream works correctly by opening a stream from msg_sender to _receiver with the given amount and duration. Checks that the stream values are set properly.
    function prove_integrity_openStream(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);

        ERC20Streaming.Stream memory stream_ = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));

        assert(stream_.amount == _amount);
        assert(stream_.ratePerSecond == _amount.divWadUp(_duration));
        assert(stream_.startTime == uint128(block.timestamp));
        assert(stream_.lastClaimTime == uint128(block.timestamp));
    }
    
    // Same as prove_integrity_openStream, but opens the stream using permit instead of approval.
    function prove_integrity_openStreamUsingPermit(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);

        ERC20Streaming.Stream memory stream_ = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));

        assert(stream_.amount == _amount);
        assert(stream_.ratePerSecond == _amount.divWadUp(_duration));
        assert(stream_.startTime == uint128(block.timestamp));
        assert(stream_.lastClaimTime == uint128(block.timestamp));
    }

    // Tests topUpStream by topping up an existing stream. Checks that the ratePerSecond is updated properly.
    function prove_integrity_topUpStream(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);

        ERC20Streaming.Stream memory stream_ = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));

        assert(stream_.ratePerSecond == stream_.amount.divWadUp(stream_.amount.divWadDown(stream_.ratePerSecond) + _additionalDuration));
    }
 
    // Same as prove_integrity_topUpStream, but uses permit instead of approval.
    function prove_integrity_topUpStreamUsingPermit(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);

        ERC20Streaming.Stream memory stream_ = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));

        assert(stream_.ratePerSecond == stream_.amount.divWadUp(stream_.amount.divWadDown(stream_.ratePerSecond) + _additionalDuration));
    }


    function streamDeleted(uint256 streamId) public view returns (bool) {
        ERC20Streaming.Stream memory stream = streaming.getStream(streamId);
        return (stream.amount == 0 && stream.ratePerSecond == 0 && stream.startTime == 0 && stream.lastClaimTime == 0);
    }

    // Tests claiming from a stream. Checks that the claimed amount is correct and the stream is updated properly.  
    function prove_integrity_claim(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(msg_sender != _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount != 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable != 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);

        ERC20Streaming.Stream memory stream_ = streaming.getStream(streaming.getStreamId(msg_sender, _streamer));
        uint256 elapsedTime_ = block.timestamp - stream_.lastClaimTime;
        uint256 claimed = elapsedTime_.mulWadUp(stream_.ratePerSecond);
        if (claimed > stream_.amount) claimed = stream_.amount;
        assert((claimed == stream_.amount && streamDeleted(streamId)) ||
            (stream_.lastClaimTime == uint128(block.timestamp) && stream_.amount + claimed == _stream.amount));
    }

    // Tests closing a stream. Checks that the stream is deleted.
    function prove_integrity_closeStream(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(msg_sender != _receiver);

        vm.prank(msg_sender);
        streaming.closeStream(_receiver);

        uint256 streamId = streaming.getStreamId(_receiver, msg_sender);
        assert(streamDeleted(streamId));
    }

    // ******************************************* REVERTABLE FUNCTIONS ***************************************************

    // openStream reverts if the sender is the zero address
    function proveFail_openStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }
    
    // openStream reverts if the receiver is the zero address
    function proveFail_openStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStream reverts if the sender equals the receiver
    function proveFail_openStream_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver == msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStream reverts if the amount is zero
    function proveFail_openStream_When_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount == 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStream reverts if the allowance is less than the amount
    function proveFail_openStream_When_Allowance_Is_Less_Than_Amount(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) < _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStream reverts if the duration is zero
    function proveFail_openStream_When_Duration_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration== 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStream reverts when a stream already exists but time has passed since the last claim
    function proveFail_openStream_When_The_Amount_Of_Stream_Is_Greater_Than_Zero_But_Time_Passed(address msg_sender, address _receiver, uint256 _amount, uint256 _duration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require((_stream.amount > 0 && block.timestamp < _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStream(_receiver, _amount, _duration);
    }

    // openStreamUsingPermit reverts when the message sender is the zero address
    function proveFail_openStreamUsingPermit_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when the receiver is the zero address
    function proveFail_openStreamUsingPermit_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when the message sender equals the receiver
    function proveFail_openStreamUsingPermit_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver == msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when the amount is zero
    function proveFail_openStreamUsingPermit_When_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount == 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when the allowance is less than the amount
    function proveFail_openStreamUsingPermit_When_Allowance_Is_Less_Than_Amount(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) < _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when the duration is zero
    function proveFail_openStreamUsingPermit_When_Duration_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration == 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0 || (_stream.amount > 0 && block.timestamp >= _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond)));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // openStreamUsingPermit reverts when a stream exists but time has passed
    function proveFail_openStreamUsingPermit_When_The_Amount_Of_Stream_Is_Greater_Than_Zero_But_Time_Passed(address msg_sender, address _receiver, uint256 _amount, uint256 _duration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);
        require(_amount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _amount);
        require(_duration != 0);

        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount > 0 && block.timestamp < _stream.startTime + _stream.amount.divWadUp(_stream.ratePerSecond));

        vm.prank(msg_sender);
        streaming.openStreamUsingPermit(_receiver, _amount, _duration, _deadline, _v, _r, _s);
    }

    // topUpStream reverts if the sender is the zero address
    function proveFail_topUpStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the receiver is the zero address
    function proveFail_topUpStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the sender equals the receiver
    function proveFail_topUpStream_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender == _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the additional amount is zero
    function proveFail_topUpStream_When_Additional_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount == 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the allowance is less than the additional amount
    function proveFail_topUpStream_When_Allowance_Is_Less_Than_Additional_Amount(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) < _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the stream amount is zero
    function proveFail_topUpStream_When_The_Receiver_Stream_Has_A_Zero_Amount(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the last claim time has passed
    function proveFail_topUpStream_When_The_Receiver_Stream_Has_A_Smaller_Last_Claim_Time(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp > _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStream reverts if the new ratePerSecond would be less
    function proveFail_topUpStream_When_The_Receiver_Stream_Has_A_Smaller_Rate_Per_Second(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) < _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStream(_receiver, _additionalAmount, _additionalDuration);
    }

    // topUpStreamUsingPermit reverts when the message sender is the zero address
    function proveFail_topUpStreamUsingPermit_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the receiver is the zero address
    function proveFail_topUpStreamUsingPermit_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the message sender equals the receiver
    function proveFail_topUpStreamUsingPermit_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender == _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the additional amount is zero
    function proveFail_topUpStreamUsingPermit_When_Additional_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount == 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the allowance is less than the additional amount
    function proveFail_topUpStreamUsingPermit_When_Allowance_Is_Less_Than_Additional_Amount(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) < _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the receiver stream has a zero amount
    function proveFail_topUpStreamUsingPermit_When_The_Receiver_Stream_Has_A_Zero_Amount(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount == 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the receiver stream has a smaller last claim time
    function proveFail_topUpStreamUsingPermit_When_The_Receiver_Stream_Has_A_Smaller_Last_Claim_Time(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp > _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) >= _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }

    // topUpStreamUsingPermit reverts when the receiver stream has a smaller rate per second
    function proveFail_topUpStreamUsingPermit_When_The_Receiver_Stream_Has_A_Smaller_Rate_Per_Second(address msg_sender, address _receiver, uint256 _additionalAmount, uint256 _additionalDuration, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(msg_sender != _receiver);
        require(_additionalAmount != 0);
        require(vault.allowance(msg_sender, address(this)) >= _additionalAmount);
        
        ERC20Streaming.Stream memory _stream = streaming.getStream(streaming.getStreamId(_receiver, msg_sender));
        require(_stream.amount != 0);
        require(block.timestamp <= _stream.lastClaimTime + _stream.amount.divWadDown(_stream.ratePerSecond));
        require(_stream.amount.divWadUp(_stream.amount.divWadDown(_stream.ratePerSecond) + _additionalDuration) < _stream.ratePerSecond);

        vm.prank(msg_sender);
        streaming.topUpStreamUsingPermit(_receiver, _additionalAmount, _additionalDuration, _deadline, _v, _r, _s);
    }


    // claim reverts if the sender is the zero address
    function proveFail_claim_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender == address(0));
        require(_sendTo != address(0));
        require(msg_sender != _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount != 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable != 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);
    }

    // claim reverts if the sendTo is the zero address
    function proveFail_claim_When_sendTo_Equals_ZeroAddress(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender != address(0));
        require(_sendTo == address(0));
        require(msg_sender != _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount != 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable != 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);
    }

    // claim reverts if the sender equals the sendTo
    function proveFail_claim_When_MSGSender_Equals_sendTo(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(msg_sender == _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount != 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable != 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);
    }

    // claim reverts if the stream amount is zero
    function proveFail_claim_When_The_Stream_Amount_Equals_Zero(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(msg_sender != _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount == 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable != 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);
    }

    // claim reverts if the claimable amount is zero.
    function proveFail_claim_When_Claimable_Equals_Zero(address msg_sender, address _streamer, address _sendTo) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(msg_sender != _sendTo);
        uint256 streamId = streaming.getStreamId(_streamer, msg_sender);
        ERC20Streaming.Stream memory _stream = streaming.getStream(streamId);
        require(_stream.amount != 0);
        uint256 _elapsedTime = block.timestamp - _stream.lastClaimTime;
        uint256 claimable = _elapsedTime.mulWadUp(_stream.ratePerSecond);
        if (claimable > _stream.amount) claimable = _stream.amount;
        require(claimable == 0);

        vm.prank(msg_sender);
        streaming.claim(_streamer, _sendTo);
    }

    // closeStream reverts if the sender is the zero address
    function proveFail_closeStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender == address(0));
        require(msg_sender != _receiver);

        vm.prank(msg_sender);
        streaming.closeStream(_receiver);
    }

    // closeStream reverts if the sender equals the receiver
    function proveFail_closeStream_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(msg_sender == _receiver);

        vm.prank(msg_sender);
        streaming.closeStream(_receiver);
    }
}
