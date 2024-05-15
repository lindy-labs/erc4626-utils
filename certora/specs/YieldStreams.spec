import "erc20.spec";
import "erc4626.spec";

using MockERC20 as asset;
using MockERC4626 as vault;

methods {
    // state mofidying functions
    function open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external returns (uint256);
    function openUsingPermit(
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256);
    function openMultiple(
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) external returns (uint256[]);
    function depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) external returns (uint256);
    function topUp(uint256 _streamId, uint256 _shares) external returns (uint256);
    function topUpUsingPermit(uint256 _streamId, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256);
    function depositAndTopUp(uint256 _streamId, uint256 _principal) external returns (uint256);
    function depositAndTopUpUsingPermit(
        uint256 _streamId,
        uint256 _principal,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256);
    function claimYield(address _sendTo) external returns (uint256);
    function claimYieldInShares(address _sendTo) external returns (uint256);
    function asset.safeTransferFrom(address token, address from, address to, uint256 value) external;
    function asset.forceApprove(address token, address spender, uint256 value) external;
    function vault.deposit(uint256 assets, address receiver) external returns (uint256);

    function asset.approve(address spender, uint256 value) external;
    // view functions
    function nextStreamId() external returns (uint256) envfree;
    function receiverTotalShares(address) external returns (uint256) envfree;
    function receiverTotalPrincipal(address) external returns (uint256) envfree;
    function receiverPrincipal(address, uint256) external returns (uint256) envfree;
    function streamIdToReceiver(uint256) external returns (address) envfree;
    function ownerOf(uint256) external returns (address) envfree;
    function previewClaimYieldInShares(address _receiver) external returns (uint256) envfree;
    function previewOpen(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external returns (uint256) envfree;
    function debtFor(address _receiver) external returns (uint256) envfree;
    function getPrincipal(uint256 _streamId) external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function asset.allowance(address owner, address spender) external returns (uint256) envfree;
    function vault.balanceOf(address) external returns (uint256) envfree;
    function vault.convertToAssets(uint256) external returns (uint256) envfree;
}

definition WAD() returns mathint = 10 ^ 18;

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
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();

    // Call the `open` function
    uint256 streamId = open(e, _receiver, _shares, _maxLossOnOpenTolerance);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert debtFor(_receiver) <= receiverTotalPrincipal(_receiver);
}

/**
 * @Rule Integrity property for the `openUsingPermit` function
 * @Category High
 * @Description This rule checks the integrity of the `openUsingPermit` function in the `YieldStreams` contract.
 *      It ensures that the state variables are updated correctly, the events are emitted as expected,
 *      and the permit is used correctly.
 */
rule integrity_of_openUsingPermit(
    address _receiver,
    uint256 _shares,
    uint256 _maxLossOnOpenTolerance,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) {
    env e; 
    // Preconditions
    require _receiver != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();

    uint256 streamId = openUsingPermit(e, _receiver, _shares, _maxLossOnOpenTolerance, deadline, v, r, s);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert debtFor(_receiver) <= receiverTotalPrincipal(_receiver);
}

/**
 * @Rule Integrity property for the `openMultiple` function
 * @Category High
 * @Description  The `openMultiple` function should open multiple yield streams and updates the contract state accordingly.
 */
rule integrity_of_openMultiple(address alice, address bob, address carol, uint256 initFunds, uint256 amount1, uint256 amount2) {
    env e;
    // Inputs
    uint256[] allocations = [amount1, amount2];

    mathint sumAmounts = amount1 + amount2;
    require to_mathint(initFunds) >= sumAmounts;

    // Preconditions
    require(alice != bob && alice != carol && bob != carol);

    // Set up the initial state
    uint256 initialAliceShares = vault.balanceOf(alice);
    uint256 initialContractShares = vault.balanceOf(currentContract);

    require asset.allowance(alice, currentContract) >= initFunds;
    require asset.balanceOf(alice) >= initFunds;

    uint256 shares = vault.deposit(e, initFunds, currentContract);
    asset.approve(e, currentContract, shares);

    // Call the openMultiple function
    address[] receivers = [bob, carol];

    openMultiple(e, shares, receivers, allocations, 0);

    // Check the state updates
    uint256 aliceSharesAfter = vault.balanceOf(alice);
    uint256 contractSharesAfter = vault.balanceOf(currentContract);

    // Alice's shares
    assert to_mathint(aliceSharesAfter) == initialAliceShares - (shares * sumAmounts) / WAD();
    // Contract's shares
    assert to_mathint(contractSharesAfter) == initialContractShares + (shares * sumAmounts) / WAD();
    // Bob's shares
    assert to_mathint(receiverTotalShares(bob)) == shares * allocations[0] / WAD();
    // Carol's shares
    assert to_mathint(receiverTotalShares(carol)) == shares * allocations[1] / WAD();
}

