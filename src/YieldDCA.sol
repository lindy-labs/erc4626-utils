// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/interfaces/IERC721.sol";
import {IERC20Metadata} from "openzeppelin-contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
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
// TODO: add multicall support to open and approve
// TODO: receiver param on creating the position
// TODO: receiver param on claiming the DCA tokens
contract YieldDCA is ERC721, AccessControl {
    using CommonErrors for uint256;
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;
    using SafeTransferLib for address;

    struct Position {
        uint256 shares;
        uint256 principal;
        uint224 dcaBalance;
        uint32 epoch;
    }

    struct EpochInfo {
        // using uint128s to pack variables and save on sstore/sload since both values are always written/read together
        // dcaPrice and sharePrice are in WAD and represent the result of dividing two uint256s
        // using uint128s instead of uint256s can potentially lead to overflow issues
        uint128 dcaPrice;
        uint128 sharePrice;
    }

    event EpochDurationUpdated(address indexed admin, uint32 oldDuration, uint32 newDuration);
    event MinYieldPerEpochUpdated(address indexed admin, uint64 oldMinYield, uint64 newMinYield);
    event SwapperUpdated(address indexed admin, address oldSwapper, address newSwapper);
    event DiscrepancyToleranceUpdated(address indexed admin, uint64 oldTolerance, uint64 newTolerance);

    event DCAExecuted(
        address indexed keeper,
        uint32 epoch,
        uint256 yieldSpent,
        uint256 dcaBought,
        uint128 dcaPrice,
        uint128 sharePrice
    );

    event PositionOpened(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionIncreased(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionReduced(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal
    );
    event PositionClosed(
        address indexed caller,
        address indexed owner,
        uint256 indexed positionId,
        uint32 epoch,
        uint256 shares,
        uint256 principal,
        uint256 dcaAmount
    );
    event DCATokensClaimed(
        address indexed caller, address indexed owner, uint256 indexed positionId, uint32 epoch, uint256 amount
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

    error EpochDurationNotReached();
    error InsufficientYield();
    error NoYield();
    error AmountReceivedTooLow();
    error InsufficientSharesToWithdraw();
    error NothingToClaim();
    error DCADiscrepancyAboveTolerance();

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint32 public constant EPOCH_DURATION_LOWER_BOUND = 1 weeks;
    uint32 public constant EPOCH_DURATION_UPPER_BOUND = 10 weeks;
    uint64 public constant MIN_YIELD_PER_EPOCH_UPPER_BOUND = 0.01e18; // 1%
    uint64 public constant DISCREPANCY_TOLERANCE_UPPER_BOUND = 1e18; // 100%

    IERC20Metadata public immutable dcaToken;
    IERC20Metadata public immutable asset;
    IERC4626 public immutable vault;

    // * SLOT 0
    // TODO: test maximum amount of epochs
    uint32 public currentEpoch = 1; // starts from 1
    /// @dev The minimum interval between executing the DCA strategy (epoch duration)
    uint32 public epochDuration = 2 weeks;
    uint64 public currentEpochTimestamp = uint64(block.timestamp);
    /// @dev The minimum yield required to execute the DCA strategy in an epoch
    uint64 public minYieldPerEpoch = 0; // 0.1%
    uint64 public discrepancyTolerance = 0.01e18; // 1%

    // * SLOT 1
    ISwapper public swapper;
    uint96 public nextPositionId = 1;

    // * SLOT 2 ...
    uint256 public totalPrincipal;

    mapping(uint256 => EpochInfo) public epochDetails;
    mapping(uint256 => Position) public positions;

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    // ERC721 name and symbol
    string private name_;
    string private symbol_;

    constructor(
        IERC20Metadata _dcaToken,
        IERC4626 _vault,
        ISwapper _swapper,
        uint32 _epochDuration,
        uint64 _minYieldPerEpochPercent,
        address _admin,
        address _keeper
    ) {
        // validate input parameters
        if (address(_dcaToken) == address(0)) revert DCATokenAddressZero();
        if (address(_vault) == address(0)) revert VaultAddressZero();
        if (address(_dcaToken) == _vault.asset()) revert DCATokenSameAsVaultAsset();
        if (_admin == address(0)) revert AdminAddressZero();
        if (_keeper == address(0)) revert KeeperAddressZero();

        // set contract state
        dcaToken = _dcaToken;
        asset = IERC20Metadata(_vault.asset());
        vault = _vault;

        _setSwapper(_swapper);
        _setEpochDuration(_epochDuration);
        _setMinYieldPerEpoch(_minYieldPerEpochPercent);

        name_ = string(abi.encodePacked("Yield DCA - ", _vault.name(), " / ", _dcaToken.name()));
        symbol_ = string(abi.encodePacked("yDCA-", _vault.symbol(), "/", _dcaToken.symbol()));

        // set roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);

        // approve the vault as underlying assets spender
        address(asset).safeApprove(address(_vault), type(uint256).max);
    }

    /*
    * =======================================================
    *                   EXTERNAL FUNCTIONS
    * =======================================================
    */

    /// @inheritdoc ERC721
    function name() public view override returns (string memory) {
        return name_;
    }

    /// @inheritdoc ERC721
    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256) public view virtual override returns (string memory) {}

    /**
     * @notice Checks if the contract implements an interface
     * @dev Implements ERC165 standard for interface detection.
     * @param _interfaceId The interface identifier, as specified in ERC-165
     * @return bool True if the contract implements the requested interface, false otherwise
     */
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(ERC721, AccessControl)
        returns (bool)
    {
        return _interfaceId == type(AccessControl).interfaceId || _interfaceId == type(IERC721).interfaceId
            || super.supportsInterface(_interfaceId);
    }

    // *** admin functions ***

    /**
     * @notice Updates the address of the swapper contract used to exchange yield for DCA tokens
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. Emits the SwapperUpdated event.
     * @param _newSwapper The address of the new swapper contract
     */
    function setSwapper(ISwapper _newSwapper) external onlyAdmin {
        address oldSwapper = _setSwapper(_newSwapper);

        emit SwapperUpdated(msg.sender, oldSwapper, address(_newSwapper));
    }

    /**
     * @notice Sets the minimum duration between epochs in which the DCA can be executed
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The duration must be between defined upper and lower bounds. Emits the DCAIntervalUpdated event.
     * @param _newDuration The new minimum duration in seconds
     */
    function setEpochDuration(uint32 _newDuration) external onlyAdmin {
        uint32 oldDuration = _setEpochDuration(_newDuration);

        emit EpochDurationUpdated(msg.sender, oldDuration, _newDuration);
    }

    /**
     * @notice Sets the minimum yield required per epoch to execute the DCA strategy
     * @dev Restricted to only the DEFAULT_ADMIN_ROLE. The yield must be between defined upper and lower bounds. Emits the MinYieldPerEpochUpdated event.
     * @param _newMinYieldPercent The new minimum yield as a WAD-scaled percentage of the total principal
     */
    function setMinYieldPerEpoch(uint64 _newMinYieldPercent) external onlyAdmin {
        uint64 oldMinYield = _setMinYieldPerEpoch(_newMinYieldPercent);

        emit MinYieldPerEpochUpdated(msg.sender, oldMinYield, _newMinYieldPercent);
    }

    function setDiscrepancyTolerance(uint64 _newTolerance) external onlyAdmin {
        if (_newTolerance > DISCREPANCY_TOLERANCE_UPPER_BOUND) revert DiscrepancyToleranceOutOfBounds();

        emit DiscrepancyToleranceUpdated(msg.sender, discrepancyTolerance, _newTolerance);

        discrepancyTolerance = _newTolerance;
    }

    // *** user functions ***

    /**
     * @notice Deposits shares of the vault's underlying asset into the DCA strategy
     * @dev Mints a unique ERC721 token representing the deposit. The deposit details are recorded, and the shares are transferred from the caller to the contract.
     * @param _shares The amount of shares to deposit
     * @return positionId The ID of the created deposit, represented by an ERC721 token
     */
    function openPosition(uint256 _shares) public returns (uint256 positionId) {
        _shares.checkIsZero();

        positionId = _openPosition(_shares);

        address(vault).safeTransferFrom(msg.sender, address(this), _shares);
    }

    function openPositionUsingPermit(uint256 _shares, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        external
        returns (uint256 positionId)
    {
        IERC20Permit(address(vault)).permit(msg.sender, address(this), _shares, _deadline, _v, _r, _s);

        positionId = openPosition(_shares);
    }

    function depositAndOpenPosition(uint256 _principal) public returns (uint256 positionId) {
        _principal.checkIsZero();

        uint256 shares = _depositToVault(msg.sender, _principal);

        positionId = _openPosition(shares);
    }

    function depositAndOpenPositionUsingPermit(uint256 _principal, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
        public
        returns (uint256 positionId)
    {
        IERC20Permit(address(asset)).permit(msg.sender, address(this), _principal, _deadline, _v, _r, _s);

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
        _checkApprovedOrOwner(msg.sender, _positionId);

        uint256 principal = vault.convertToAssets(_shares);

        _increasePosition(_positionId, _shares, principal);

        address(vault).safeTransferFrom(_ownerOf(_positionId), address(this), _shares);
    }

    function increasePositionUsingPermit(
        uint256 _positionId,
        uint256 _shares,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        IERC20Permit(address(vault)).permit(_ownerOf(_positionId), address(this), _shares, _deadline, _v, _r, _s);

        increasePosition(_positionId, _shares);
    }

    function depositAndIncreasePosition(uint256 _positionId, uint256 _assets) public {
        _assets.checkIsZero();
        _checkApprovedOrOwner(msg.sender, _positionId);

        uint256 shares = _depositToVault(_ownerOf(_positionId), _assets);

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
        IERC20Permit(address(asset)).permit(_ownerOf(_positionId), address(this), _assets, _deadline, _v, _r, _s);

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
        _checkApprovedOrOwner(msg.sender, _positionId);

        Position storage position = positions[_positionId];
        uint32 currentEpoch_ = currentEpoch;
        (uint256 sharesBalance_, uint224 dcaBalance_) = _calculateBalances(position, currentEpoch_);

        // the position will be closed if all shares are withdrawn
        if (_shares != sharesBalance_) {
            _reducePosition(position, _positionId, currentEpoch_, _shares, sharesBalance_, dcaBalance_);
        } else {
            _closePosition(_positionId, position.principal, sharesBalance_, dcaBalance_);
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
        _checkApprovedOrOwner(msg.sender, _positionId);

        uint32 currentEpoch_ = currentEpoch;
        Position storage position = positions[_positionId];
        (uint256 shares, uint256 _dcaBalance) = _calculateBalances(position, currentEpoch_);

        _closePosition(_positionId, position.principal, shares, _dcaBalance);
    }

    function claimDCATokens(uint256 _positionId) external returns (uint256 dcaAmount) {
        _checkApprovedOrOwner(msg.sender, _positionId);

        uint32 currentEpoch_ = currentEpoch;
        Position storage position = positions[_positionId];
        (position.shares, dcaAmount) = _calculateBalances(position, currentEpoch_);

        if (dcaAmount == 0) revert NothingToClaim();

        position.epoch = currentEpoch_;
        position.dcaBalance = 0;

        address owner = _ownerOf(_positionId);

        dcaAmount = _transferDcaTokens(owner, dcaAmount);

        emit DCATokensClaimed(msg.sender, owner, _positionId, currentEpoch_, dcaAmount);
    }

    // *** keeper functions ***

    /**
     * @notice Executes the DCA strategy to convert all available yield into DCA tokens and starts a new epoch
     * @dev Restricted to only the KEEPER_ROLE. This function redeems yield from the vault, swaps it for DCA tokens, and updates the epoch information.
     * Emits the DCAExecuted event with details of the executed epoch.
     * @param _dcaAmountOutMin The minimum amount of DCA tokens expected to be received from the swap
     * @param _swapData Arbitrary data used by the swapper contract to facilitate the token swap
     */
    function executeDCA(uint256 _dcaAmountOutMin, bytes calldata _swapData) external onlyRole(KEEPER_ROLE) {
        _checkEpochDuration();

        uint256 totalPrincipal_ = totalPrincipal;
        uint256 yieldInShares = _calculateYieldInShares(totalPrincipal_);

        vault.redeem(yieldInShares, address(this), address(this));

        uint256 yield = asset.balanceOf(address(this));

        _checkMinYieldPerEpoch(yield, totalPrincipal_);

        uint32 currentEpoch_ = currentEpoch;
        uint256 amountOut = _buyDcaTokens(yield, _dcaAmountOutMin, _swapData);
        uint128 dcaPrice = amountOut.divWad(yield).toUint128();
        uint128 sharePrice = yield.divWad(yieldInShares).toUint128();

        epochDetails[currentEpoch_] = EpochInfo({dcaPrice: dcaPrice, sharePrice: sharePrice});

        unchecked {
            currentEpoch++;
        }

        currentEpochTimestamp = uint64(block.timestamp);

        emit DCAExecuted(msg.sender, currentEpoch_, yield, amountOut, dcaPrice, sharePrice);
    }

    // *** view functions ***

    /**
     * @notice Checks if the conditions are met to execute the DCA strategy for the current epoch.
     * @dev Meant to be called only off-chain to preview the DCA execution conditions.
     * @return True if the DCA strategy can be executed, reverts otherwise
     */
    function canExecuteDCA() external view returns (bool) {
        _checkEpochDuration();

        uint256 yieldInShares = _calculateYieldInShares(totalPrincipal);
        uint256 yield = vault.previewRedeem(yieldInShares);

        _checkMinYieldPerEpoch(yield, totalPrincipal);

        return true;
    }

    /**
     * @notice Calculates the yield generated in the current epoch expressed in asset units.
     * @dev This yield represents the total available assets minus the principal so it can be negative.
     * @return int256 Yield generated in the current epoch.
     */
    function calculateYield() public view returns (int256) {
        return int256(vault.convertToAssets(sharesBalance())) - int256(totalPrincipal);
    }

    /**
     * @notice Calculates the current yield expressed in the underlying 4626 vault shares.
     * @dev Useful for operations requiring share-based calculations. Reverts if the actual yield is zero or negative.
     * @return uint256 The yield expressed in shares.
     */
    function calculateYieldInShares() public view returns (uint256) {
        return _calculateYieldInShares(totalPrincipal);
    }

    /**
     * @notice Provides the current balance of shares and DCA tokens for a given deposit
     * @param _positionId The ID of the deposit to query
     * @return _sharesBalance The current number of shares in the deposit
     * @return _dcaBalance The current amount of DCA tokens attributed to the deposit
     */
    function balancesOf(uint256 _positionId) public view returns (uint256 _sharesBalance, uint256 _dcaBalance) {
        (_sharesBalance, _dcaBalance) = _calculateBalances(positions[_positionId], currentEpoch);
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

    function isApprovedOrOwner(address _account, uint256 _tokenId) public view returns (bool) {
        return _isApprovedOrOwner(_account, _tokenId);
    }

    /*
    * =======================================================
    *                   INTERNAL FUNCTIONS
    * =======================================================
    */

    // *** admin functons ***

    function _setSwapper(ISwapper _newSwapper) internal returns (address oldSwapper) {
        if (address(_newSwapper) == address(0)) revert SwapperAddressZero();
        oldSwapper = address(swapper);

        // revoke previous swapper's approval and approve new swapper
        if (oldSwapper != address(0)) address(asset).safeApprove(oldSwapper, 0);
        address(asset).safeApprove(address(_newSwapper), type(uint256).max);

        swapper = _newSwapper;
    }

    function _setEpochDuration(uint32 _newDuration) internal returns (uint32 oldDuration) {
        if (_newDuration < EPOCH_DURATION_LOWER_BOUND || _newDuration > EPOCH_DURATION_UPPER_BOUND) {
            revert EpochDurationOutOfBounds();
        }

        oldDuration = epochDuration;
        epochDuration = _newDuration;
    }

    function _setMinYieldPerEpoch(uint64 _newMinYieldPercent) internal returns (uint64 oldMinYield) {
        if (_newMinYieldPercent > MIN_YIELD_PER_EPOCH_UPPER_BOUND) {
            revert MinYieldPerEpochOutOfBounds();
        }

        oldMinYield = minYieldPerEpoch;
        minYieldPerEpoch = _newMinYieldPercent;
    }

    // *** accounting functions ***

    function _openPosition(uint256 _shares) internal returns (uint256 positionId) {
        uint32 currentEpoch_ = currentEpoch;
        uint256 principal = vault.convertToAssets(_shares);

        unchecked {
            totalPrincipal += principal;
            positionId = nextPositionId++;
        }

        // if caller is a contract make sure it implements IERC721Receiver-onERC721Received by using safeMint
        _safeMint(msg.sender, positionId);

        positions[positionId] = Position({epoch: currentEpoch_, shares: _shares, principal: principal, dcaBalance: 0});

        emit PositionOpened(msg.sender, msg.sender, positionId, currentEpoch_, _shares, principal);
    }

    function _increasePosition(uint256 _positionId, uint256 _shares, uint256 _principal) internal {
        uint32 epoch = currentEpoch;
        Position storage position = positions[_positionId];

        // if deposit is from a previous epoch, update the balances
        if (position.epoch < epoch) {
            (position.shares, position.dcaBalance) = _calculateBalances(position, epoch);
        }

        unchecked {
            position.epoch = epoch;
            // overflow here is not realistic to happen
            position.shares += _shares;
            position.principal += _principal;

            totalPrincipal += _principal;
        }

        emit PositionIncreased(msg.sender, _ownerOf(_positionId), _positionId, epoch, _shares, _principal);
    }

    function _reducePosition(
        Position storage position,
        uint256 _positionId,
        uint32 _epoch,
        uint256 _shares,
        uint256 _sharesBalance,
        uint224 _dcaBalance
    ) internal {
        if (_shares > _sharesBalance) revert InsufficientSharesToWithdraw();

        uint256 principal = position.principal.mulDiv(_shares, _sharesBalance);

        position.epoch = _epoch;
        position.dcaBalance = _dcaBalance;

        unchecked {
            // cannot underflow because of sharesAvailable > _shares check
            position.shares = _sharesBalance - _shares;
            position.principal -= principal;
        }

        totalPrincipal -= principal;

        address owner = _ownerOf(_positionId);

        _shares = _transferShares(owner, _shares);

        emit PositionReduced(msg.sender, owner, _positionId, _epoch, _shares, principal);
    }

    function _closePosition(uint256 _positionId, uint256 _principal, uint256 _shares, uint256 _dcaBalance) internal {
        totalPrincipal -= _principal;
        address owner = _ownerOf(_positionId);

        delete positions[_positionId];
        _burn(_positionId);

        _shares = _transferShares(owner, _shares);
        _dcaBalance = _transferDcaTokens(owner, _dcaBalance);

        emit PositionClosed(msg.sender, owner, _positionId, currentEpoch, _shares, _principal, _dcaBalance);
    }

    function _calculateYieldInShares(uint256 _totalPrincipal) internal view returns (uint256) {
        uint256 balance = sharesBalance();
        uint256 totalPrincipalInShares = vault.convertToShares(_totalPrincipal);

        if (balance <= totalPrincipalInShares) revert NoYield();

        unchecked {
            // cannot underflow because of the check above
            return balance - totalPrincipalInShares;
        }
    }

    function _calculateBalances(Position storage _position, uint32 _currentEpoch)
        internal
        view
        returns (uint256 _sharesBalance, uint224 _dcaBalance)
    {
        if (_position.epoch == 0) return (0, 0);

        _sharesBalance = _position.shares;
        uint256 calculatedDcaBalance = _position.dcaBalance;
        uint256 principal = _position.principal;

        // NOTE: one iteration costs around 2700 gas
        for (uint256 i = _position.epoch; i < _currentEpoch;) {
            EpochInfo memory info = epochDetails[i];
            // save gas on sload
            uint256 sharePrice = info.sharePrice;

            // round up to minimize rounding errors and prevent underestimation when calculating user's yield
            uint256 sharesValue = _sharesBalance.mulWadUp(sharePrice);

            unchecked {
                i++;

                if (sharesValue > principal) {
                    // cannot underflow because of the check above
                    uint256 usersYield = sharesValue - principal;

                    // cannot underflow because (yield / sharePrice) <= shares (yield is always less than principal)
                    _sharesBalance -= usersYield.divWad(sharePrice);
                    // not realistic to overflow (not fit into uint224) but just in case there is check below
                    // will overflow if total users yield adds up to 2^96
                    calculatedDcaBalance += usersYield.mulWad(info.dcaPrice);
                }
            }
        }

        // make sure the calculated dca balance fits into uint224
        _dcaBalance = calculatedDcaBalance.toUint224();
    }

    /// *** helper functions ***

    function _depositToVault(address _from, uint256 _principal) internal returns (uint256 shares) {
        address(asset).safeTransferFrom(_from, address(this), _principal);

        shares = vault.deposit(_principal, address(this));
    }

    function _transferShares(address _to, uint256 _shares) internal returns (uint256) {
        // limit to available shares because of possible rounding errors
        uint256 sharesBalance_ = sharesBalance();

        if (_shares > sharesBalance_) _shares = sharesBalance_;

        address(vault).safeTransfer(_to, _shares);

        return _shares;
    }

    function _transferDcaTokens(address _to, uint256 _amount) internal returns (uint256) {
        uint256 balance = dcaBalance();

        // limit to available or revert if amount discrepancy is above set tolerance
        if (_amount > balance) {
            unchecked {
                // cannot underflow because of the check above
                if (_amount - balance > _amount.mulWad(discrepancyTolerance)) {
                    revert DCADiscrepancyAboveTolerance();
                }
            }

            _amount = balance;
        }

        address(dcaToken).safeTransfer(_to, _amount);

        return _amount;
    }

    function _buyDcaTokens(uint256 _amountIn, uint256 _dcaAmountOutMin, bytes calldata _swapData)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = dcaBalance();

        swapper.execute(address(asset), address(dcaToken), _amountIn, _dcaAmountOutMin, _swapData);

        uint256 balanceAfter = dcaBalance();

        if (balanceAfter < balanceBefore + _dcaAmountOutMin) revert AmountReceivedTooLow();

        unchecked {
            return balanceAfter - balanceBefore;
        }
    }

    function _checkApprovedOrOwner(address _caller, uint256 _positionId) internal view {
        if (!_isApprovedOrOwner(_caller, _positionId)) revert ERC721.NotOwnerNorApproved();
    }

    function _checkEpochDuration() internal view {
        if (block.timestamp < currentEpochTimestamp + epochDuration) revert EpochDurationNotReached();
    }

    function _checkMinYieldPerEpoch(uint256 _yield, uint256 _totalPrincipal) internal view {
        if (minYieldPerEpoch != 0 && _yield < _totalPrincipal.mulWad(minYieldPerEpoch)) revert InsufficientYield();
    }
}
