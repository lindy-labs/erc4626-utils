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
        yieldStreaming = new YieldStreaming(IERC4626(address(vault)));
    }

    // Symbolic test checking that openYieldStream updates receiver state properly
    function prove_integrity_of_openYieldStream(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
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
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + _shares == receiverShares_);
        assert(_receiverTotalPrincipal + principal == receiverTotalPrincipal_);
        assert(_receiverPrincipal + principal == receiverPrincipal_);
    }

    // Symbolic test checking openYieldStreamUsingPermit updates receiver state properly
    function prove_integrity_of_openYieldStreamUsingPermit(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
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
        uint256 principal = yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + _shares == receiverShares_);
        assert(_receiverTotalPrincipal + principal == receiverTotalPrincipal_);
        assert(_receiverPrincipal + principal == receiverPrincipal_);
    }

    // Symbolic test checking depositAndOpenYieldStream updates receiver state properly
    function prove_integrity_depositAndOpenYieldStream(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 _receiverPrincipal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + principal == receiverShares_);
        assert(_receiverTotalPrincipal + _amount == receiverTotalPrincipal_);
        assert(_receiverPrincipal + _amount == receiverPrincipal_);
    }

    // Symbolic test checking depositAndOpenYieldStreamUsingPermit updates receiver state properly
    function prove_integrity_depositAndOpenYieldStreamUsingPermit(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 _receiverPrincipal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares + principal == receiverShares_);
        assert(_receiverTotalPrincipal + _amount == receiverTotalPrincipal_);
        assert(_receiverPrincipal + _amount == receiverPrincipal_);
    }

    // Checks closeYieldStream updates receiver state properly
    function prove_integrity_of_closeYieldStream(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
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

    // Checks that opening and closing the same yield stream does not change shares and total principal (they are complementary operations)
    function prove_open_And_Close_YieldStream(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares == receiverShares_);
        assert(_receiverTotalPrincipal == receiverTotalPrincipal_);
        assert(receiverPrincipal_ == 0);
    }
    
    // Checks closeYieldStreamAndWithdraw updates receiver state properly
    function prove_integrity_closeYieldStreamAndWithdraw(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
        require(principal != 0);
        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);

        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.closeYieldStreamAndWithdraw(_receiver);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares == receiverShares_ + shares);
        assert(_receiverTotalPrincipal == receiverTotalPrincipal_ + principal);
        assert(receiverPrincipal_ == 0);
    }

    // Checks that deposit and opening and closing with withdraw the same yield stream does not change shares and total principal (they are complementary operations)
    function prove_integrity_depositAndOpen_And_closeYieldStream_And_Withdraw(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 _receiverShares = yieldStreaming.receiverShares(_receiver);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 _receiverPrincipal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
        vm.prank(msg_sender);
        uint256 shares = yieldStreaming.closeYieldStreamAndWithdraw(_receiver);

        uint256 receiverShares_ = yieldStreaming.receiverShares(_receiver);
        uint256 receiverTotalPrincipal_ = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 receiverPrincipal_ = yieldStreaming.receiverPrincipal(_receiver, msg_sender);

        assert(_receiverShares == receiverShares_);
        assert(_receiverTotalPrincipal == receiverTotalPrincipal_);
        assert(0 == receiverPrincipal_);
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

    // Checks that constructing YieldStreaming with a zero vault address reverts
    function proveFail_constructor_failsIfVaultIsAddress0() public {
        new YieldStreaming(IERC4626(address(0)));
    }

    // Checks that openYieldStream should revert when the msg.sender is the zero address
    function proveFail_openYieldStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldStream should revert when the _receiver address parameter is the zero address
    function proveFail_openYieldStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }
    // Checks that openYieldStream should revert when the _shares amount parameter is 0 
    function proveFail_openYieldStream_When_Shares_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldStream should revert when the _receiver address parameter is the same as the msg.sender
    function proveFail_openYieldStream_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver == msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldStream should revert when the receiver has no existing debt
    function proveFail_openYieldStream_When_Debt_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);
        uint256 _receiverTotalPrincipal = yieldStreaming.receiverTotalPrincipal(_receiver);
        uint256 principal = vault.convertToAssets(_shares);
        uint256 lossOnOpen = debt.mulDivUp(principal, _receiverTotalPrincipal + principal);
        require(lossOnOpen <= principal.mulWadUp(_maxLossOnOpenTolerancePercent));

        vm.prank(msg_sender);
        yieldStreaming.openYieldStream(_receiver, _shares, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldStreamUsingPermit should revert when the msg.sender is the zero address
    function proveFail_openYieldStreamUsingPermit_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the zero address
    function proveFail_openYieldStreamUsingPermit_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _shares amount parameter is 0
    function proveFail_openYieldStreamUsingPermit_When_Shares_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares == 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the _receiver address parameter is the same as the msg.sender
    function proveFail_openYieldStreamUsingPermit_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the deadline parameter is less than the current block timestamp
    function proveFail_openYieldStreamUsingPermit_When_Deadline_Is_Less_Than_TimeStamp(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline < block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the vault allowance for the contract is less than the _shares amount
    function proveFail_openYieldStreamUsingPermit_When_Allowance_Is_Less_Than_Shares(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) < _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt != 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldStreamUsingPermit should revert when the receiver has no existing debt
    function proveFail_openYieldStreamUsingPermit_When_Debt_Equals_Zero(address msg_sender, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_shares != 0);
        require(_receiver != msg_sender);
        require(deadline >= block.timestamp);
        require(vault.allowance(msg_sender, address(this)) >= _shares);
        uint256 debt = yieldStreaming.debtFor(_receiver);
        require(debt == 0);

        vm.prank(msg_sender);
        yieldStreaming.openYieldStreamUsingPermit(_receiver, _shares, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the msg.sender is the zero address
    function proveFail_depositAndOpenYieldStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the _receiver is the zero address
    function proveFail_depositAndOpenYieldStream_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the msg.sender equals _receiver
    function proveFail_depositAndOpenYieldStream_When_Receiver_Equals_MSGSender(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver == msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the _amount equals zero
    function proveFail_depositAndOpenYieldStream_When_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when the allowance is less than _amount
    function proveFail_depositAndOpenYieldStream_When_Allowance_Is_Less_Than_Amount(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) < _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that openYieldSdepositAndOpenYieldStreamtream should revert when principal equals zero
    function proveFail_depositAndOpenYieldStream_When_Principal_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal == 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStream(_receiver, _amount, _maxLossOnOpenTolerancePercent);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when msg.sender equals the zero address
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when _receiver equals the zero address
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when msg.sender equals _receiver
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver == msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when _amount equals zero
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_Amount_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount == 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when allowance is less than _amount
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_Allowance_Is_Less_Than_Amount(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) < _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that depositAndOpenYieldStreamUsingPermit should revert when principal equals zero
    function proveFail_depositAndOpenYieldStreamUsingPermit_When_Principal_Equals_Zero(address msg_sender, address _receiver, uint256 _amount, uint256 _maxLossOnOpenTolerancePercent, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_amount != 0);
        require(_receiver != msg_sender);
        require(vault.allowance(msg_sender, address(this)) >= _amount);

        uint256 principal = vault.previewDeposit(_amount);
        require(principal == 0);

        vm.prank(msg_sender);
        yieldStreaming.depositAndOpenYieldStreamUsingPermit(_receiver, _amount, _maxLossOnOpenTolerancePercent, deadline, v, r, s);
    }

    // Checks that closeYieldStream should revert when the msg.sender is the zero address
    function proveFail_closeYieldStream_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
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
        principal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
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
        principal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
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
        principal = yieldStreaming.receiverPrincipal(_receiver,msg_sender);
        require(principal == 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStream(_receiver);
    }

    // Checks that closeYieldStreamAndWithdraw should revert when msg.sender equals the zero address
    function proveFail_closeYieldStreamAndWithdraw_When_MSGSender_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender == address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStreamAndWithdraw(_receiver);
    }

    // Checks that closeYieldStreamAndWithdraw should revert when _receiver equals the zero address
    function proveFail_closeYieldStreamAndWithdraw_When_Receiver_Equals_ZeroAddress(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver == address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStreamAndWithdraw(_receiver);
    }

    // Checks that closeYieldStreamAndWithdraw should revert when msg.sender equals _receiver
    function proveFail_closeYieldStreamAndWithdraw_When_MSGSender_Equals_Receiver(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver == msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
        require(principal != 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStreamAndWithdraw(_receiver);
    }

    // Checks that closeYieldStreamAndWithdraw should revert when principal equals zero
    function proveFail_closeYieldStreamAndWithdraw_When_Principal_Equals_Zero(address msg_sender, address _receiver) public {
        require(msg_sender != address(0));
        require(_receiver != address(0));
        require(_receiver != msg_sender);

        uint256 principal;
        vm.prank(msg_sender);
        principal = yieldStreaming.receiverPrincipal(_receiver, msg_sender);
        require(principal == 0);

        vm.prank(msg_sender);
        yieldStreaming.closeYieldStreamAndWithdraw(_receiver);
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
