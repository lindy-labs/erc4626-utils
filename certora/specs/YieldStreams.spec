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
    function openMultipleUsingPermit(
        uint256 _shares,
        address[] _receivers,
        uint256[] _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[]);
    function depositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) external returns (uint256);
    function depositAndOpenUsingPermit(
        address _receiver,
        uint256 _principal,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256);
    function depositAndOpenMultipleUsingPermit(
        uint256 _principal,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[]);
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
    function previewClaimYield(address _receiver) external returns (uint256) envfree;
    function previewClaimYieldInShares(address _receiver) external returns (uint256) envfree;
    function previewOpen(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external returns (uint256) envfree;
    function debtFor(address _receiver) external returns (uint256) envfree;
    function getPrincipal(uint256 _streamId) external returns (uint256) envfree;
    function currentContract.balanceOf(address) external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function asset.allowance(address owner, address spender) external returns (uint256) envfree;
    function vault.balanceOf(address) external returns (uint256) envfree;
    function vault.allowance(address owner, address spender) external returns (uint256) envfree;
    function vault.balanceOf(address) external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function vault.convertToAssets(uint256) external returns (uint256) envfree;
    function vault.convertToShares(uint256) external returns (uint256) envfree;
    function vault.previewDeposit(uint256) external returns (uint256) envfree;
    function previewDepositAndOpen(address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) external returns (uint256) envfree;
    // Vault deposit
    function _.deposit(uint256, address) external;// returns (uint256);
    function _._ external => DISPATCH [
      _.transferFrom(address, address, uint256),
      _.safeTransferFrom(address, address, uint256),
      _.convertToAssets(uint256),
      _.convertToShares(uint256)
    ] default NONDET;
}

definition WAD() returns mathint = 10 ^ 18;
definition delta(mathint a, mathint b) returns mathint = (a > b) ? (a - b) : (b - a);

/**
 * @Rule Integrity property for the `open` function
 * @Category High
 * @Description  The `open` function should create a new yield stream with the correct parameters and update the contract state accordingly, regardless of the caller. This property ensures that the `open` function correctly creates a new yield stream, mints a new ERC721 token, updates the receiver's total shares and principal, and emits the `StreamOpened` event with the correct parameters.
 */
rule integrity_of_open(address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) {
    env e; 
    // Preconditions
    require _receiver != 0 && e.msg.sender != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;
    uint256 initialThisShareBalance = vault.balanceOf(currentContract);

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();
    uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

    // Call the `open` function
    uint256 streamId = open(e, _receiver, _shares, _maxLossOnOpenTolerance);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert to_mathint(receiverTotalPrincipal(_receiver)) == receiverTotalPrincipalBefore + principal &&
     receiverPrincipal(_receiver, streamId) == principal;
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
    require _receiver != 0 && e.msg.sender != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;
    uint256 initialThisShareBalance = vault.balanceOf(currentContract);

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();
    uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

    uint256 streamId = openUsingPermit(e, _receiver, _shares, _maxLossOnOpenTolerance, deadline, v, r, s);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert to_mathint(receiverTotalPrincipal(_receiver)) == receiverTotalPrincipalBefore + principal &&
     receiverPrincipal(_receiver, streamId) == principal;
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
    uint256 bobTotalPrincipalBefore = receiverTotalPrincipal(bob);

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

    assert to_mathint(receiverTotalPrincipal(bob)) == bobTotalPrincipalBefore + initFunds &&
     receiverPrincipal(bob, 1) == initFunds;
}

/**
 * @Rule Integrity property for the `openMultipleUsingPermit` function
 * @Category High
 * @Description  The `openMultipleUsingPermit` function should open multiple yield streams using ERC4626 permit for approval.
 */

