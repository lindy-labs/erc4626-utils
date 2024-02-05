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

contract ERC4626YieldStreaming_FV is Test {
    using FixedPointMathLib for uint256;

    YieldStreaming public yieldStreaming;
    MockERC4626 public vault;
    MockERC20 public asset;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        yieldStreaming = new YieldStreaming(address(this), IERC4626(address(vault)));
    }
    // *** constructor *** ///

    function proveFail_constructor_failsIfVaultIsAddress0() public {
        new YieldStreaming(address(this), IERC4626(address(0)));
    }

    function proveFail_constructor_failsIfOwnerIsAddress0() public {
        new YieldStreaming(address(0), IERC4626(address(vault)));
    }

    /// *** setLossTolerancePercent ***

    function proveFail_setLossTolerancePercent_failsIfCallerIsNotOwner(address caller) public {
        //require(caller != address(this));
        vm.prank(alice);
        yieldStreaming.setLossTolerancePercent(0);
    }

    function proveFail_setlossTolerancePercent_failsIfLossToleraceIsAboveMax(uint256 maxLossTolerance) public {
        require(maxLossTolerance > yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(maxLossTolerance);
    }

    function prove_setLossTolerancePercent_updatesLossTolerancePercentValue(uint256 maxLossTolerance) public {
        require(maxLossTolerance <= yieldStreaming.MAX_LOSS_TOLERANCE_PERCENT());
        yieldStreaming.setLossTolerancePercent(maxLossTolerance);

        assertEq(yieldStreaming.lossTolerancePercent(), maxLossTolerance);
    }


    // Proves that convertToShares is greater than or equal to previewDeposit
    function prove_convertToShares_gte_previewDeposit(address msg_sender, uint256 assets) public {
        require(msg_sender != address(this));
        vm.prank(msg_sender);
        assert(vault.convertToShares(assets) >= vault.previewDeposit(assets));
    }

    // Proves that convertToShares rounds down towards 0 
    function prove_converToShares_rounds_down_towards_0(address msg_sender, address account, uint256 amount, uint256 assets) public {
        require(msg_sender != address(this));
        require(msg_sender != account);
        require(account != address(0));
        require(amount != 0);

        vm.prank(msg_sender);
        vault.mint(amount, account);
        require(vault.totalSupply() != 0);
        assert((assets * vault.totalSupply()) / vault.totalAssets() == vault.convertToShares(assets));
    }

    // Proves that share price is maintained after minting new shares
    function prove_share_price_maintained_after_mint(address msg_sender, uint256 shares, address receiver) public {
        require(msg_sender != address(this));
        require(receiver != address(this));
        require(msg_sender != receiver);

        vm.prank(msg_sender);
        uint256 _totalAssets = vault.totalAssets();
        require((_totalAssets == 0 && vault.totalSupply() == 0) || (_totalAssets != 0 && vault.totalSupply() != 0));

        uint256 assets = vault.mint(shares, receiver);
        require(_totalAssets + assets <= asset.totalSupply()); // avoid overflow
    
        assert(assets == vault.previewMint(shares));
    }

    // Proves that convertToAssets is less than or equal to previewMint 
    function prove_convertToAssets_lte_previewMint(address msg_sender, uint256 shares) public {
        vm.prank(msg_sender);
        assert(vault.convertToAssets(shares) <= vault.previewMint(shares));
    }

    // Proves that convertToAssets rounds down towards 0
    function prove_convertToAssets_rounds_down_towards_0(address msg_sender, address account, uint256 amount, uint256 shares) public {
        vm.prank(msg_sender);
        vault.mint(amount, account);
        require(vault.totalSupply() != 0);
        assert((shares * vault.totalAssets()) / vault.totalSupply() == vault.convertToAssets(shares));
    }

    // Proves that maxDeposit returns the maximum value of the UINT256 type
    function prove_maxDeposit_returns_correct_value(address msg_sender,  address receiver) public {
        vm.prank(msg_sender);
        assert(vault.maxDeposit(receiver) == 2 ** 256 - 1);
    }

    // Proves that maxMint returns the the maximum value of the UINT256 type
    function prove_maxMint_returns_correct_value(address msg_sender, address receiver) public {
        vm.prank(msg_sender);
        assert(vault.maxMint(receiver) == 2 ** 256 - 1);
    }

    // Proves that previewDeposit is less than or equal to deposit
    function prove_previewDeposit_lte_deposit(address msg_sender, uint256 assets, address receiver) public {
        vm.prank(msg_sender);
        assert(vault.previewDeposit(assets) <= vault.deposit(assets, receiver));
    }

    // Proves that previewMint is greater than or equal to mint
    function prove_previewMint_gte_mint(address msg_sender, uint256 shares, address receiver) public {
        vm.prank(msg_sender);
        assert(vault.previewMint(shares) >= vault.mint(shares, receiver));
    }

    // Proves that previewWithdraw is greater than or equal to withdraw
    function prove_previewWithdraw_gte_withdraw(address msg_sender, uint256 assets, address receiver, address owner) public {
        vm.prank(msg_sender);
        assert(vault.previewWithdraw(assets) >= vault.withdraw(assets, receiver, owner));
    }

    // Proves that previewRedeem is less than or equal to redeem
    function prove_previewRedeem_lte_redeem(address msg_sender, uint256 shares, address receiver, address owner) public {
        vm.prank(msg_sender);
        assert(vault.previewRedeem(shares) <= vault.redeem(shares, receiver, owner));
    }

    // Proves the integrity of the deposit function
    function TooLongprove_integrity_of_deposit(address msg_sender, address account, uint256 amount, uint256 assets, address receiver) public {
        require(msg_sender != address(this));
        require(receiver != address(this));
        
        require(amount >= assets);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);
        uint256 _userAssets = asset.balanceOf(msg_sender);
        uint256 _totalAssets = asset.balanceOf(address(this));
        require(_totalAssets + assets <= asset.totalSupply());
        uint256 _receiverShares = vault.balanceOf(receiver);

        uint256 shares = vault.deposit(assets, receiver);

        require(_receiverShares + shares <= vault.totalSupply());

        vm.prank(msg_sender);
        uint256 userAssets_ = asset.balanceOf(msg_sender);
        uint256 totalAssets_ = asset.balanceOf(address(this));
        uint256 receiverShares_ = vault.balanceOf(receiver);

        assert(_userAssets - assets == userAssets_);
        assert(_receiverShares + shares == receiverShares_);
        assert(_totalAssets + assets == totalAssets_);
    }

    // Proves the integrity of the mint function
    function prove_integrity_of_mint(address msg_sender, address account, uint256 amount,uint256 shares, address receiver) public {
        require(msg_sender != address(this));
        require(receiver != address(this));

        require(amount >= shares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        vm.prank(msg_sender);

        uint256 _userAssets = asset.balanceOf(msg_sender);
        uint256 _totalAssets = asset.balanceOf(address(this));
        uint256 _receiverShares = vault.balanceOf(receiver);
        require(_receiverShares + shares <= vault.totalSupply());

        uint256 assets = vault.mint(shares, receiver);
        require(_totalAssets + assets <= asset.totalSupply());

        uint256 userAssets_ = asset.balanceOf(msg_sender);
        uint256 totalAssets_ = asset.balanceOf(address(this));
        uint256 receiverShares_ = vault.balanceOf(receiver);

        assert(_userAssets - assets == userAssets_);
        assert(_totalAssets + assets == totalAssets_);
        assert(_receiverShares + shares == receiverShares_);
    }

    // Proves the integrity of the withdraw function 
    function TooLongprove_integrity_of_withdraw(address msg_sender, address account, uint256 amount,uint256 assets, address receiver, address owner) public {
        require(msg_sender != address(this));
        require(receiver != address(this));
        require(msg_sender != owner);
        require(owner != address(this));
        require(owner != receiver);

        require(amount >= assets);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        uint256 _receiverAssets = asset.balanceOf(receiver);
        require(_receiverAssets + assets <= asset.totalSupply());
        uint256 _ownerShares = vault.balanceOf(owner);
        vm.prank(msg_sender);
        uint256 _senderAllowance = vault.allowance(owner, msg_sender);

        uint256 shares = vault.withdraw(assets, receiver, owner);

        uint256 receiverAssets_ = asset.balanceOf(receiver);
        uint256 ownerShares_ = vault.balanceOf(owner);
        vm.prank(msg_sender);
        uint256 senderAllowance_ = vault.allowance(owner, msg_sender);

        assert(_receiverAssets + assets == receiverAssets_);
        assert(_ownerShares - shares == ownerShares_);
        assert((_senderAllowance == 2 ** 256 -1 && senderAllowance_ == 2 ** 256 -1) 
            || (_senderAllowance - shares == senderAllowance_));
    }

    // Proves the integrity of the redeem function
    function TooLongprove_integrity_of_redeem(address msg_sender, address account, uint256 amount, uint256 shares, address receiver, address owner) public {
        require(msg_sender != address(this));
        require(receiver != address(this));

        require(amount >= shares);

        vm.prank(msg_sender);
        vault.mint(amount, account);

        uint256 _receiverAssets = asset.balanceOf(receiver);
        uint256 _totalAssets = asset.balanceOf(address(this));
        uint256 _ownerShares = vault.balanceOf(owner);
        uint256 _senderAllowance = vault.allowance(owner, msg_sender);

        uint256 assets = vault.redeem(shares, receiver, owner);
        require(_receiverAssets + assets <= asset.totalSupply());

        uint256 totalAssets_ = asset.balanceOf(address(this));
        uint256 receiverAssets_ = asset.balanceOf(receiver);
        uint256 ownerShares_ = vault.balanceOf(owner);
        uint256 senderAllowance_ = vault.allowance(owner, msg_sender);

        assert(_totalAssets - assets == totalAssets_);
        assert(_receiverAssets + assets == receiverAssets_);
        assert(_ownerShares - shares == ownerShares_);
        assert((msg_sender == owner) || 
            ((_senderAllowance == 2**256 -1 && senderAllowance_ == 2**256 -1) 
            || (_senderAllowance - shares == senderAllowance_)));
    }

}
