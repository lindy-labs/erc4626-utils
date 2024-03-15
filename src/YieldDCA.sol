// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";

import {ISwapper} from "./ISwapper.sol";

/**
 * @title YieldDCA
 * @dev This contract implements a Dollar Cost Averaging (DCA) strategy by utilizing yield generated from deposited ERC4626 tokens over fixed periods (epochs).
 * The contract calculates the yield generated from the total principal deposited in every epoch, and sells the yield for a specified DCA token via the swapper contract.
 * Distribution of the purchased DCA tokens among participants is based on their share of the total yield generated in each epoch.
 *
 * The contract tracks each user's deposit (in terms of shares of the vault and principal amount) and the epoch when the deposit was made.
 * When users decide to withdraw, they receive their share of the DCA tokens bought during the epochs their deposit was active, adjusted for any yield generated on their principal.
 *
 * Key functionalities include:
 * - Allowing users to deposit assets into a vault and participate in the DCA strategy.
 * - Automatic progression through epochs, with the contract executing the DCA strategy by selling generated yield for DCA tokens at the end of each epoch.
 * - Calculation of users' shares of DCA tokens based on the yield generated from their deposited principal.
 * - Providing a mechanism for users to withdraw their original deposit and their share of DCA tokens generated from yields.
 *
 * This contract requires external integration with a vault (IERC4626 for asset management), a token to DCA into (IERC20), and a swapper contract for executing trades.
 * It is designed for efficiency and scalability, with considerations for gas optimization and handling a large number of epochs and user deposits.
 */