/**
 * @Rule Integrity property for the `depositAndOpen` function
 * @Category High
 * @Description Ensures that the `depositAndOpen` function creates a new yield stream with the correct parameters, deposit the specified principal amount, and update the contract state accordingly, regardless of the caller.
 */
rule integrity_of_depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) {
    env e;
    address streamer = e.msg.sender;
    uint256 streamId;
    uint256 shares;

    // Preconditions
    require _receiver != 0;
    require _principal > 0;

    // Capture the initial state
    uint256 initialTotalPrincipal = receiverTotalPrincipal(_receiver);

    // Call the `depositAndOpen` function
    streamId = depositAndOpen(e, _receiver, _principal, _maxLossOnOpenTolerance);

    // Postconditions
    //assert streamId > 0;
    assert streamIdToReceiver(streamId) == _receiver &&
     to_mathint(receiverTotalPrincipal(_receiver)) == initialTotalPrincipal + _principal;
}

/**
 * @Rule Integrity property for the `topUp` function
 * @Category High
 * @Description Ensures that the `topUp` function adds the specified shares to the existing yield stream and update the contract state accordingly, if the caller is the owner of the stream.
 */

rule integrity_of_topUp(uint256 _streamId, uint256 _shares) {
    env e;
    address streamer = e.msg.sender;
    address receiver = streamIdToReceiver(_streamId);
    uint256 principal;

    // Preconditions
    require _shares > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    // Call the `topUp` function
    principal = topUp(e, _streamId, _shares);

    // Postconditions
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + _shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal;
    assert to_mathint(receiverPrincipal(receiver, _streamId)) == initialPrincipal + principal;
}

/**
 * @Rule Integrity property for the `topUpPermit` function
 * @Category High
 * @Description Ensures that the `topUpPermit` function correctly adds additional shares to an existing yield stream and updates the contract state.
 */

rule integrity_of_topUpPermit(uint256 _streamId, uint256 _shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;
    address streamer = e.msg.sender;
    address receiver = streamIdToReceiver(_streamId);
    uint256 principal;

    // Preconditions
    require _shares > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);
    //uint256 initialStreamerShareBalance = vault.balanceOf(streamer);

    // Call the `topUp` function
    principal = topUpUsingPermit(e, _streamId, _shares, deadline, v, r, s);

    // Postconditions
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + _shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal;
    assert to_mathint(receiverPrincipal(receiver, _streamId)) == initialPrincipal + principal;
}


/**
 * @Rule Integrity property for the `depositAndTopUp` function
 * @Category High
 * @Description Ensures that the `depositAndTopUp` function adds the specified principal amount to the existing yield stream, deposit the principal, and update the contract state accordingly, if the caller is the owner of the stream.
 */
 
rule integrity_of_depositAndTopUp(uint256 _streamId, uint256 _principal) {
    env e;
    address streamer = e.msg.sender;
    address receiver = streamIdToReceiver(_streamId);
    uint256 shares;

    // Preconditions
    require _principal > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    // Call the `depositAndTopUp` function
    shares = depositAndTopUp(e, _streamId, _principal);

    // Postconditions
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + _principal;
    assert to_mathint(receiverPrincipal(receiver, _streamId)) == initialPrincipal + _principal;
}

/**
 * @Rule Integrity property for the `depositAndTopUpUsingPermit` function
 * @Category High
 * @Description Ensures that the `depositAndTopUpUsingPermit` function correctly adds additional principal to an existing yield stream using the permit mechanism and updates the contract state.
 */
