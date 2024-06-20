// ERC4626 functions

methods {
    function _.asset() external                                 => DISPATCHER(true);
    function _.totalAssets() external                           => DISPATCHER(true);
    function _.convertToShares(uint256) external                => DISPATCHER(true);
    function _.convertToAssets(uint256) external                => DISPATCHER(true);
    function _.maxDeposit(address) external                     => DISPATCHER(true);
    function _.previewDeposit(uint256) external                 => DISPATCHER(true);
    function _.deposit(uint256, address) external               => DISPATCHER(true);
    function _.maxMint(address) external                        => DISPATCHER(true);
    function _.previewMint(uint256) external                    => DISPATCHER(true);
    function _.mint(uint256, address) external                  => DISPATCHER(true);
    function _.maxWithdraw(address) external                    => DISPATCHER(true);
    function _.previewWithdraw(uint256) external                => DISPATCHER(true);
    function _.withdraw(uint256, address, address) external     => DISPATCHER(true);
    function _.maxRedeem(address) external                      => DISPATCHER(true);
    function _.previewRedeem(uint256) external                  => DISPATCHER(true);
    function _.redeem(uint256, address, address) external       => DISPATCHER(true);
}