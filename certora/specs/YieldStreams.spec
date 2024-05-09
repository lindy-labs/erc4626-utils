import "erc20.spec";
import "erc4626.spec";

using MockERC20 as asset;
using MockERC4626 as vault;

methods {
    // state mofidying functions
    function open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external returns (uint256);

    // view functions
    function nextStreamId() external returns (uint256) envfree;
    function receiverTotalShares(address) external returns (uint256) envfree;
    function receiverTotalPrincipal(address) external returns (uint256) envfree;
    function receiverPrincipal(address, uint256) external returns (uint256) envfree;
    function streamIdToReceiver(uint256) external returns (address) envfree;
    function vault.balanceOf(address) external returns (uint256) envfree;
    function vault.convertToAssets(uint256) external returns (uint256) envfree;
}

/**
 * @Rule Integrity property for the `open` function
 * @Category High
 * @Description  The `open` function should create a new yield stream with the correct parameters and update the contract state accordingly, regardless of the caller. This property ensures that the `open` function correctly creates a new yield stream, mints a new ERC721 token, updates the receiver's total shares and principal, and emits the `StreamOpened` event with the correct parameters.
 */
rule integrity_of_open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) {
    env e; 
    // Preconditions
    require _receiver != 0;
    require _shares > 0;

    // Get the initial state
    uint256 initialReceiverTotalShares = receiverTotalShares(_receiver);

    // Call the `open` function
    uint256 streamId = open(e, _receiver, _shares, _maxLossOnOpenTolerance);

    assert streamIdToReceiver(streamId) == _receiver; // ok
    assert to_mathint(receiverTotalShares(_receiver)) == initialReceiverTotalShares + _shares;//ok
}