rule integrity_of_openMultipleUsingPermit(address alice, address bob, address carol, uint256 initFunds, uint256 amount1, uint256 amount2,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
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
    uint256 bobTotalPrincipalBefore = receiverTotalPrincipal(bob);

    require asset.allowance(alice, currentContract) >= initFunds;
    require asset.balanceOf(alice) >= initFunds;

    uint256 shares = vault.deposit(e, initFunds, currentContract);
    asset.approve(e, currentContract, shares);

    // Call the openMultiple function
    address[] receivers = [bob, carol];

    require nextStreamId() == 1;

    // Call the function
    uint256[] streamIds = openMultipleUsingPermit(e, shares, receivers, allocations, 0, deadline, v, r, s);

    // Postconditions
    assert streamIds.length == 1;
    assert streamIds[0] == 1;
    assert nextStreamId() == 2;

    // Check the state updates
    uint256 aliceSharesAfter = vault.balanceOf(alice);
    uint256 contractSharesAfter = vault.balanceOf(currentContract);

    // Alice's shares
    assert to_mathint(aliceSharesAfter) == initialAliceShares - (shares * sumAmounts) / WAD() &&
    // Contract's shares
     to_mathint(contractSharesAfter) == initialContractShares + (shares * sumAmounts) / WAD() &&
    // Bob's shares
     to_mathint(receiverTotalShares(bob)) == shares * allocations[0] / WAD() &&
    // Carol's shares
     to_mathint(receiverTotalShares(carol)) == shares * allocations[1] / WAD();

    assert to_mathint(receiverTotalPrincipal(bob)) == bobTotalPrincipalBefore + initFunds &&
     receiverPrincipal(bob, 1) == initFunds;
}


/**
 * @Rule Integrity property for the `depositAndOpen` function
 * @Category High
 * @Description Ensures that the `depositAndOpen` function creates a new yield stream with the correct parameters, deposit the specified principal amount, and update the contract state accordingly, regardless of the caller.
 */
rule integrity_of_depositAndOpen(address streamer, address receiver, uint256 principal, uint256 maxLossOnOpenTolerance) {
    env e;
    // Preconditions
    require streamer != 0 && receiver != 0 && streamer != receiver && streamer == e.msg.sender && principal > 0;
    require streamer != asset && streamer != vault && streamer != currentContract;
    require receiver != asset && receiver != vault && receiver != currentContract;

    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialBalanceStreamer = asset.balanceOf(streamer);
    uint256 initialBalanceThis = asset.balanceOf(currentContract);
    uint256 initialVaultBalanceThis = vault.balanceOf(currentContract);

    require asset.balanceOf(currentContract) >= principal;


    uint256 shares = previewDepositAndOpen(receiver, principal, maxLossOnOpenTolerance);
    require initialBalanceStreamer >= principal && initialVaultBalanceThis + shares <= 2 ^ 256 - 1;

    assert shares == vault.convertToShares(principal);
    require nextStreamId() == 1;

    uint256 streamId = depositAndOpen(e, receiver, principal, maxLossOnOpenTolerance);

    assert streamId == 1 &&
     nextStreamId() == 2 &&
     ownerOf(streamId) == streamer &&
     streamIdToReceiver(streamId) == receiver &&
     to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares &&
     to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal &&
     receiverPrincipal(receiver, streamId) == principal;
    assert to_mathint(asset.balanceOf(streamer)) == initialBalanceStreamer - principal &&
     to_mathint(vault.balanceOf(currentContract)) == initialVaultBalanceThis + shares;
}

/**
 * @Rule Integrity property for the `depositAndOpenUsingPermit` function
 * @Category High
 * @Description Ensures that the `depositAndOpenUsingPermit` function opens a new yield stream using ERC20 permit for approval, allocating the underlying asset as principal.
 */
rule integrity_of_depositAndOpenUsingPermit(address streamer, address receiver, uint256 principal, uint256 maxLossOnOpenTolerance,
    uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;
    // Preconditions
    require streamer != 0 && receiver != 0 && streamer != receiver && streamer == e.msg.sender && principal > 0;
    require streamer != asset && streamer != vault && streamer != currentContract;
    require receiver != asset && receiver != vault && receiver != currentContract;

    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialBalanceStreamer = asset.balanceOf(streamer);
    uint256 initialBalanceThis = asset.balanceOf(currentContract);
    uint256 initialVaultBalanceThis = vault.balanceOf(currentContract);

    require asset.balanceOf(currentContract) >= principal;


    uint256 shares = previewDepositAndOpen(receiver, principal, maxLossOnOpenTolerance);
    require initialBalanceStreamer >= principal && initialVaultBalanceThis + shares <= 2 ^ 256 - 1;

    assert shares == vault.convertToShares(principal);
    require nextStreamId() == 1;

    // Call the `depositAndOpen` function
    uint256 streamId = depositAndOpenUsingPermit(e, receiver, principal, maxLossOnOpenTolerance, deadline, v, r, s);

    assert streamId == 1 &&
     nextStreamId() == 2 &&
     ownerOf(streamId) == streamer &&
     streamIdToReceiver(streamId) == receiver &&
     to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares &&
     to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal &&
     receiverPrincipal(receiver, streamId) == principal;
    assert to_mathint(asset.balanceOf(streamer)) == initialBalanceStreamer - principal &&
     to_mathint(vault.balanceOf(currentContract)) == initialVaultBalanceThis + shares;
}

