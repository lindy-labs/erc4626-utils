import "erc20.spec";
import "erc4626.spec";

using MockERC20 as asset;
using MockERC20 as assetNew;
using MockERC4626 as vault;
using MockERC4626 as vaultNew;
using YieldStreams as stream;

methods {
    // state mofidying functions
    function createFromAddress(address) external returns (address);
    function asset.mint(address to, uint256 id) external;
    function asset.approve(address account, uint256 id) external;
    function vault.approve(address account, uint256 id) external;
    function vault.deposit(uint256 assets, address receiver) external returns (uint256);
    function stream.open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external  returns (uint256);

    // view functions
    function deployedAddresses(uint256) external returns (address) envfree;
    function isDeployedFromAddress(address) external returns (bool) envfree;
    function deployedCount() external returns (uint256) envfree;
    function lastDeployedAddress() external returns (address) envfree;
    function associatedVault(address) external returns (address) envfree;
    function vault.balanceOf(address) external returns (uint256) envfree;
    function predictDeployFromAddress(address _vault) external returns (address) envfree;
    function lengthOfDeployedAddresses() external returns (uint256) envfree;
    // External functions
    function _._ external => DISPATCH [
      _.transferFrom(address, address, uint256),
      _.safeTransferFrom(address, address, uint256),
      _.convertToAssets(uint256),
      _.convertToShares(uint256)
    ] default NONDET;
}

/*
    @Invariant

    @Category: High level

    @Description:
        deployedCount == deployedAddresses.length
    @Certora report: https://prover.certora.com/output/729163/d7ff4603c11b41098591c2b402f19cce?anonymousKey=7b92ca91134e678035c59da0979689ad9012e04e
*/
invariant DeployedCountConsistencyInvariant()
  deployedCount() == lengthOfDeployedAddresses();


/**
 * @Rule Integrity property for the `create` function
 * @Category High
 * @Description  The `create` function should create a new `YieldStreams` contract instance with the given `ERC4626` vault address, use the `CREATE3` method to deploy a new instance, add the address to the `deployedAddresses` array, and increment the `deployedCount`
 */
rule integrity_of_create(address _vault, uint256 amount, address receiver, uint256 maxLossOnOpenTolerance) {
    env e;
    // Preconditions
    require e.msg.sender != 0 && _vault!= 0 && receiver!= 0 && vault == _vault;
    require !isDeployedFromAddress(_vault);
    uint256 deployedCountBefore = deployedCount();
    require amount > 0;

    // Invoke the create function
    address deployed = createFromAddress(e, _vault);
    require deployed ==  stream;

    // Postconditions
    assert isDeployedFromAddress(_vault);
    assert associatedVault(deployed) == _vault;
    assert to_mathint(deployedCount()) == deployedCountBefore + 1;
    assert lastDeployedAddress() == deployed;

    // open yield stream to confirm correcntess
    asset.mint(e, currentContract, amount);
    asset.approve(e, vault, amount);
    uint256 shares = vault.deposit(e, amount, currentContract);
    vault.approve(e, deployed, shares);

    stream.open(e, receiver, shares, maxLossOnOpenTolerance);

    assert vault.balanceOf(deployed) == shares;

}

/**
 * @Rule Integrity property for the `create` function
 * @Category High
 * @Description  The `create` function should verify the correct behavior of the `create` function when called with two different ERC4626 vaults.
 */
rule verify_create_on_two_different_vaults(address _vault, address _vaultNew) {
  env e;
  // Preconditions
  require e.msg.sender != 0;
  require asset != assetNew && vault != vaultNew;
  // The following precondition allows the vaults to be the same, but the postcondition must show this is not the case.
  require (_vault == vault || _vault == vaultNew) && (_vaultNew == vault || _vaultNew == vaultNew);
  require deployedCount() == 0;

  // Predict the deployed addresses
  address predicted = predictDeployFromAddress(_vault);
  address predictedNew = predictDeployFromAddress(_vaultNew);

  // Deploy YieldStreams instances for both vaults
  address deployed = createFromAddress(e, _vault);
  address deployedNew = createFromAddress(e, _vaultNew);

  // Postconditions
  assert _vault != _vaultNew;
  assert isDeployedFromAddress(_vault);
  assert isDeployedFromAddress(_vaultNew);
  assert deployedAddresses(0) == deployed;
  assert deployedAddresses(1) == deployedNew;
  assert predicted == deployed;
  assert predictedNew == deployedNew;
  assert deployedCount() == 2;
  assert associatedVault(deployed) == _vault;
  assert associatedVault(deployedNew) == _vaultNew;
}

/**
 * @Rule
 * @Category: Unit test
 * @Description: function `create` must revert if the vault is the zero address
*/
rule create_reverts_if_vault_is_the_zero_address() {
    env e;

    // Invoke the create function
    address deployed = createFromAddress@withrevert(e, 0); // Using the zero address as the vault address

    assert lastReverted;
}

/**
 * @Rule
 * @Category: Unit test
 * @Description: function `create` must revert if the vault is already deployed
*/
rule create_reverts_if_vault_is_already_deployed(address _vault) {
    env e;
    // Preconditions
    require isDeployedFromAddress(_vault);

    // Invoke the create function
    address deployed = createFromAddress@withrevert(e, _vault);

    assert lastReverted;
}
