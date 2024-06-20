# Properties of YieldStreamsFactory

## Overview of the YieldStreamsFactory

The smart contract YieldStreamsFactory provides a way to deploy and manage instances of the `YieldStreams` contract, which is likely related to a yield streaming system using `ERC4626` vaults. The factory pattern allows for the creation of multiple instances of the `YieldStreams` contract, each associated with a different `ERC4626` vault..

It has mainly the following state variables:
* `deployedAddresses` (type `address[]`), An array that stores the addresses of all deployed `YieldStreams` contract instances.
* `deployedCount` (type `uint256`), A counter that keeps track of the number of deployed `YieldStreams` contract instances.


It has the following external/functions that change state variables:
* `create(IERC4626 _vault) public virtual returns (YieldStreams deployed)`, This function creates a new `YieldStreams` contract instance with the given `ERC4626` vault address. If an instance already exists, it reverts with an `AlreadyDeployed` error. Otherwise, it uses the `CREATE3` method to deploy a new instance, adds the address to the `deployedAddresses` array, increments the `deployedCount`, and emits the `Deployed` event.

It has the following view functions, which do not change state:
* `predictDeploy(IERC4626 _vault) public view returns (YieldStreams predicted)`, This function predicts the address of the `YieldStreams` contract for a given `ERC4626` vault address using `CREATE3.getDeployed`, based on the `salt` and `factory` contract address.
* `isDeployed(IERC4626 _vault) public view returns (bool)`, This function checks if a `YieldStreams` contract has been deployed for a given `ERC4626` vault address. It returns true if the predicted address has non-zero code, indicating a contract exists, and false otherwise.
* `getSalt(IERC4626 _vault) public pure returns (bytes32)`, This function returns the `salt` for the `CREATE3` deployment of the `YieldStreams` contract, calculated as the `keccak256` hash of the `ERC4626` vault address encoded as bytes.

## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
| 1 | `integrity_of_create(address _vault, uint256 amount, address receiver, uint256 maxLossOnOpenTolerance)` should create a new `YieldStreams` contract instance with the given `ERC4626` vault address, use the `CREATE3` method to deploy a new instance, add the address to the `deployedAddresses` array, and increment the `deployedCount` | high level | high | Y | Y | [Link](https://prover.certora.com/output/729163/6aef79050dbc4f848ae05dce290ec294?anonymousKey=45508808cde47f6d66905b39fd21f2909e6b1be3) |
| 2 | `verify_create_on_two_different_vaults(address _vault, address _vaultNew)` should should verify the correct behavior of the `create` function when called with two different ERC4626 vaults. | high level | high | Y | Y | [Link](https://prover.certora.com/output/729163/b56141b1d63d47af8fe44a3fccbf1574?anonymousKey=08a3b472ae321566cbd96c39e192c36e0242cf1b) |
| 3 | `create_reverts_if_vault_is_the_zero_address()` should revert if the vault is set to the zero address | Medium level | unit test | Y | Y | [Link](https://prover.certora.com/output/729163/5fec3136e8d24ff5b847d5b9dd795026?anonymousKey=f35bd78303ee967272ee3d85a4a28701de931ee2) |
| 4 | `create_reverts_if_vault_is_already_deployed()` should revert if the vault is already deployed | Medium level | unit test | Y | Y | [Link](https://prover.certora.com/output/729163/5fec3136e8d24ff5b847d5b9dd795026?anonymousKey=f35bd78303ee967272ee3d85a4a28701de931ee2) |