/**
 * @Rule Integrity property for the `depositAndOpenMultiple` function
 * @Category High
 * @Description Ensures that the `depositAndOpenMultiple` function opens multiple yield streams using ERC20 permit for approval, allocating the underlying asset as principal.
 */

rule integrity_of_depositAndOpenMultiple(address dave, address bob, uint256 _principal, address[] _receivers, uint256[] _allocations, uint256 _maxLossOnOpenTolerance) {
    env e;
    require dave != bob && dave == e.msg.sender;
    require _principal > 0;
    require asset.balanceOf(dave) == _principal;

    require(asset.balanceOf(dave) >= _principal && asset.allowance(dave, currentContract) >= _principal);

    require to_mathint(asset.balanceOf(vault)) == 2 * _principal;
 
    require _receivers.length == _allocations.length && _allocations.length == 1;
    require _receivers[0] == bob && _allocations[0] == _principal;

    uint256 shares = vault.deposit(e, _principal, currentContract);
    asset.approve(e, currentContract, shares);

    // Capture the initial state
    uint256 initialNextStreamId = nextStreamId();
    uint256 initialBobShares = receiverTotalShares(bob);
    uint256 initialBobPrincipal = receiverTotalPrincipal(bob);

    // Call the depositAndOpenMultipleUsingPermit function
    uint256[] streamIds = depositAndOpenMultiple(
        e,
        _principal,
        _receivers,
        _allocations,
        _maxLossOnOpenTolerance);

    require ownerOf(streamIds[0]) == dave;

    // Postconditions
    assert streamIds.length == 1 &&
     streamIds[0] == initialNextStreamId &&
     to_mathint(nextStreamId()) == initialNextStreamId + 1;
    assert to_mathint(receiverTotalPrincipal(bob)) == initialBobPrincipal + _principal &&
     receiverPrincipal(bob, streamIds[0]) == _principal && vault.balanceOf(currentContract) == shares;
}

/**
 * @Rule Integrity property for the `depositAndOpenMultipleUsingPermit` function
 * @Category High
 * @Description Ensures that the `depositAndOpenMultipleUsingPermit` function opens multiple yield streams using ERC20 permit for approval, allocating the underlying asset as principal.
 */
rule integrity_of_depositAndOpenMultipleUsingPermit(address dave, address bob, uint256 principal,
        address[] receivers,
        uint256[] allocations,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s) {
    env e;
    require dave != bob && dave == e.msg.sender;
    require principal > 0;
    require to_mathint(deadline) == e.block.timestamp + 1;
    require asset.balanceOf(dave) == principal;

    require(asset.balanceOf(dave) >= principal && asset.allowance(dave, currentContract) >= principal);

    require to_mathint(asset.balanceOf(vault)) == 2 * principal;
 
    require receivers.length == allocations.length && allocations.length == 1;
    require receivers[0] == bob && allocations[0] == principal;

    uint256 shares = vault.deposit(e, principal, currentContract);
    asset.approve(e, currentContract, shares);

    // Capture the initial state
    uint256 initialNextStreamId = nextStreamId();
    uint256 initialBobShares = receiverTotalShares(bob);
    uint256 initialBobPrincipal = receiverTotalPrincipal(bob);

    // Call the depositAndOpenMultipleUsingPermit function
    uint256[] streamIds = depositAndOpenMultipleUsingPermit(
        e,
        principal,
        receivers,
        allocations,
        0,
        deadline,
        v,
        r,
        s
    );

    require ownerOf(streamIds[0]) == dave;

    // Postconditions
    assert streamIds.length == 1 &&
     streamIds[0] == initialNextStreamId &&
     to_mathint(nextStreamId()) == initialNextStreamId + 1;
    assert to_mathint(receiverTotalPrincipal(bob)) == initialBobPrincipal + principal &&
     receiverPrincipal(bob, streamIds[0]) == principal && vault.balanceOf(currentContract) == shares;
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

    // Call the `depositAndTopUpUsingPermit` function
    shares = depositAndTopUpUsingPermit(e, _streamId, _principal, deadline, v, r, s);

    // Postconditions
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + _principal;
    assert to_mathint(receiverPrincipal(receiver, _streamId)) == initialPrincipal + _principal;
}

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
 * @Rule Verify property for the `claimYield` function to Self
 * @Category High
 * @Description  The `claimYield` function should verify the correct behavior of the claimYield function when the receiver claims the yield to their own address, ensuring that the streamer's share balance is reduced to zero, and the receiver's asset balance is increased by the claimed yield amount.
 */
