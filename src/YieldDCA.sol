// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {AmountZero} from "./common/Errors.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/**
 * @title YieldDCA
 * @notice Implements a Dollar Cost Averaging (DCA) strategy using yield from ERC4626 vault assets
 * @dev This contract deploys a strategy that automatically executes DCA by converting yield generated from assets deposited in an ERC4626 vault into a specified ERC20 DCA token.
 * The DCA execution is scheduled in defined time periods known as epochs.
 * The contract manages the periodic sale of accumulated yield for the DCA token at the end of each epoch using a designated swapper contract.
 * It handles user deposits, each represented as an ERC721 token, and tracks the accrual of DCA tokens per deposit based on the yield generated.
 *
 * Key features include:
 * - Depositing and withdrawing shares from a specified ERC4626 vault.
 * - Automatic conversion of yield to DCA tokens at fixed intervals (epochs).
 * - Tracking of individual deposits and allocation of DCA tokens based on the yield generated from those deposits during active epochs.
 * - Configurable settings for the duration of epochs, minimum yield required per epoch to trigger the DCA.
 *
 * The contract uses roles for administration and operation, specifically distinguishing between default admin and keeper roles for enhanced security. Each role is empowered to perform specific functions, such as adjusting operational parameters or executing the DCA strategy.
 *
 * It requires external integrations with:
 * - An ERC4626-compliant vault for managing the underlying asset.
 * - An ERC20 token to act as the DCA target.
 * - A swapper contract to facilitate the exchange of assets.
 *
 * The implementation focuses on optimizing gas costs and ensuring security through rigorous checks and balances, while accommodating a scalable number of epochs and user deposits.
 */
