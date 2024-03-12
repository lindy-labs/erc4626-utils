// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
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

    struct Deposit {
        uint256 shares;
        uint256 principal;
        uint256 epoch;
    }

    struct EpochInfo {
        uint256 yieldSpent;
        uint256 dcaPrice;
        uint256 pricePerShare;
    }

    error DcaIntervalNotPassed();
    error DcaZeroYield();

    uint256 public constant DCA_INTERVAL = 2 weeks;

    IERC20 public dcaToken;
    IERC4626 public vault;
    ISwapper public swapper;

    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;
    uint256 public totalPrincipalDeposited;
    mapping(address => Deposit) public deposits;
    mapping(uint256 => EpochInfo) public epochDetails;

    constructor(IERC20 _dcaToken, IERC4626 _vault, ISwapper _swapper) {
        dcaToken = _dcaToken;
        vault = _vault;
        swapper = _swapper;

        // approve swapper to spend deposits on DCA token
        IERC20(vault.asset()).approve(address(swapper), type(uint256).max);
    }

    function deposit(uint256 _shares) external {
        uint256 principal = vault.convertToAssets(_shares);

        Deposit storage position = deposits[msg.sender];

        // check if user has already deposited in the past
        if (position.epoch != 0 && position.epoch < currentEpoch) {
            (uint256 shares, uint256 dcaTokens) = _calculateBalances(position);
            position.shares = shares;

            // TODO: this could be unnecessary
            if (dcaTokens != 0) {
                dcaToken.safeTransfer(msg.sender, dcaTokens);
            }
        }

        position.shares += _shares;
        position.principal += principal;
        position.epoch = currentEpoch;

        totalPrincipalDeposited += principal;

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        // TODO: emit event
    }

    function executeDCA() external {
        if (block.timestamp < currentEpochTimestamp + DCA_INTERVAL) revert DcaIntervalNotPassed();

        uint256 yieldInShares = calculateCurrentYieldInShares();

        if (yieldInShares == 0) revert DcaZeroYield();

        uint256 yield = vault.redeem(yieldInShares, address(this), address(this));
        // TODO: use asset.balanceOf here instead of yield?

        uint256 tokensBought = _buyDcaToken(yield);

        uint256 tokenPrice = tokensBought.divWadDown(yield);
        uint256 realizedPricePerShare = yield.divWadDown(yieldInShares);

        epochDetails[currentEpoch] =
            EpochInfo({yieldSpent: yield, dcaPrice: tokenPrice, pricePerShare: realizedPricePerShare});

        currentEpoch++;
        currentEpochTimestamp = block.timestamp;

        // TODO: emit event
    }

    function calculateCurrentYieldInShares() public view returns (uint256) {
        uint256 balance = vault.balanceOf(address(this));
        uint256 totalPrincipalInShares = vault.convertToShares(totalPrincipalDeposited);

        return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
    }

    // NOTE: uses around 300k gas iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    function withdraw() external {
        Deposit memory user = deposits[msg.sender];
        // TODO: reconsider this to allow withdrawing in the same epoch as deposit
        require(user.epoch < currentEpoch, "Cannot withdraw in the same epoch");

        (uint256 sharesRemaining, uint256 dcaAmount) = _calculateBalances(user);

        // withdraw remaining shares
        if (sharesRemaining > vault.balanceOf(address(this))) {
            sharesRemaining = vault.balanceOf(address(this));
        }

        vault.safeTransfer(msg.sender, sharesRemaining);

        if (dcaAmount > dcaToken.balanceOf(address(this))) {
            dcaAmount = dcaToken.balanceOf(address(this));
        }

        dcaToken.safeTransfer(msg.sender, dcaAmount);

        // update
        totalPrincipalDeposited -= user.principal;

        // update user position
        delete deposits[msg.sender];

        // TODO: emit event
    }

    function _buyDcaToken(uint256 _amountIn) private returns (uint256 amountOut) {
        uint256 balanceBefore = dcaToken.balanceOf(address(this));
        uint256 amountOutMin = 0;

        // TODO: handle slippage somehow
        amountOut = swapper.execute(vault.asset(), address(dcaToken), _amountIn, amountOutMin);

        require(
            dcaToken.balanceOf(address(this)) >= balanceBefore + amountOut, "received less DCA tokens than expected"
        );
    }

    function balanceOf(address _user) public view returns (uint256 shares, uint256 dcaTokens) {
        return _calculateBalances(deposits[_user]);
    }

    function _calculateBalances(Deposit memory _deposit) internal view returns (uint256 shares, uint256 dcaTokens) {
        if (_deposit.epoch == 0) return (0, 0);

        shares = _deposit.shares;

        for (uint256 i = _deposit.epoch; i < currentEpoch; i++) {
            EpochInfo memory epoch = epochDetails[i];

            if (epoch.yieldSpent == 0) continue;

            uint256 sharesValue = shares.mulWadDown(epoch.pricePerShare);

            if (sharesValue <= _deposit.principal) continue;

            uint256 usersYield = sharesValue - _deposit.principal;
            uint256 sharesSpent = usersYield.divWadDown(epoch.pricePerShare);

            shares -= sharesSpent;
            dcaTokens += usersYield.mulWadDown(epoch.dcaPrice);
        }
    }
}