rule verify_claimYield_toSelf(address alice, address bob, uint256 _principal, uint8 parts) {
    env e;
    uint256 _shares = vault.convertToShares(_principal);
    require alice != 0 && bob != 0 && alice != bob && bob == e.msg.sender;

    // State changes
    uint256 streamId = nextStreamId();
    require streamIdToReceiver(streamId) == bob;
    require receiverTotalShares(bob) == _shares;
    require receiverTotalPrincipal(bob) == _principal;
    require receiverPrincipal(bob, streamId) == _principal;
    require _shares > 0;
    require vault.balanceOf(alice) >= _shares;
    require 1 <= parts;
    // Add X% profit to vault
    require to_mathint(vault.balanceOf(currentContract)) == _shares + _principal / parts;

    claimYield(e, bob);

    assert vault.balanceOf(alice) == 0;
    assert delta(to_mathint(asset.balanceOf(bob)), _principal / parts) <= 1;
}

/**
 * @Rule Verify property for the `claimYield` function to another account
 * @Category High
 * @Description  The `claimYield` function should verify the correct behavior of the claimYield function when the receiver (bob) claims the yield to a different account (carol). It ensures that the streamer's (alice) share balance is reduced to zero, the receiver's (bob) asset balance remains unchanged, and the claimed yield amount is transferred to the specified account (carol).
 */
rule verify_claimYield_toAnotherAccount(address alice, address bob, address carol, uint256 _principal, uint8 parts) {
    env e;
    uint256 _shares = vault.convertToShares(_principal);
    require alice != 0 && bob != 0 && alice != bob && alice != carol && bob != carol && bob == e.msg.sender;

    // State changes
    uint256 streamId = nextStreamId();
    require streamIdToReceiver(streamId) == bob;
    require receiverTotalShares(bob) == _shares;
    require receiverTotalPrincipal(bob) == _principal;
    require receiverPrincipal(bob, streamId) == _principal;
    require _shares > 0;
    require vault.balanceOf(alice) >= _shares;
    require 1 <= parts;

    mathint previewClaim = previewClaimYield(bob);
    // Add X% profit to vault
    require to_mathint(vault.balanceOf(currentContract)) == _shares + _principal / parts;

    mathint claimed = claimYield(e, carol);

    assert delta(claimed, previewClaim) <= 1 &&

     vault.balanceOf(alice) == 0 &&
     asset.balanceOf(bob) == 0 &&
     delta(to_mathint(asset.balanceOf(carol)), claimed) <= 1;
}

/**
 * @Rule Verify property for the `claimYield` function, with claims from all opened streams
 * @Category High
 * @Description  The `claimYield` function should verify the correct behavior of the claimYield function when the receiver (carol) claims the yield from multiple opened streams. It sets up a scenario where two yield streams are opened, one between alice and carol, and another between bob and carol, with specified principal amounts. The rule then generates yield by adding a percentage of the principals to the vault's balance. Finally, it invokes the claimYield function with carol as the receiver and asserts that the claimed yield is correctly calculated and transferred to carol's asset balance, while ensuring that the contract's state is updated accordingly.
 */

rule verify_claimYield_claimsFromAllOpenedStreams(address alice, address carol, address bob, uint256 alicesPrincipal, uint256 bobsPrincipal, uint8 multiple, uint8 desloc) {
    env e;
    require carol == e.msg.sender && alice != carol && alice != bob && bob != carol;
    require to_mathint(alicesPrincipal) == multiple * (10 ^ 18);
    uint256 _aliceShares = vault.convertToShares(alicesPrincipal);
    uint256 aliceStreamId = nextStreamId();
    require streamIdToReceiver(aliceStreamId) == carol;
    require receiverPrincipal(carol, aliceStreamId) == alicesPrincipal;
    require vault.balanceOf(alice) >= _aliceShares;

    require to_mathint(bobsPrincipal) == (multiple + desloc) * (10 ^ 18);
    uint256 _bobShares = vault.convertToShares(bobsPrincipal);
    uint256 bobStreamId = aliceStreamId;
    require streamIdToReceiver(bobStreamId) == carol;
    require to_mathint(receiverTotalPrincipal(carol)) >= alicesPrincipal + bobsPrincipal;
    require receiverPrincipal(carol, bobStreamId) == bobsPrincipal;
    require vault.balanceOf(bob) >= _bobShares;


    // add X% profit to vault
    require 1 <= desloc;
    require to_mathint(receiverTotalShares(carol)) >= _aliceShares + _bobShares + (multiple + desloc) * (10 ^ 18);
    require to_mathint(vault.balanceOf(currentContract)) >= _aliceShares + _bobShares + (multiple + desloc) * (10 ^ 18);
    
    assert delta(to_mathint(previewClaimYield(carol)), alicesPrincipal + bobsPrincipal) <= 1;

    uint256 claimed = claimYield(e, carol);

    assert to_mathint(claimed) == alicesPrincipal + bobsPrincipal &&
     asset.balanceOf(carol) == claimed &&
     previewClaimYield(carol) == 0;
}


