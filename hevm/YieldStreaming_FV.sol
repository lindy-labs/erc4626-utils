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

    // Checks that constructing YieldStreaming with a zero vault address reverts
    function proveFail_constructor_failsIfVaultIsAddress0() public {
        new YieldStreaming(address(this), IERC4626(address(0)));
    }

    // Checks that constructing YieldStreaming with a zero owner address reverts
    function proveFail_constructor_failsIfOwnerIsAddress0() public {
        new YieldStreaming(address(0), IERC4626(address(vault)));
    }

    // Checks that setLossTolerancePercent fails if called by someone other than the owner
    function proveFail_setLossTolerancePercent_failsIfCallerIsNotOwner(address caller) public {
        require(caller != address(this));
        vm.prank(caller);
        yieldStreaming.setLossTolerancePercent(0);
    }

    // Checks that setLossTolerancePercent fails if trying to set above the maximum
    function proveFail_setlossTolerancePercent_failsIfLossToleraceIsAboveMax(uint256 newLossTolerance) public {
        require(newLossTolerance > yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(newLossTolerance);
    }

    // Checks that setLossTolerancePercent updates lossTolerancePercent
    function prove_setLossTolerancePercent_updatesLossTolerancePercentValue(uint256 newLossTolerance) public {
        require(newLossTolerance <= yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(newLossTolerance);

        assertEq(yieldStreaming.lossTolerancePercent(), newLossTolerance);
    }

    // Auxiliary function for the symbolic test prove_integrity_of_openYieldStream below. Checks loss on open is within tolerance
    function prove_auxiliary_integrity_of_openYieldStream(address _receiver, uint256 _principal) public { // This is needed by the next symbolic test
        require(_receiver != address(0));
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent()));
    }

    // Symbolic test checking that openYieldStream updates receiver state properly
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

    // Symbolic test checking openYieldStreamUsingPermit updates receiver state properly
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

    // Checks closeYieldStream updates receiver state properly
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

    // Symbolic test checking claimYield transfers correct asset amount and updates state
    function prove_integrity_of_claimYield(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares != 0);

        require(amount >= yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        uint256 _receiverShares = yieldStreaming.receiverShares(msg_sender);
        uint256 _receiverAssets = asset.balanceOf(_sendTo);
        uint256 _totalAssets = asset.balanceOf(address(this));
        uint256 _ownerShares = vault.balanceOf(address(this));
        uint256 _senderAllowance = vault.allowance(address(this), msg_sender);

        vm.prank(msg_sender);
        uint256 assets = yieldStreaming.claimYield(_sendTo);

        uint256 receiverShares_ = yieldStreaming.receiverShares(msg_sender);
        uint256 receiverAssets_ = asset.balanceOf(_sendTo);
        uint256 totalAssets_ = asset.balanceOf(address(this));
        uint256 ownerShares_ = vault.balanceOf(address(this));
        uint256 senderAllowance_ = vault.allowance(address(this), msg_sender);

        assert(_receiverShares  == receiverShares_ + yieldInShares);
        assert(_receiverAssets + assets == receiverAssets_);
        assert(_totalAssets - assets == totalAssets_);
        assert(_ownerShares - yieldInShares == ownerShares_);
        assert((msg_sender == address(this)) || 
            ((_senderAllowance == 2**256 -1 && senderAllowance_ == 2**256 -1) 
            || (_senderAllowance - yieldInShares == senderAllowance_)));
    }

    // Checks claimYieldInShares transfers correct share amount and updates state
    function prove_integrity_of_claimYieldInShares(address msg_sender, address _sendTo, uint256 amount) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        asset.mint(msg_sender, amount);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(shares != 0);

        uint256 _receiverShares = yieldStreaming.receiverShares(msg_sender);
        uint256 _balanceSender = asset.balanceOf(msg_sender);
        uint256 _balanceRecipient = asset.balanceOf(_sendTo);

        vm.prank(msg_sender);
        yieldStreaming.claimYieldInShares(_sendTo);

        uint256 receiverShares_ = yieldStreaming.receiverShares(msg_sender);

        assert(_receiverShares  == receiverShares_ + shares);
        assert(asset.balanceOf(msg_sender) <=  _balanceSender - shares);
        assert(asset.balanceOf(_sendTo) ==  _balanceRecipient + shares);
    }

    // ************************************ REVERTABLE PROPERTIES *************************************************

    // Checks that openYieldStream should revert when the msg.sender is the zero address
    function proveFail_openYieldStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares);
    }

    // Checks that openYieldStream should revert when the _receiver address parameter is the zero address
    function proveFail_openYieldStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares);
    }
    // Checks that openYieldStream should revert when the _shares amount parameter is 0 
    function proveFail_openYieldStream_When_Shares_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares);
    }

    // Checks that openYieldStream should revert when the _receiver address parameter is the same as the msg.sender
    function proveFail_openYieldStream_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver == msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares);
    }

    // Checks that openYieldStream should revert when the receiver has no existing debt
    function proveFail_openYieldStream_When_Debt_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _principal) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        //uint256 lossOnOpen = debt.mulDivUp(_principal, _receiverTotalPrincipal + _principal);
        //require(lossOnOpen <= _principal.mulWadUp(yieldStreaming.lossTolerancePercent())); // This is too costly for Z3

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares);
    }

    // Checks that openYieldStreamUsingPermit should revert when the msg.sender is the zero address
    function proveFail_openYieldStreamUsingPermit_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the zero address
    function proveFail_openYieldStreamUsingPermit_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _shares amount parameter is 0
    function proveFail_openYieldStreamUsingPermit_When_Shares_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the same as the msg.sender
    function proveFail_openYieldStreamUsingPermit_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the deadline parameter is less than the current block timestamp
    function proveFail_openYieldStreamUsingPermit_When_Deadline_Is_Less_Than_TimeStamp(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline < block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the vault allowance for the contract is less than the _shares amount
    function proveFail_openYieldStreamUsingPermit_When_Allowance_Is_Less_Than_Shares(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) < _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the receiver has no existing debt
    function proveFail_openYieldStreamUsingPermit_When_Debt_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt == 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, deadline, v, r, s);
    }

    // Checks that closeYieldStream should revert when the msg.sender is the zero address
    function proveFail_closeYieldStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        (, principal) = yieldStreaming._previewCloseYieldStream(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);
    }

    // Checks that closeYieldStream should revert when the _receiver address parameter is the zero address
    function proveFail_closeYieldStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        (, principal) = yieldStreaming._previewCloseYieldStream(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);
    }

    // Checks that closeYieldStream should revert when the _receiver address parameter is the same as the msg.sender
    function proveFail_closeYieldStream_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver == msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        (, principal) = yieldStreaming._previewCloseYieldStream(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);
    }

    // Checks that closeYieldStream should revert when previewCloseYieldStream returns 0 principal
    function proveFail_closeYieldStream_When_previewCloseYieldStream_Equals_Zero(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        (, principal) = yieldStreaming._previewCloseYieldStream(_receiver, msg_sender);
        require(principal == 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);
    }

    // Checks that claimYield should revert when the msg.sender is the zero address
    function proveFail_claimYield_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender == address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares != 0);

        require(amount >= yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        yieldStreaming.claimYield(_sendTo);

    }

    // Checks that claimYield should revert when the _sendTo address parameter is the zero address
    function proveFail_claimYield_When_sendTo_Equals_ZeroAddress(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender != address(0));
        require(_sendTo == address(0));
        require(_sendTo != msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares != 0);

        require(amount >= yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        yieldStreaming.claimYield(_sendTo);

    }

    // Checks that claimYield should revert when the _sendTo address parameter is the same as the msg.sender
    function proveFail_claimYield_When_sendTo_Equals_MSGSender(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo == msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares != 0);

        require(amount >= yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        yieldStreaming.claimYield(_sendTo);

    }

    // Checks that claimYield should revert when previewClaimYieldInShares returns 0 shares
    function proveFail_claimYield_When_previewClaimYieldInShares_Equals_Zero(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares == 0);

        require(amount >= yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        yieldStreaming.claimYield(_sendTo);

    }

    // Checks that claimYield should revert when the vault token balance is less than the yield share amount
    function proveFail_claimYield_When_amount_Is_Less_Than_To_previewClaimYieldInShares(address msg_sender, address _sendTo, uint256 amount, address account) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        vm.prank(msg_sender);
        uint256 yieldInShares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(yieldInShares != 0);

        require(amount < yieldInShares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        yieldStreaming.claimYield(_sendTo);

    }

    // Checks that claimYieldInShares should revert when the msg.sender is the zero address
    function proveFail_claimYieldInShares_MSGSender_Equals_ZeroAddress(address msg_sender, address _sendTo, uint256 amount) public {
        require(msg_sender == address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        asset.mint(msg_sender, amount);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(shares != 0);

        vm.prank(msg_sender);
        yieldStreaming.claimYieldInShares(_sendTo);
    }

    // Checks that claimYieldInShares should revert when the _sendTo address parameter is the zero address
    function proveFail_claimYieldInShares_sendTo_Equals_ZeroAddress(address msg_sender, address _sendTo, uint256 amount) public {
        require(msg_sender != address(0));
        require(_sendTo == address(0));
        require(_sendTo != msg_sender);

        asset.mint(msg_sender, amount);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(shares != 0);

        vm.prank(msg_sender);
        yieldStreaming.claimYieldInShares(_sendTo);
    }

    // Checks that claimYieldInShares should revert when the _sendTo address parameter is the same as the msg.sender
    function proveFail_claimYieldInShares_sendTo_Equals_MSGSender(address msg_sender, address _sendTo, uint256 amount) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo == msg_sender);

        asset.mint(msg_sender, amount);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(shares != 0);

        vm.prank(msg_sender);
        yieldStreaming.claimYieldInShares(_sendTo);
    }

    // Checks that claimYieldInShares should revert when previewClaimYieldInShares returns 0 shares
    function proveFail_claimYieldInShares_previewClaimYieldInShares_Equals_Zero(address msg_sender, address _sendTo, uint256 amount) public {
        require(msg_sender != address(0));
        require(_sendTo != address(0));
        require(_sendTo != msg_sender);

        asset.mint(msg_sender, amount);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.previewClaimYieldInShares(msg_sender);
        require(shares == 0);

        vm.prank(msg_sender);
        yieldStreaming.claimYieldInShares(_sendTo);
    }

}