contract YieldDCA {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;
    using SafeERC20 for IERC20;

    struct DepositInfo {
        uint256 shares;
        uint256 principal;
        uint256 epoch;
        uint256 dcaAmountAtEpoch;
    }

    struct EpochInfo {
        uint256 yieldSpent;
        uint256 dcaPrice;
        uint256 pricePerShare;
    }

    error DcaIntervalNotPassed();
    error DcaYieldZero();
    error NoDepositFound();
    error InsufficientSharesToWithdraw();

    event Deposit(address indexed user, uint256 epoch, uint256 shares, uint256 principal);
    event Withdraw(address indexed user, uint256 epoch, uint256 principal, uint256 shares, uint256 dcaTokens);
    event DCAExecuted(uint256 epoch, uint256 yieldSpent, uint256 dcaBought, uint256 dcaPrice, uint256 sharePrice);

    // TODO: make this configurable?
    uint256 public constant DCA_INTERVAL = 2 weeks;

    IERC20 public dcaToken;
    IERC4626 public vault;
    ISwapper public swapper;

    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;
    uint256 public totalPrincipalDeposited;
    mapping(address => DepositInfo) public deposits;
    mapping(uint256 => EpochInfo) public epochDetails;

    constructor(IERC20 _dcaToken, IERC4626 _vault, ISwapper _swapper) {
        dcaToken = _dcaToken;
        vault = _vault;
        swapper = _swapper;

        // approve swapper to spend deposits on DCA token
        IERC20(vault.asset()).approve(address(swapper), type(uint256).max);
        // TODO: make sure dca token and underlying asset are not the same
    }

    function deposit(uint256 _shares) external {
        DepositInfo storage deposit_ = deposits[msg.sender];

        // check if user has already deposited in the past
        if (deposit_.epoch != 0 && deposit_.epoch < currentEpoch) {
            (uint256 shares, uint256 dcaTokens) = _calculateBalances(deposit_);

            deposit_.shares = shares;
            deposit_.dcaAmountAtEpoch = dcaTokens;
        }

        uint256 principal = vault.convertToAssets(_shares);

        deposit_.shares += _shares;
        deposit_.principal += principal;
        deposit_.epoch = currentEpoch;

        totalPrincipalDeposited += principal;

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit Deposit(msg.sender, currentEpoch, _shares, principal);
    }

    // TODO: pass amount out min here?
    function executeDCA() external {
        if (block.timestamp < currentEpochTimestamp + DCA_INTERVAL) revert DcaIntervalNotPassed();

        uint256 yieldInShares = calculateCurrentYieldInShares();

        if (yieldInShares == 0) revert DcaYieldZero();

        uint256 yield = vault.redeem(yieldInShares, address(this), address(this));
        // TODO: use asset.balanceOf here instead of yield?

        uint256 tokensBought = _buyDcaToken(yield);

        uint256 tokenPrice = tokensBought.divWadDown(yield);
        uint256 sharePrice = yield.divWadDown(yieldInShares);

        epochDetails[currentEpoch] = EpochInfo({yieldSpent: yield, dcaPrice: tokenPrice, pricePerShare: sharePrice});

        currentEpoch++;
        currentEpochTimestamp = block.timestamp;

        emit DCAExecuted(currentEpoch - 1, yield, tokensBought, tokenPrice, sharePrice);
    }

    // if 0 is passed only dca is withdrawn
    // TODO: return values?
    // NOTE: uses around 300k gas iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    function withdraw(uint256 _shares) external returns (uint256 principal, uint256 dcaTokens) {
        DepositInfo storage deposit_ = deposits[msg.sender];

        if (deposit_.epoch == 0) revert NoDepositFound();

        (uint256 sharesRemaining, uint256 dcaAmount) = _calculateBalances(deposit_);

        if (_shares > sharesRemaining) revert InsufficientSharesToWithdraw();

        uint256 sharesBalance = vault.balanceOf(address(this));
        uint256 dcaBalance = dcaToken.balanceOf(address(this));

        uint256 principalRemoved = deposit_.principal.mulDivDown(_shares, sharesRemaining);
        if (_shares == sharesRemaining) {
            // withadraw all
            totalPrincipalDeposited -= principalRemoved;

            delete deposits[msg.sender];
        } else {
            // withdraw partial
            deposit_.principal -= principalRemoved;
            deposit_.shares = sharesRemaining - _shares;
            deposit_.dcaAmountAtEpoch = 0;
            deposit_.epoch = currentEpoch;

            totalPrincipalDeposited -= principalRemoved;
        }

        // limit to available shares and dca tokens because of possible rounding errors
        _shares = _shares > sharesBalance ? sharesBalance : _shares;
        vault.safeTransfer(msg.sender, _shares);

        dcaAmount = dcaAmount > dcaBalance ? dcaBalance : dcaAmount;
        dcaToken.safeTransfer(msg.sender, dcaAmount);

        emit Withdraw(msg.sender, currentEpoch, principalRemoved, _shares, dcaAmount);

        return (principalRemoved, dcaAmount);
    }

    function balanceOf(address _user) public view returns (uint256 shares, uint256 dcaTokens) {
        return _calculateBalances(deposits[_user]);
    }

    function calculateCurrentYieldInShares() public view returns (uint256) {
        uint256 balance = vault.balanceOf(address(this));
        uint256 totalPrincipalInShares = vault.convertToShares(totalPrincipalDeposited);

        return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
    }

    function _buyDcaToken(uint256 _amountIn) internal returns (uint256 amountOut) {
        uint256 balanceBefore = dcaToken.balanceOf(address(this));
        uint256 amountOutMin = 0;

        // TODO: handle slippage somehow
        // TODO: use delegate call
        amountOut = swapper.execute(vault.asset(), address(dcaToken), _amountIn, amountOutMin);

        require(
            dcaToken.balanceOf(address(this)) >= balanceBefore + amountOut, "received less DCA tokens than expected"
        );
    }

    function _calculateBalances(DepositInfo memory _deposit)
        internal
        view
        returns (uint256 shares, uint256 dcaTokens)
    {
        if (_deposit.epoch == 0) return (0, 0);

        shares = _deposit.shares;
        dcaTokens = _deposit.dcaAmountAtEpoch;

        for (uint256 i = _deposit.epoch; i < currentEpoch; i++) {
            EpochInfo memory epoch = epochDetails[i];

            uint256 sharesValue = shares.mulWadDown(epoch.pricePerShare);

            if (sharesValue <= _deposit.principal) continue;

            uint256 usersYield = sharesValue - _deposit.principal;
            uint256 sharesSpent = usersYield.divWadDown(epoch.pricePerShare);

            // since we are only working with yield, `sharesSpent` is never greater than `shares` (ie. principal)
            unchecked {
                shares -= sharesSpent;
                dcaTokens += usersYield.mulWadDown(epoch.dcaPrice);
            }
        }
    }
}