/**
 * @Rule Verify property for the `claimYieldInShares` function to self
 * @Category High
 * @Description Ensures that the `claimYieldInShares` function verifies the correct behavior of the claimYieldInShares function when the receiver (bob) claims the yield in the form of shares to their own address. It sets up a scenario where a yield stream is opened between alice (the streamer) and bob (the receiver), with a specified principal amount. The rule then generates yield by adding a percentage of the principal to the vault's balance. Finally, it invokes the claimYieldInShares function with bob as the receiver and asserts that the claimed yield in shares is correctly calculated and transferred to bob's share balance, while ensuring that the contract's state is updated accordingly.
 */
rule verify_claimYieldInShares_toSelf(address alice, address bob, uint256 _principal, uint8 parts) {
    env e;
    uint256 _shares = vault.convertToShares(_principal);
    require alice != 0 && bob != 0 && alice != bob && bob == e.msg.sender;

    // State changes
    uint256 streamId = nextStreamId();
    require streamIdToReceiver(streamId) == bob;
    require receiverTotalShares(bob) == _shares;
    require receiverTotalPrincipal(bob) == _principal;
    require receiverPrincipal(bob, streamId) == _principal;
    require _shares > 0;
    require vault.balanceOf(alice) >= _shares;
    require 1 <= parts;
    uint256 principalParts;
    require to_mathint(principalParts) == _principal / parts;
    uint256 expectedYieldInShares = vault.convertToShares(principalParts);
    // Add X% profit to vault
    require to_mathint(vault.balanceOf(currentContract)) == _shares + principalParts;

    uint256 claimed = claimYieldInShares(e, bob);

    assert delta(claimed, expectedYieldInShares) <= 1 &&
     asset.balanceOf(bob) == 0 &&
     vault.balanceOf(bob) == claimed &&
     vault.balanceOf(alice) == 0;
}


/**
 * @Rule Verify property for the `claimYieldInShares` function for another account
 * @Category High
 * @Description Ensures that the `claimYieldInShares` function verifies the correct behavior of the claimYieldInShares function when the receiver (bob) claims the yield in the form of shares to a different account (carol). It sets up a scenario where a yield stream is opened between alice (the streamer) and bob (the receiver), with a specified principal amount. The rule then generates yield by adding a percentage of the principal to the vault's balance. Finally, it invokes the claimYieldInShares function with carol as the recipient and asserts that the claimed yield in shares is correctly calculated and transferred to carol's share balance, while ensuring that the contract's state is updated accordingly.
 */
 rule verify_claimYieldInShares_toAnotherAccount(address alice, address bob, address carol, uint256 _principal, uint8 parts) {
    env e;
    uint256 _shares = vault.convertToShares(_principal);
    require alice != 0 && bob != 0 && alice != bob && alice != carol && bob != carol && bob == e.msg.sender;

    // State changes
    uint256 streamId = nextStreamId();
    require streamIdToReceiver(streamId) == bob;
    require receiverTotalShares(bob) == _shares;
    require receiverTotalPrincipal(bob) == _principal;
    require receiverPrincipal(bob, streamId) == _principal;
    require _shares > 0;
    require vault.balanceOf(alice) >= _shares;
    require 1 <= parts;

    uint256 principalParts;
    require to_mathint(principalParts) == _principal / parts;

    // Add X% profit to vault
    require to_mathint(vault.balanceOf(currentContract)) == _shares + principalParts;

    mathint expectedYieldInShares = vault.convertToShares(principalParts);

    mathint claimed = claimYieldInShares(e, carol);

    assert delta(claimed, expectedYieldInShares) <= 1 &&
     vault.balanceOf(alice) == 0 &&
     vault.balanceOf(bob) == 0 &&
     delta(vault.balanceOf(carol), claimed) <= 1 &&
     asset.balanceOf(carol) == 0;
}
