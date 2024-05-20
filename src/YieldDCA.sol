// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC2612} from "openzeppelin-contracts/interfaces/IERC2612.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {CommonErrors} from "./common/CommonErrors.sol";
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
    using CommonErrors for uint256;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 epoch;
        uint256 shares;
        uint256 principal;
        uint256 dcaAmount;
    }

    struct EpochInfo {
        // using uint128s to pack variables and save on sstore/sload since both values are always written/read together
        // dcaPrice and sharePrice are in WAD and represent the result of dividing two uint256s
        // using uint128s instead of uint256s can potentially lead to overflow issues
        uint128 dcaPrice;
        uint128 sharePrice;
    }

    event PositionOpened(
        address indexed caller, uint256 indexed positionId, uint256 epoch, uint256 shares, uint256 principal
    );
    event PositionIncreased(
        address indexed caller, uint256 indexed positionId, uint256 epoch, uint256 shares, uint256 principal
    );
    event PositionReduced(
        address indexed caller, uint256 indexed positionId, uint256 epoch, uint256 shares, uint256 principal
    );
    event PositionClosed(
        address indexed caller,
        uint256 indexed positionId,
        uint256 epoch,
        uint256 shares,
        uint256 princpal,
        uint256 dcaTokens
    );
    event DCATokensClaimed(address indexed caller, uint256 indexed positionId, uint256 epoch, uint256 dcaTokens);

    event DCAIntervalUpdated(address indexed admin, uint256 newInterval);
    event MinYieldPerEpochUpdated(address indexed admin, uint256 newMinYield);
    event SwapperUpdated(address indexed admin, address newSwapper);
    event DiscrepancyToleranceUpdated(address indexed admin, uint256 newTolerance);

    event DCAExecuted(
        address indexed keeper,
        uint256 epoch,
        uint256 yieldSpent,
        uint256 dcaBought,
        uint256 dcaPrice,
        uint256 sharePrice
    );

    error DCATokenAddressZero();
    error VaultAddressZero();
    error SwapperAddressZero();
    error DCATokenSameAsVaultAsset();
    error KeeperAddressZero();
    error AdminAddressZero();
    error EpochDurationOutOfBounds();
    error MinYieldPerEpochOutOfBounds();
    error DiscrepancyToleranceOutOfBounds();

    //   TODO: find better names
    error MinEpochDurationNotReached();
    error InsufficientYield();
    error NoYield();
    error AmountReceivedTooLow();
    error InsufficientSharesToWithdraw();
    error CallerNotTokenOwner();
    error NothingToClaim();
    error DCADiscrepancyAboveTolerance();

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant EPOCH_DURATION_LOWER_BOUND = 1 weeks;
    uint256 public constant EPOCH_DURATION_UPPER_BOUND = 10 weeks;
    uint256 public constant MIN_YIELD_PER_EPOCH_LOWER_BOUND = 0.0001e18; // 0.01%
    uint256 public constant MIN_YIELD_PER_EPOCH_UPPER_BOUND = 0.01e18; // 1%
    uint256 public constant DISCREPANCY_TOLERANCE_UPPER_BOUND = 1e18; // 100%

    IERC20 public immutable dcaToken;
    IERC20 public immutable asset;
    IERC4626 public immutable vault;
    ISwapper public swapper;

    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;
    /// @dev The minimum interval between executing the DCA strategy (epoch duration)
    uint256 public epochDuration = 2 weeks;
    /// @dev The minimum yield required to execute the DCA strategy in an epoch
    uint256 public minYieldPerEpoch = 0.001e18; // 0.1%
    uint256 public discrepancyTolerance = 0.01e18; // 1%

    mapping(uint256 => EpochInfo) public epochDetails;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    uint256 public totalPrincipal;

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    constructor(
        IERC20 _dcaToken,
        IERC4626 _vault,
        ISwapper _swapper,
        uint256 _epochDuration,
        uint256 _minYieldPerEpochPercent,
        address _admin,
        address _keeper
    ) ERC721("YieldDCA", "YDCA") {
        if (address(_dcaToken) == address(0)) revert DCATokenAddressZero();
        if (address(_vault) == address(0)) revert VaultAddressZero();
        if (address(_dcaToken) == _vault.asset()) revert DCATokenSameAsVaultAsset();
        if (_admin == address(0)) revert AdminAddressZero();
        if (_keeper == address(0)) revert KeeperAddressZero();

        dcaToken = _dcaToken;
        asset = IERC20(_vault.asset());
        vault = _vault;

        _setSwapper(_swapper);
        _setEpochDuration(_epochDuration);
        _setMinYieldPerEpoch(_minYieldPerEpochPercent);

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
     * @param _newSwapper The address of the new swapper contract
     */
    function setSwapper(ISwapper _newSwapper) external onlyAdmin {
        _setSwapper(_newSwapper);

        emit SwapperUpdated(msg.sender, address(_newSwapper));
    }

    function _setSwapper(ISwapper _newSwapper) internal {
        if (address(_newSwapper) == address(0)) revert SwapperAddressZero();

        // revoke previous swapper's approval and approve new swapper
        if (address(swapper) != address(0)) asset.forceApprove(address(swapper), 0);
        asset.forceApprove(address(_newSwapper), type(uint256).max);

        swapper = _newSwapper;
    }

    /**
     * @notice Sets the minimum duration between epochs in which the DCA can be executed
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The duration must be between defined upper and lower bounds. Emits the DCAIntervalUpdated event.
     * @param _newDuration The new minimum duration in seconds
     */
    function setEpochDuration(uint256 _newDuration) external onlyAdmin {
        _setEpochDuration(_newDuration);

        emit DCAIntervalUpdated(msg.sender, _newDuration);
    }

    function _setEpochDuration(uint256 _newDuration) internal {
        if (_newDuration < EPOCH_DURATION_LOWER_BOUND || _newDuration > EPOCH_DURATION_UPPER_BOUND) {
            revert EpochDurationOutOfBounds();
        }

        epochDuration = _newDuration;
    }

    /**
     * @notice Sets the minimum yield required per epoch to execute the DCA strategy
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The yield must be between defined upper and lower bounds. Emits the MinYieldPerEpochUpdated event.
     * @param _newMinYieldPercent The new minimum yield as a WAD-scaled percentage of the total principal
     */
    function setMinYieldPerEpoch(uint256 _newMinYieldPercent) external onlyAdmin {
        _setMinYieldPerEpoch(_newMinYieldPercent);

        emit MinYieldPerEpochUpdated(msg.sender, _newMinYieldPercent);
    }

    function _setMinYieldPerEpoch(uint256 _newMinYieldPercent) internal {
        if (
            _newMinYieldPercent < MIN_YIELD_PER_EPOCH_LOWER_BOUND
                || _newMinYieldPercent > MIN_YIELD_PER_EPOCH_UPPER_BOUND
        ) {
            revert MinYieldPerEpochOutOfBounds();
        }

        minYieldPerEpoch = _newMinYieldPercent;
    }

    function setDiscrepancyTolerance(uint256 _newTolerance) external onlyAdmin {
        if (_newTolerance > DISCREPANCY_TOLERANCE_UPPER_BOUND) revert DiscrepancyToleranceOutOfBounds();

        discrepancyTolerance = _newTolerance;

        emit DiscrepancyToleranceUpdated(msg.sender, _newTolerance);
    }

    /**
     * @notice Deposits shares of the vault's underlying asset into the DCA strategy
     * @dev Mints a unique ERC721 token representing the deposit. The deposit details are recorded, and the shares are transferred from the caller to the contract.
     * @param _shares The amount of shares to deposit
     * @return positionId The ID of the created deposit, represented by an ERC721 token
     */
    function openPosition(uint256 _shares) public returns (uint256 positionId) {
        _shares.checkIsZero();

        positionId = _openPosition(_shares);

        vault.safeTransferFrom(msg.sender, address(this), _shares);
    }

    function openPositionUsingPermit(uint256 _shares, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256 positionId)
    {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        positionId = openPosition(_shares);
    }

    function depositAndOpenPosition(uint256 _principal) public returns (uint256 positionId) {
        _principal.checkIsZero();

        uint256 shares = _depositToVault(_principal);

        positionId = _openPosition(shares);
    }

    function depositAndOpenPositionUsingPermit(uint256 _principal, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        public
        returns (uint256 positionId)
    {
        IERC2612(address(asset)).permit(msg.sender, address(this), _principal, _deadline, _v, _r, _s);

        positionId = depositAndOpenPosition(_principal);
    }

    /**
     * @notice Adds additional shares to an existing deposit
     * @dev Can only be called by the owner of the deposit. Updates the deposit's principal and share count.
     * @param _shares The amount of additional shares to add
     * @param _positionId The ID of the deposit to top up
     */
    function increasePosition(uint256 _positionId, uint256 _shares) public {
        _shares.checkIsZero();
        _checkIsOwner(_positionId);

        uint256 principal = vault.convertToAssets(_shares);

        _increasePosition(_positionId, _shares, principal);

        vault.safeTransferFrom(msg.sender, address(this), _shares);
    }

    function increasePositionUsingPermit(
        uint256 _positionId,
        uint256 _shares,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        increasePosition(_positionId, _shares);
    }

    function depositAndIncreasePosition(uint256 _positionId, uint256 _assets) public {
        _assets.checkIsZero();
        _checkIsOwner(_positionId);

        uint256 shares = _depositToVault(_assets);

        _increasePosition(_positionId, shares, _assets);
    }

    function depositAndIncreasePositionUsingPermit(
        uint256 _positionId,
        uint256 _assets,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC2612(address(asset)).permit(msg.sender, address(this), _assets, _deadline, _v, _r, _s);

        depositAndIncreasePosition(_positionId, _assets);
    }

    // NOTE: uses around 610k gas while iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    /**
     * @notice Withdraws a specified amount of shares and any accumulated DCA tokens from a deposit
     * @dev Can only be called by the owner of the deposit. Adjusts or deletes the deposit record based on the amount withdrawn.
     * Emits the Withdraw event with details of the withdrawal.
     * Reverts if the user does not own the deposit, or if the amount of shares to withdraw is greater than the principal value of the deposit.
     * If 0 shares are passed, only DCA tokens are withdrawn.
     * @param _shares The number of shares to withdraw
     * @param _positionId The ID of the deposit from which to withdraw
     */
    function reducePosition(uint256 _positionId, uint256 _shares) external {
        _shares.checkIsZero();
        _checkIsOwner(_positionId);

        Position storage position = positions[_positionId];
        uint256 currentEpoch_ = currentEpoch;
        (uint256 sharesAvailable, uint256 dcaAmount) = _calculateBalances(position, currentEpoch_);

        // the position will be closed if all shares are withdrawn
        if (_shares != sharesAvailable) {
            _reducePosition(position, _positionId, currentEpoch_, _shares, sharesAvailable, dcaAmount);
        } else {
            _closePosition(_positionId, position.principal, sharesAvailable, dcaAmount);
        }
    }

    /**
     * @notice Withdraws all shares and any accumulated DCA tokens from a deposit
     * @dev Can only be called by the owner of the deposit. Deletes the deposit record and transfers the shares and DCA tokens to the caller.
     * Emits the Withdraw event with details of the withdrawal.
     * Reverts if the user does not own the deposit.
     * @param _positionId The ID of the deposit to close
     */
    function closePosition(uint256 _positionId) external {
        _checkIsOwner(_positionId);

        uint256 currentEpoch_ = currentEpoch;
        Position storage position = positions[_positionId];
        (uint256 shares, uint256 dcaAmount) = _calculateBalances(position, currentEpoch_);

        _closePosition(_positionId, position.principal, shares, dcaAmount);
    }

    function claimDCATokens(uint256 _positionId) external returns (uint256 dcaAmount) {
        _checkIsOwner(_positionId);

        uint256 currentEpoch_ = currentEpoch;
        Position storage position = positions[_positionId];
        (position.shares, dcaAmount) = _calculateBalances(position, currentEpoch_);

        if (dcaAmount == 0) revert NothingToClaim();

        position.epoch = currentEpoch_;
        position.dcaAmount = 0;

        dcaAmount = _transferDcaTokens(dcaAmount);

        emit DCATokensClaimed(msg.sender, _positionId, currentEpoch_, dcaAmount);
    }

    /**
     * @notice Checks if the conditions are met to execute the DCA strategy for the current epoch.
     * @dev Meant to be called only off-chain to preview the DCA execution conditions.
     * @return True if the DCA strategy can be executed, reverts otherwise
     */
    function canExecuteDCA() external view returns (bool) {
        if (block.timestamp < currentEpochTimestamp + epochDuration) revert MinEpochDurationNotReached();

        uint256 yieldInShares = _calculateCurrentYieldInShares(totalPrincipal);

        if (yieldInShares == 0) revert NoYield();

        uint256 yield = vault.previewRedeem(yieldInShares);

        if (yield < totalPrincipal.mulWad(minYieldPerEpoch)) revert InsufficientYield();

        return true;
    }

    /**
     * @notice Executes the DCA strategy to convert all available yield into DCA tokens and starts a new epoch
     * @dev Restricted to only the KEEPER_ROLE. This function redeems yield from the vault, swaps it for DCA tokens, and updates the epoch information.
     * Emits the DCAExecuted event with details of the executed epoch.
     * @param _dcaAmountOutMin The minimum amount of DCA tokens expected to be received from the swap
     * @param _swapData Arbitrary data used by the swapper contract to facilitate the token swap
     */
    function executeDCA(uint256 _dcaAmountOutMin, bytes calldata _swapData) external onlyRole(KEEPER_ROLE) {
        if (block.timestamp < currentEpochTimestamp + epochDuration) revert MinEpochDurationNotReached();

        uint256 totalPrincipal_ = totalPrincipal;
        uint256 yieldInShares = _calculateCurrentYieldInShares(totalPrincipal_);

        if (yieldInShares == 0) revert NoYield();

        vault.redeem(yieldInShares, address(this), address(this));

        uint256 yield = asset.balanceOf(address(this));

        if (yield < totalPrincipal_.mulWad(minYieldPerEpoch)) revert InsufficientYield();

        uint256 amountOut = _buyDcaTokens(yield, _dcaAmountOutMin, _swapData);
        uint256 dcaPrice = amountOut.divWad(yield);
        uint256 sharePrice = yield.divWad(yieldInShares);
        uint256 currentEpoch_ = currentEpoch;

        epochDetails[currentEpoch_] = EpochInfo({dcaPrice: uint128(dcaPrice), sharePrice: uint128(sharePrice)});

        unchecked {
            currentEpoch++;
        }

        currentEpochTimestamp = block.timestamp;

        emit DCAExecuted(msg.sender, currentEpoch_, yield, amountOut, dcaPrice, sharePrice);
    }

    /**
     * @notice Calculates the total yield generated from the vault's assets beyond the total principal deposited
     * @dev This yield represents the total available assets minus the principal, which can be used in the DCA strategy.
     * @return uint256 The total yield available in the vault's underlying asset units
     */
    function calculateYield() public view returns (uint256) {
        uint256 assets = vault.convertToAssets(sharesBalance());

        unchecked {
            return assets > totalPrincipal ? assets - totalPrincipal : 0;
        }
    }

    /**
     * @notice Calculates the current yield in terms of vault shares
     * @dev Provides the yield in share format, useful for operations requiring share-based calculations.
     * @return uint256 The yield represented in shares of the vault
     */
    function calculateYieldInShares() public view returns (uint256) {
        return _calculateCurrentYieldInShares(totalPrincipal);
    }

    /**
     * @notice Provides the current balance of shares and DCA tokens for a given deposit
     * @param _positionId The ID of the deposit to query
     * @return shares The current number of shares in the deposit
     * @return dcaTokens The current amount of DCA tokens attributed to the deposit
     */
    function balancesOf(uint256 _positionId) public view returns (uint256 shares, uint256 dcaTokens) {
        (shares, dcaTokens) = _calculateBalances(positions[_positionId], currentEpoch);
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

    function _checkIsOwner(uint256 _positionId) internal view {
        if (ownerOf(_positionId) != msg.sender) revert CallerNotTokenOwner();
    }

    function _openPosition(uint256 _shares) internal returns (uint256 positionId) {
        uint256 currentEpoch_ = currentEpoch;
        uint256 principal = vault.convertToAssets(_shares);

        unchecked {
            totalPrincipal += principal;
            positionId = nextPositionId++;
        }

        _mint(msg.sender, positionId);

        positions[positionId] = Position({epoch: currentEpoch_, shares: _shares, principal: principal, dcaAmount: 0});

        emit PositionOpened(msg.sender, positionId, currentEpoch_, _shares, principal);
    }

    function _increasePosition(uint256 _positionId, uint256 _shares, uint256 _principal) internal {
        uint256 epoch = currentEpoch;
        Position storage position = positions[_positionId];

        // if deposit is from a previous epoch, update the balances
        if (position.epoch < epoch) {
            (position.shares, position.dcaAmount) = _calculateBalances(position, epoch);
        }

        unchecked {
            position.epoch = epoch;
            position.shares += _shares;
            position.principal += _principal;

            totalPrincipal += _principal;
        }

        emit PositionIncreased(msg.sender, _positionId, epoch, _shares, _principal);
    }

    function _reducePosition(
        Position storage position,
        uint256 _positionId,
        uint256 _epoch,
        uint256 _shares,
        uint256 _sharesAvailable,
        uint256 _dcaAmount
    ) internal {
        if (_shares > _sharesAvailable) revert InsufficientSharesToWithdraw();

        uint256 principal = position.principal.mulDiv(_shares, _sharesAvailable);

        position.epoch = _epoch;
        position.dcaAmount = _dcaAmount;

        unchecked {
            // cannot underflow because of sharesAvailable > _shares check
            position.shares = _sharesAvailable - _shares;
            position.principal -= principal;
        }

        totalPrincipal -= principal;

        _shares = _transferShares(_shares);

        emit PositionReduced(msg.sender, _positionId, _epoch, _shares, principal);
    }

    function _closePosition(uint256 _positionId, uint256 _principal, uint256 _shares, uint256 _dcaAmount) internal {
        totalPrincipal -= _principal;

        delete positions[_positionId];
        _burn(_positionId);

        _shares = _transferShares(_shares);
        _dcaAmount = _transferDcaTokens(_dcaAmount);

        emit PositionClosed(msg.sender, _positionId, currentEpoch, _shares, _principal, _dcaAmount);
    }

    function _depositToVault(uint256 _principal) internal returns (uint256 shares) {
        asset.safeTransferFrom(msg.sender, address(this), _principal);

        asset.forceApprove(address(vault), _principal);

        shares = vault.deposit(_principal, address(this));
    }

    function _transferShares(uint256 _shares) internal returns (uint256) {
        // limit to available shares because of possible rounding errors
        uint256 sharesBalance_ = sharesBalance();

        if (_shares > sharesBalance_) _shares = sharesBalance_;

        vault.safeTransfer(msg.sender, _shares);

        return _shares;
    }

    function _transferDcaTokens(uint256 _amount) internal returns (uint256) {
        uint256 balance = dcaBalance();

        // limit to available or revert if amount discrepancy is above set tolerance
        if (_amount > balance) {
            unchecked {
                if (_amount - balance > _amount.mulWad(discrepancyTolerance)) {
                    revert DCADiscrepancyAboveTolerance();
                }
            }

            _amount = balance;
        }

        dcaToken.safeTransfer(msg.sender, _amount);

        return _amount;
    }

    function _buyDcaTokens(uint256 _amountIn, uint256 _dcaAmountOutMin, bytes calldata _swapData)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = dcaBalance();

        swapper.execute(vault.asset(), address(dcaToken), _amountIn, _dcaAmountOutMin, _swapData);

        uint256 balanceAfter = dcaBalance();

        unchecked {
            if (balanceAfter < balanceBefore + _dcaAmountOutMin) revert AmountReceivedTooLow();

            return balanceAfter - balanceBefore;
        }
    }

    function _calculateCurrentYieldInShares(uint256 _totalPrincipal) internal view returns (uint256) {
        uint256 balance = sharesBalance();
        uint256 totalPrincipalInShares = vault.convertToShares(_totalPrincipal);

        unchecked {
            return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
        }
    }

    function _calculateBalances(Position storage _position, uint256 _latestEpoch)
        internal
        view
        returns (uint256 shares, uint256 dcaAmount)
    {
        if (_position.epoch == 0) return (0, 0);

        shares = _position.shares;
        dcaAmount = _position.dcaAmount;
        uint256 principal = _position.principal;

        // NOTE: one iteration costs around 2600 gas
        for (uint256 i = _position.epoch; i < _latestEpoch;) {
            EpochInfo memory info = epochDetails[i];
            // save gas on sload
            uint256 sharePrice = info.sharePrice;

            // round up to minimize the impact on rounding errors
            uint256 sharesValue = shares.mulWadUp(sharePrice);

            unchecked {
                if (sharesValue > principal) {
                    // cannot underflow because of the check above
                    uint256 usersYield = sharesValue - principal;

                    shares -= usersYield * 1e18 / sharePrice;
                    dcaAmount += usersYield * info.dcaPrice / 1e18;
                }

                i++;
            }
        }
    }
}