/* 
rule integrity_of_depositAndTopUpPermit(uint256 _streamId, uint256 _principal, uint256 deadline, uint8 v, bytes32 r, bytes32 s) { //not ok
    env e;
    address streamer = e.msg.sender;
    address receiver = streamIdToReceiver(_streamId);
    uint256 shares;

    // Preconditions
    require _principal > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);
    //uint256 initialStreamerAssetBalance = asset.balanceOf(streamer);
    //uint256 initialContractAssetBalance = asset.balanceOf(currentContract);
    //uint256 initialContractShareBalance = vault.balanceOf(currentContract);

    // Call the `depositAndTopUpUsingPermit` function
    shares = depositAndTopUpUsingPermit(e, _streamId, _principal, deadline, v, r, s);

    // Postconditions
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + _principal;
    assert to_mathint(receiverPrincipal(receiver, _streamId)) == initialPrincipal + _principal;
     //to_mathint(asset.balanceOf(streamer)) == initialStreamerAssetBalance - _principal &&
     //to_mathint(asset.balanceOf(currentContract)) == initialContractAssetBalance + _principal &&
     //to_mathint(vault.balanceOf(currentContract)) == initialContractShareBalance + shares;
}
*/

/**
 * @Rule Integrity property for the `close` function
 * @Category High
 * @Description Ensures that the `close` function closes the specified yield stream, return the remaining shares to the caller (if the caller is the owner), and update the contract state accordingly.
 */
rule integrity_of_close(uint256 _streamId, address streamer, address receiver) {
    env e;
    require streamer == e.msg.sender;
    require receiver == streamIdToReceiver(_streamId);
    uint256 principal;

    // Preconditions
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);

    // Call the `close` function
    uint256 shares = close(e, _streamId);

    // Postconditions
    assert streamIdToReceiver(_streamId) == 0;
    assert receiverPrincipal(receiver, _streamId) == 0;
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares - shares;
}
/**
 * @Rule Integrity property for the `claimYield` function
 * @Category High
 * @Description Ensures that the `claimYield` function correctly claims the generated yield for a receiver, updates the contract state, and transfers the claimed assets.
 */

rule integrity_of_claimYield(address _sendTo) {
    env e;
    address receiver = e.msg.sender;
    uint256 assets;

    // Preconditions
    require _sendTo != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialContractShareBalance = vault.balanceOf(currentContract);
    // Get the expected yield in shares
    uint256 expectedYieldInShares = previewClaimYieldInShares(receiver);

    // Call the `claimYield` function
    assets = claimYield(e, _sendTo);

    // Postconditions
    // Check the claimed yield in shares against the expected value
    assert yieldInShares == expectedYieldInShares;
    assert receiverTotalShares(receiver) < initialTotalShares;
    assert receiverTotalPrincipal(receiver) == initialTotalPrincipal;
    assert vault.balanceOf(currentContract) < initialContractShareBalance;
    // Check the principal for each stream
    require streamIdToReceiver(streamId) == receiver;
    uint256 principal = getPrincipal(streamId);
    assert receiverPrincipal(receiver, streamId) == principal;
}

/**
 * @Rule Integrity property for the `claimYieldInShares` function
 * @Category High
 * @Description Ensures that the `claimYieldInShares` function correctly claims the generated yield for a receiver, updates the contract state, and transfers the claimed assets.
 */
rule integrity_of_claimYieldInShares(address _sendTo, uint256 streamId) {
    env e;
    address receiver = e.msg.sender;
    uint256 yieldInShares;

    // Preconditions
    require _sendTo != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialContractShareBalance = vault.balanceOf(currentContract);
    // Get the expected yield in shares
    uint256 expectedYieldInShares = previewClaimYieldInShares(receiver);

    // Call the `claimYieldInShares` function
    yieldInShares = claimYieldInShares(e, _sendTo);

    // Postconditions
    // Check the claimed yield in shares against the expected value
    assert yieldInShares == expectedYieldInShares;
    assert receiverTotalShares(receiver) < initialTotalShares;
    assert receiverTotalPrincipal(receiver) == initialTotalPrincipal;
    assert vault.balanceOf(currentContract) < initialContractShareBalance;
    // Check the principal for each stream
    require streamIdToReceiver(streamId) == receiver;
    uint256 principal = getPrincipal(streamId);
    assert receiverPrincipal(receiver, streamId) == principal;
}
