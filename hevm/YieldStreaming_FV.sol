// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {Multicall} from "openzeppelin-contracts/utils/Multicall.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldStreaming} from "../src/YieldStreaming.sol";
import "../src/common/Errors.sol";

contract YieldStreaming_FV is Test {
    using FixedPointMathLib for uint256;

    YieldStreaming public yieldStreaming;
    MockERC4626 public vault;
    MockERC20 public asset;

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        yieldStreaming = new YieldStreaming(address(this), IERC4626(address(vault)));
    }

    function proveFail_constructor_failsIfVaultIsAddress0() public {
        new YieldStreaming(address(this), IERC4626(address(0)));
    }

    function proveFail_constructor_failsIfOwnerIsAddress0() public {
        new YieldStreaming(address(0), IERC4626(address(vault)));
    }

    function proveFail_setLossTolerancePercent_failsIfCallerIsNotOwner(address caller) public {
        require(caller != address(this));
        vm.prank(caller);
        yieldStreaming.setLossTolerancePercent(0);
    }

    function proveFail_setlossTolerancePercent_failsIfLossToleraceIsAboveMax(uint256 newLossTolerance) public {
        require(newLossTolerance > yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(newLossTolerance);
    }

    function prove_setLossTolerancePercent_updatesLossTolerancePercentValue(uint256 newLossTolerance) public {
        require(newLossTolerance <= yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(newLossTolerance);

        assertEq(yieldStreaming.lossTolerancePercent(), newLossTolerance);
    }

    function prove_auxiliary_integrity_of_openYieldStream(address _receiver, uint256 _principal) public { // This is needed by the next symbolic test
        require(_receiver != address(0));
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent()));
    }

    function prove_integrity_of_openYieldStream(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 _receiverPrincipal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        uint256 principal = yieldStreaming.openYieldStream(_receiver, _shares);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + _shares == receiverShares_);
        assert(_receiverTotalPrincipal + principal == receiverTotalPrincipal_);
        assert(_receiverPrincipal + principal == receiverPrincipal_);
    }

    function prove_integrity_of_openYieldStreamUsingPermit(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 _receiverPrincipal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        uint256 principal = yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + _shares == receiverShares_);
        assert(_receiverTotalPrincipal + principal == receiverTotalPrincipal_);
        assert(_receiverPrincipal + principal == receiverPrincipal_);
    }

    function prove_integrity_of_closeYieldStream(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        (, principal) = yieldStreaming._previewCloseYieldStream(_receiver, msg_sender);
        require(principal != 0);
        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.closeYieldStream(_receiver);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares == receiverShares_ + shares);
        assert(_receiverTotalPrincipal == receiverTotalPrincipal_ + principal);
        assert(receiverPrincipal_ == 0);
    }
/*
    function prove_integrity_of_claimYield(address _sendTo) public { }
    
    function prove_integrity_of_claimYieldInShares(address _sendTo) public { }

    */
}
