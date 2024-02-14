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
    address public carol = address(0x3);

    event OpenStream(address indexed streamer, address indexed receiver, uint256 amount, uint256 duration);
    event Claim(address indexed streamer, address indexed receiver, uint256 claimed);
    event CloseStream(address indexed streamer, address indexed receiver, uint256 remaining, uint256 claimed);
    event TopUpStream(address indexed streamer, address indexed receiver, uint256 added, uint256 addedDuration);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        streaming = new ERC20Streaming(IERC4626(address(vault)));
    }

    // *** constructor *** ///

    function proveFail_constructor_failsForAddress0() public {
        new ERC20Streaming(IERC4626(address(0)));
    }

    // *** #openStream *** ///

    function prove_openStream_createsNewStream() public {
        uint256 shares = _depositToVault(alice, 1e18);
        uint256 duration = 1 days;

        vm.prank(alice);
        vault.approve(address(streaming), shares);
        vm.prank(alice);
        streaming.openStream(bob, shares, duration);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(address(streaming)), shares);

        ERC20Streaming.Stream memory stream = streaming.getStream(streaming.getStreamId(alice, bob));
        assertEq(stream.amount, shares, "stream amount");
        assertEq(stream.ratePerSecond, shares.divWadUp(duration), "stream rate per second");
        assertEq(stream.startTime, block.timestamp, "stream start time");
        assertEq(stream.lastClaimTime, block.timestamp, "stream last claim time");
    }

    function _depositToVault(address _account, uint256 _amount) internal returns (uint256 shares) {
        vm.prank(_account);
        asset.mint(_account, _amount);
        vm.prank(_account);
        asset.approve(address(vault), _amount);
        vm.prank(_account);
        shares = vault.deposit(_amount, _account);
    }

}
