// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";

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
contract YieldDCA is AccessControl {
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
        uint256 dcaPrice;
        uint256 sharePrice;
    }

    error DcaTokenAddressZero();
    error VaultAddressZero();
    error SwapperAddressZero();
    error DcaTokenSameAsVaultAsset();
    error DcaIntervalNotAllowed();
    error KeeperAddressZero();
    error AdminAddressZero();

    error DcaIntervalNotPassed();
    error DcaYieldZero();
    error NoDepositFound();
    error NoPrincipalDeposited();
    error DcaAmountReceivedTooLow();
    error InsufficientSharesToWithdraw();

    event DCAIntervalUpdated(address indexed admin, uint256 newInterval);
    event SwapperUpdated(address indexed admin, address newSwapper);
    event Deposit(address indexed user, uint256 epoch, uint256 shares, uint256 principal);
    event Withdraw(address indexed user, uint256 epoch, uint256 principal, uint256 shares, uint256 dcaTokens);
    event DCAExecuted(uint256 epoch, uint256 yieldSpent, uint256 dcaBought, uint256 dcaPrice, uint256 sharePrice);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant MIN_DCA_INTERVAL = 2 weeks;
    uint256 public constant MAX_DCA_INTERVAL = 10 weeks;

    IERC20 public immutable dcaToken;
    IERC4626 public immutable vault;
    ISwapper public swapper;

    uint256 public dcaInterval = 2 weeks;
    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;
    uint256 public totalPrincipalDeposited;

    mapping(address => DepositInfo) public deposits;
    mapping(uint256 => EpochInfo) public epochDetails;

    constructor(
        IERC20 _dcaToken,
        IERC4626 _vault,
        ISwapper _swapper,
        uint256 _dcaInterval,
        address _admin,
        address _keeper
    ) {
        if (address(_dcaToken) == address(0)) revert DcaTokenAddressZero();
        if (address(_vault) == address(0)) revert VaultAddressZero();
        if (address(_dcaToken) == _vault.asset()) revert DcaTokenSameAsVaultAsset();
        if (address(_swapper) == address(0)) revert SwapperAddressZero();
        if (_admin == address(0)) revert AdminAddressZero();
        if (_keeper == address(0)) revert KeeperAddressZero();

        dcaToken = _dcaToken;
        vault = _vault;
        swapper = _swapper;

        _setDcaInterval(_dcaInterval);

        IERC20(vault.asset()).forceApprove(address(_swapper), type(uint256).max);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
    }

    function setSwapper(ISwapper _swapper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSwapper(_swapper);

        emit SwapperUpdated(msg.sender, address(_swapper));
    }

    function _setSwapper(ISwapper _swapper) internal {
        if (address(_swapper) == address(0)) revert SwapperAddressZero();

        // revoke previous swapper's approval and approve new swapper
        IERC20 asset = IERC20(vault.asset());
        asset.forceApprove(address(swapper), 0);
        asset.forceApprove(address(_swapper), type(uint256).max);

        swapper = _swapper;
    }

    function setDcaInterval(uint256 _interval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDcaInterval(_interval);

        emit DCAIntervalUpdated(msg.sender, _interval);

        dcaInterval = _interval;
    }

    function _setDcaInterval(uint256 _interval) internal {
        if (_interval < MIN_DCA_INTERVAL || _interval > MAX_DCA_INTERVAL) revert DcaIntervalNotAllowed();

        dcaInterval = _interval;
    }

    function deposit(uint256 _shares) external {
        DepositInfo storage deposit_ = deposits[msg.sender];

        // check if the user has made a deposit previously
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

    function executeDCA(uint256 _dcaAmountOutMin, bytes calldata _swapData) external onlyRole(KEEPER_ROLE) {
        if (totalPrincipalDeposited == 0) revert NoPrincipalDeposited();
        if (block.timestamp < currentEpochTimestamp + dcaInterval) revert DcaIntervalNotPassed();

        uint256 yieldInShares = calculateCurrentYieldInShares();

        // this check will also prevent reentrancy when calling sapper.execute
        if (yieldInShares == 0) revert DcaYieldZero();

        vault.redeem(yieldInShares, address(this), address(this));

        uint256 yield = IERC20(vault.asset()).balanceOf(address(this));
        uint256 amountOut = _buyDcaToken(yield, _dcaAmountOutMin, _swapData);
        uint256 dcaPrice = amountOut.divWadDown(yield);
        uint256 sharePrice = yield.divWadDown(yieldInShares);

        epochDetails[currentEpoch] = EpochInfo({dcaPrice: dcaPrice, sharePrice: sharePrice});

        currentEpoch++;
        currentEpochTimestamp = block.timestamp;

        emit DCAExecuted(currentEpoch - 1, yield, amountOut, dcaPrice, sharePrice);
    }

    // if 0 is passed only dca is withdrawn
    // NOTE: uses around 1073k gas while iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    function withdraw(uint256 _shares) external returns (uint256 principal, uint256 dcaAmount) {
        DepositInfo storage deposit_ = deposits[msg.sender];

        if (deposit_.epoch == 0) revert NoDepositFound();

        uint256 sharesRemaining;
        (sharesRemaining, dcaAmount) = _calculateBalances(deposit_);

        if (_shares > sharesRemaining) revert InsufficientSharesToWithdraw();

        principal = deposit_.principal.mulDivDown(_shares, sharesRemaining);

        totalPrincipalDeposited -= principal;

        if (_shares == sharesRemaining) {
            // withadraw all
            delete deposits[msg.sender];
        } else {
            // withdraw partial
            deposit_.principal -= principal;
            deposit_.shares = sharesRemaining - _shares;
            deposit_.dcaAmountAtEpoch = 0;
            deposit_.epoch = currentEpoch;
        }

        uint256 sharesBalance = vault.balanceOf(address(this));
        // limit to available shares and dca tokens because of possible rounding errors
        _shares = _shares > sharesBalance ? sharesBalance : _shares;
        vault.safeTransfer(msg.sender, _shares);

        uint256 dcaBalance = dcaToken.balanceOf(address(this));
        dcaAmount = dcaAmount > dcaBalance ? dcaBalance : dcaAmount;
        dcaToken.safeTransfer(msg.sender, dcaAmount);

        emit Withdraw(msg.sender, currentEpoch, principal, _shares, dcaAmount);
    }

    function balanceOf(address _user) public view returns (uint256 shares, uint256 dcaTokens) {
        (shares, dcaTokens) = _calculateBalances(deposits[_user]);
    }

    function calculateCurrentYield() public view returns (uint256) {
        uint256 assets = vault.convertToAssets(vault.balanceOf(address(this)));

        return assets > totalPrincipalDeposited ? assets - totalPrincipalDeposited : 0;
    }

    function calculateCurrentYieldInShares() public view returns (uint256) {
        uint256 balance = vault.balanceOf(address(this));
        uint256 totalPrincipalInShares = vault.convertToShares(totalPrincipalDeposited);

        return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
    }

    function _buyDcaToken(uint256 _amountIn, uint256 _dcaAmountOutMin, bytes calldata _swapData)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = dcaToken.balanceOf(address(this));

        swapper.execute(vault.asset(), address(dcaToken), _amountIn, _dcaAmountOutMin, _swapData);

        uint256 balanceAfter = dcaToken.balanceOf(address(this));

        if (dcaToken.balanceOf(address(this)) < balanceBefore + _dcaAmountOutMin) revert DcaAmountReceivedTooLow();

        return balanceAfter - balanceBefore;
    }

    function _calculateBalances(DepositInfo memory _deposit)
        internal
        view
        returns (uint256 shares, uint256 dcaTokens)
    {
        if (_deposit.epoch == 0) return (0, 0);

        shares = _deposit.shares;
        dcaTokens = _deposit.dcaAmountAtEpoch;

        // NOTE: one iteration costs around 4900 gas when called from a non-view function compared to 1000 gas when called from a view function
        for (uint256 i = _deposit.epoch; i < currentEpoch; i++) {
            EpochInfo memory epoch = epochDetails[i];

            unchecked {
                // use plain arithmetic instead of FixedPointMathLib to lower gas costs
                // since we are only working with yield, it is not realistic to expect values large enough to overflow on multiplication
                uint256 sharesValue = shares * epoch.sharePrice / 1e18;

                if (sharesValue <= _deposit.principal) continue;

                // cannot underflow because of the check above
                uint256 usersYield = sharesValue - _deposit.principal;

                shares -= usersYield * 1e18 / epoch.sharePrice;
                dcaTokens += usersYield * epoch.dcaPrice / 1e18;
            }
        }
    }
}