contract YieldDCA is ERC721, AccessControl {
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
        // using uint128s to pack variables and save on sstore/sload since both values are always written/read together
        // dcaPrice and sharePrice are in WAD and represent the result of dividing two uint256s
        // using uint128s instead of uint256s can only lead to some insignificant precision loss in balances calculation
        uint128 dcaPrice;
        uint128 sharePrice;
    }

    error DCATokenAddressZero();
    error VaultAddressZero();
    error SwapperAddressZero();
    error DCATokenSameAsVaultAsset();
    error InvalidDCAInterval();
    error KeeperAddressZero();
    error AdminAddressZero();
    error InvalidMinYieldPerEpoch();

    error MinEpochDurationNotReached();
    error InsufficientYield();
    error YieldZero();
    error NoPrincipalDeposited();
    error AmountReceivedTooLow();
    error InsufficientSharesToWithdraw();
    error CallerNotTokenOwner();

    event DCAIntervalUpdated(address indexed admin, uint256 newInterval);
    event MinYieldPerEpochUpdated(address indexed admin, uint256 newMinYield);
    event SwapperUpdated(address indexed admin, address newSwapper);
    event Deposit(address indexed user, uint256 indexed depositId, uint256 epoch, uint256 shares, uint256 principal);
    event Withdraw(address indexed user, uint256 epoch, uint256 principal, uint256 shares, uint256 dcaTokens);
    event DCAExecuted(uint256 epoch, uint256 yieldSpent, uint256 dcaBought, uint256 dcaPrice, uint256 sharePrice);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant MIN_DCA_INTERVAL_LOWER_BOUND = 1 weeks;
    uint256 public constant MIN_DCA_INTERVAL_UPPER_BOUND = 10 weeks;
    uint256 public constant MIN_YIELD_PER_EPOCH_LOWER_BOUND = 0.0001e18; // 0.01%
    uint256 public constant MIN_YIELD_PER_EPOCH_UPPER_BOUND = 0.01e18; // 1%

    IERC20 public immutable dcaToken;
    IERC4626 public immutable vault;
    ISwapper public swapper;

    /// @dev The minimum interval between executing the DCA strategy (epoch duration)
    uint256 public minEpochDuration = 2 weeks;
    /// @dev The minimum yield required to execute the DCA strategy in an epoch
    uint256 public minYieldPerEpoch = 0.001e18; // 0.1%
    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;

    mapping(uint256 => EpochInfo) public epochDetails;

    uint256 public nextDepositId = 1;
    uint256 public totalPrincipalDeposited;
    mapping(uint256 => DepositInfo) public deposits;

    constructor(
        IERC20 _dcaToken,
        IERC4626 _vault,
        ISwapper _swapper,
        uint256 _minEpochDuration,
        address _admin,
        address _keeper
    ) ERC721("YieldDCA", "YDCA") {
        if (address(_dcaToken) == address(0)) revert DCATokenAddressZero();
        if (address(_vault) == address(0)) revert VaultAddressZero();
        if (address(_dcaToken) == _vault.asset()) revert DCATokenSameAsVaultAsset();
        if (address(_swapper) == address(0)) revert SwapperAddressZero();
        if (_admin == address(0)) revert AdminAddressZero();
        if (_keeper == address(0)) revert KeeperAddressZero();

        dcaToken = _dcaToken;
        vault = _vault;
        swapper = _swapper;

        _setMinEpochDuration(_minEpochDuration);

        IERC20(vault.asset()).forceApprove(address(_swapper), type(uint256).max);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
    }

    /**
     * @notice Checks if the contract implements an interface
     * @dev Implements ERC165 standard for interface detection.
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return bool True if the contract implements the requested interface, false otherwise
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return interfaceId == type(AccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Updates the address of the swapper contract used to exchange yield for DCA tokens
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. Emits the SwapperUpdated event.
     * @param _swapper The address of the new swapper contract
     */
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

    /**
     * @notice Sets the minimum duration between epochs in which the DCA can be executed
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The duration must be between defined upper and lower bounds. Emits the DCAIntervalUpdated event.
     * @param _duration The new minimum duration in seconds
     */
    function setMinEpochDuration(uint256 _duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinEpochDuration(_duration);

        emit DCAIntervalUpdated(msg.sender, _duration);

        minEpochDuration = _duration;
    }

    function _setMinEpochDuration(uint256 _duration) internal {
        if (_duration < MIN_DCA_INTERVAL_LOWER_BOUND || _duration > MIN_DCA_INTERVAL_UPPER_BOUND) {
            revert InvalidDCAInterval();
        }

        minEpochDuration = _duration;
    }

    /**
     * @notice Sets the minimum yield required per epoch to execute the DCA strategy
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The yield must be between defined upper and lower bounds. Emits the MinYieldPerEpochUpdated event.
     * @param _minYield The new minimum yield as a WAD-scaled percentage of the total principal
     */
    function setMinYieldPerEpoch(uint256 _minYield) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minYield < MIN_YIELD_PER_EPOCH_LOWER_BOUND || _minYield > MIN_YIELD_PER_EPOCH_UPPER_BOUND) {
            revert InvalidMinYieldPerEpoch();
        }

        minYieldPerEpoch = _minYield;

        emit MinYieldPerEpochUpdated(msg.sender, _minYield);
    }

    /**
     * @notice Deposits shares of the vault's underlying asset into the DCA strategy
     * @dev Mints a unique ERC721 token representing the deposit. The deposit details are recorded, and the shares are transferred from the caller to the contract.
     * @param _shares The amount of shares to deposit
     * @return depositId The ID of the created deposit, represented by an ERC721 token
     */
    function deposit(uint256 _shares) external returns (uint256 depositId) {
        _checkAmount(_shares);

        unchecked {
            depositId = nextDepositId++;
        }

        _mint(msg.sender, depositId);

        uint256 currentEpoch_ = currentEpoch;
        uint256 principal = _convertToAssets(_shares);

        unchecked {
            totalPrincipalDeposited += principal;
        }

        DepositInfo storage deposit_ = deposits[depositId];
        deposit_.shares = _shares;
        deposit_.principal = principal;
        deposit_.epoch = currentEpoch_;

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit Deposit(msg.sender, depositId, _shares, principal, currentEpoch_);
    }

    /**
     * @notice Adds additional shares to an existing deposit
     * @dev Can only be called by the owner of the deposit. Updates the deposit's principal and share count.
     * @param _shares The amount of additional shares to add
     * @param _depositId The ID of the deposit to top up
     */
    function topUp(uint256 _shares, uint256 _depositId) external {
        _checkAmount(_shares);
        _checkOwnership(_depositId);

        uint256 currentEpoch_ = currentEpoch;
        uint256 principal = _convertToAssets(_shares);

        unchecked {
            totalPrincipalDeposited += principal;
        }

        DepositInfo storage deposit_ = deposits[_depositId];
        // if deposit is from a previous epoch, update the balances
        if (deposit_.epoch < currentEpoch_) {
            (uint256 shares, uint256 dcaTokens) = _calculateBalances(deposit_, currentEpoch_);

            deposit_.shares = shares;
            deposit_.dcaAmountAtEpoch = dcaTokens;
        }

        unchecked {
            deposit_.shares += _shares;
            deposit_.principal += principal;
            deposit_.epoch = currentEpoch_;
        }

        vault.safeTransferFrom(msg.sender, address(this), _shares);

        emit Deposit(msg.sender, _depositId, _shares, principal, currentEpoch_);
    }

    /**
     * @notice Checks if the conditions are met to execute the DCA strategy for the current epoch
     * @dev Verifies if there is sufficient principal deposited, the minimum time has elapsed, and the yield threshold is met.
     * @return bool True if the DCA strategy can be executed, false otherwise
     */
    function canExecuteDCA() external view returns (bool) {
        return totalPrincipalDeposited != 0 && block.timestamp >= currentEpochTimestamp + minEpochDuration
            && getYield() >= totalPrincipalDeposited.mulWadDown(minYieldPerEpoch);
    }

    /**
     * @notice Executes the DCA strategy to convert all available yield into DCA tokens and starts a new epoch
     * @dev Restricted to only the KEEPER_ROLE. This function redeems yield from the vault, swaps it for DCA tokens, and updates the epoch information.
     * Emits the DCAExecuted event with details of the executed epoch.
     * @param _dcaAmountOutMin The minimum amount of DCA tokens expected to be received from the swap
     * @param _swapData Arbitrary data used by the swapper contract to facilitate the token swap
     */
    function executeDCA(uint256 _dcaAmountOutMin, bytes calldata _swapData) external onlyRole(KEEPER_ROLE) {
        uint256 totalPrincipal = totalPrincipalDeposited;
        if (totalPrincipal == 0) revert NoPrincipalDeposited();
        if (block.timestamp < currentEpochTimestamp + minEpochDuration) revert MinEpochDurationNotReached();

        uint256 yieldInShares = _calculateCurrentYieldInShares(totalPrincipal);

        if (yieldInShares == 0) revert YieldZero();

        vault.redeem(yieldInShares, address(this), address(this));

        uint256 yield = IERC20(vault.asset()).balanceOf(address(this));

        if (yield < totalPrincipal.mulWadDown(minYieldPerEpoch)) revert InsufficientYield();

        uint256 amountOut = _buyDcaToken(yield, _dcaAmountOutMin, _swapData);
        uint256 dcaPrice = amountOut.divWadDown(yield);
        uint256 sharePrice = yield.divWadDown(yieldInShares);
        uint256 currentEpoch_ = currentEpoch;

        epochDetails[currentEpoch_] = EpochInfo({dcaPrice: uint128(dcaPrice), sharePrice: uint128(sharePrice)});

        unchecked {
            currentEpoch++;
        }

        currentEpochTimestamp = block.timestamp;

        emit DCAExecuted(currentEpoch_, yield, amountOut, dcaPrice, sharePrice);
    }

    function _buyDcaToken(uint256 _amountIn, uint256 _dcaAmountOutMin, bytes calldata _swapData)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = dcaBalance();

        swapper.execute(vault.asset(), address(dcaToken), _amountIn, _dcaAmountOutMin, _swapData);

        uint256 balanceAfter = dcaBalance();

        if (balanceAfter < balanceBefore + _dcaAmountOutMin) revert AmountReceivedTooLow();

        unchecked {
            return balanceAfter - balanceBefore;
        }
    }

    // NOTE: uses around 610k gas while iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    /**
     * @notice Withdraws a specified amount of shares and any accumulated DCA tokens from a deposit
     * @dev Can only be called by the owner of the deposit. Adjusts or deletes the deposit record based on the amount withdrawn.
     * Emits the Withdraw event with details of the withdrawal.
     * Reverts if the user does not own the deposit, or if the amount of shares to withdraw is greater than the principal value of the deposit.
     * If 0 shares are passed, only DCA tokens are withdrawn.
     * @param _shares The number of shares to withdraw
     * @param _depositId The ID of the deposit from which to withdraw
     * @return principalWithdrawn The amount of principal corresponding to the shares withdrawn
     * @return dcaAmount The amount of DCA tokens withdrawn
     */
    function withdraw(uint256 _shares, uint256 _depositId)
        external
        returns (uint256 principalWithdrawn, uint256 dcaAmount)
    {
        _checkOwnership(_depositId);

        uint256 currentEpoch_ = currentEpoch;
        (principalWithdrawn, dcaAmount) = _processWithdrawal(_shares, _depositId, currentEpoch_);

        uint256 sharesBalance_ = sharesBalance();
        // limit to available shares and dca tokens because of possible rounding errors
        _shares = _shares > sharesBalance_ ? sharesBalance_ : _shares;
        vault.safeTransfer(msg.sender, _shares);

        uint256 dcaBalance_ = dcaBalance();
        dcaAmount = dcaAmount > dcaBalance_ ? dcaBalance_ : dcaAmount;
        dcaToken.safeTransfer(msg.sender, dcaAmount);

        emit Withdraw(msg.sender, currentEpoch_, principalWithdrawn, _shares, dcaAmount);
    }

    function _processWithdrawal(uint256 _shares, uint256 _depositId, uint256 _currentEpoch)
        internal
        returns (uint256 principalWithdrawn, uint256 dcaAmount)
    {
        DepositInfo storage deposit_ = deposits[_depositId];
        uint256 sharesRemaining;
        (sharesRemaining, dcaAmount) = _calculateBalances(deposit_, _currentEpoch);

        if (_shares > sharesRemaining) revert InsufficientSharesToWithdraw();

        if (_shares == sharesRemaining) {
            // withadraw all
            principalWithdrawn = deposit_.principal;

            delete deposits[_depositId];
            _burn(_depositId);
        } else {
            // withdraw partial
            principalWithdrawn = deposit_.principal.mulDivDown(_shares, sharesRemaining);

            deposit_.principal -= principalWithdrawn;
            deposit_.shares = sharesRemaining - _shares;
            deposit_.dcaAmountAtEpoch = 0;
            deposit_.epoch = _currentEpoch;
        }

        totalPrincipalDeposited -= principalWithdrawn;
    }

    /**
     * @notice Provides the current balance of shares and DCA tokens for a given deposit
     * @param _depositId The ID of the deposit to query
     * @return shares The current number of shares in the deposit
     * @return dcaTokens The current amount of DCA tokens attributed to the deposit
     */
    function balancesOf(uint256 _depositId) public view returns (uint256 shares, uint256 dcaTokens) {
        (shares, dcaTokens) = _calculateBalances(deposits[_depositId], currentEpoch);
    }

    /**
     * @notice Calculates the total yield generated from the vault's assets beyond the total principal deposited
     * @dev This yield represents the total available assets minus the principal, which can be used in the DCA strategy.
     * @return uint256 The total yield available in the vault's underlying asset units
     */
    function getYield() public view returns (uint256) {
        uint256 assets = _convertToAssets(sharesBalance());

        unchecked {
            return assets > totalPrincipalDeposited ? assets - totalPrincipalDeposited : 0;
        }
    }

    /**
     * @notice Calculates the current yield in terms of vault shares
     * @dev Provides the yield in share format, useful for operations requiring share-based calculations.
     * @return uint256 The yield represented in shares of the vault
     */
    function getYieldInShares() public view returns (uint256) {
        return _calculateCurrentYieldInShares(totalPrincipalDeposited);
    }

    function _calculateCurrentYieldInShares(uint256 _totalPrincipal) internal view returns (uint256) {
        uint256 balance = sharesBalance();
        uint256 totalPrincipalInShares = vault.convertToShares(_totalPrincipal);

        unchecked {
            return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
        }
    }

    function _calculateBalances(DepositInfo memory _deposit, uint256 _latestEpoch)
        internal
        view
        returns (uint256 shares, uint256 dcaTokens)
    {
        if (_deposit.epoch == 0) return (0, 0);

        shares = _deposit.shares;
        dcaTokens = _deposit.dcaAmountAtEpoch;
        uint256 principal = _deposit.principal;

        // NOTE: one iteration costs around 2480 gas when called from a non-view function
        for (uint256 i = _deposit.epoch; i < _latestEpoch;) {
            EpochInfo memory info = epochDetails[i];
            // save gas on sload
            uint256 sharePrice = info.sharePrice;

            unchecked {
                // use plain arithmetic instead of FixedPointMathLib to lower gas costs
                // since we are only working with yield, it is not realistic to expect values large enough to overflow on multiplication
                uint256 sharesValue = shares * sharePrice / 1e18;

                if (sharesValue > principal) {
                    // cannot underflow because of the check above
                    uint256 usersYield = sharesValue - principal;

                    shares -= usersYield * 1e18 / sharePrice;
                    dcaTokens += usersYield * info.dcaPrice / 1e18;
                }

                i++;
            }
        }
    }

    /**
     * @notice Gets the balance of DCA tokens held by this contract
     * @dev Useful for checking how many DCA tokens are available for withdrawal or other operations.
     * @return uint256 The amount of DCA tokens currently held by the contract
     */
    function dcaBalance() public view returns (uint256) {
        return dcaToken.balanceOf(address(this));
    }

    /**
     * @notice Gets the balance of vault shares held by this contract
     * @dev Useful for operations that require knowledge of total shares under the control of the contract.
     * @return uint256 The total number of shares held by the contract
     */
    function sharesBalance() public view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return vault.convertToAssets(_shares);
    }

    function _checkOwnership(uint256 _depositId) internal view {
        if (ownerOf(_depositId) != msg.sender) revert CallerNotTokenOwner();
    }

    function _checkAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }
}
