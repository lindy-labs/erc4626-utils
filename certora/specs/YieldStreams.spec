import "erc20.spec";
import "erc4626.spec";

using MockERC20 as asset;
using MockERC4626 as vault;

methods {
    // state mofidying functions
    function open(address _owner, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) external returns (uint256);
    function openUsingPermit(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256);
    function openMultiple(
        address _owner,
        uint256 _shares,
        address[] calldata _receivers,
        uint256[] calldata _allocations,
        uint256 _maxLossOnOpenTolerance
    ) external returns (uint256[]);
    function openMultipleUsingPermit(
        address _owner,
        uint256 _shares,
        address[] _receivers,
        uint256[] _allocations,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256[]);
    function depositAndOpen(address _owner, address _receiver, uint256 _principal, uint256 _maxLossOnOpenTolerance) external returns (uint256);
    function depositAndOpenUsingPermit(
        address _owner,
        address _receiver,
        uint256 _principal,
        uint256 _maxLossOnOpenTolerance,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256);
    function depositAndOpenMultipleUsingPermit(
        address _owner,
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
    function claimYield(address _receiver, address _sendTo) external returns (uint256);
    function claimYieldInShares(address _receiver, address _sendTo) external returns (uint256);
    function setTokenCID(uint256 _tokenId, string memory _cid) external;
    function approveClaimer(address _claimer) external;
    function revokeClaimer(address _claimer) external;
    function asset.safeTransferFrom(address token, address from, address to, uint256 value) external;
    function asset.forceApprove(address token, address spender, uint256 value) external;
    function vault.deposit(uint256 assets, address receiver) external returns (uint256);

    function asset.approve(address spender, uint256 value) external;
    // view functions
    function vault.totalAssets() external returns (uint256) envfree;
    function vault.totalSupply() external returns (uint256) envfree;
    function vault.previewRedeem(uint256 shares) external returns (uint256) envfree;
    function compareStrings(string, string) external returns (bool) envfree;
    function receiverToApprovedClaimers(address, address ) external returns (bool) envfree;
    function isApprovedClaimer(address _claimer, address _receiver) external returns (bool) envfree;
    function nextStreamId() external returns (uint256) envfree;
    function receiverTotalShares(address) external returns (uint256) envfree;
    function receiverTotalPrincipal(address) external returns (uint256) envfree;
    function receiverPrincipal(address, uint256) external returns (uint256) envfree;
    function streamIdToReceiver(uint256) external returns (address) envfree;
    function ownerOf(uint256) external returns (address) envfree;
    function tokenCIDs(uint256) external returns (string) envfree;
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
rule integrity_of_open(address _owner, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) {
    env e; 
    // Preconditions
    require _receiver != 0 && e.msg.sender != 0 && _owner != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;
    uint256 initialOwnerShareBalance = vault.balanceOf(_owner);

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();
    uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

    // Call the `open` function
    uint256 streamId = open(e, _owner, _receiver, _shares, _maxLossOnOpenTolerance);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert to_mathint(receiverTotalPrincipal(_receiver)) == receiverTotalPrincipalBefore + principal;
    Assert receiverPrincipal(_receiver, streamId) == principal;
    assert to_mathint(vault.balanceOf(e.msg.sender)) == initialStreamerShareBalance - _shares;
    assert ownerOf(streamId) == _owner;
    assert vault.balanceOf(_owner) == initialOwnerShareBalance;
}

/**
 * @Rule Integrity property for the `openUsingPermit` function
 * @Category High
 * @Description This rule checks the integrity of the `openUsingPermit` function in the `YieldStreams` contract.
 *      It ensures that the state variables are updated correctly, the events are emitted as expected,
 *      and the permit is used correctly.
 */
rule integrity_of_openUsingPermit(
    address _owner,
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
    require _receiver != 0 && e.msg.sender != 0 && _owner != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;
    uint256 initialOwnerShareBalance = vault.balanceOf(_owner);

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();
    uint256 principal = previewOpen(_receiver, _shares, _maxLossOnOpenTolerance);

    uint256 streamId = openUsingPermit(e, _owner, _receiver, _shares, _maxLossOnOpenTolerance, deadline, v, r, s);
    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert to_mathint(receiverTotalPrincipal(_receiver)) == receiverTotalPrincipalBefore + principal;
    assert receiverPrincipal(_receiver, streamId) == principal;
    assert to_mathint(vault.balanceOf(e.msg.sender)) == initialStreamerShareBalance - _shares;
    assert ownerOf(streamId) == _owner;
    assert vault.balanceOf(_owner) == initialOwnerShareBalance;
}

/**
 * @Rule Integrity property for the `openMultiple` function
 * @Category High
 * @Description  The `openMultiple` function should open multiple yield streams and updates the contract state accordingly.
 */
rule integrity_of_openMultiple(address _owner, address alice, address bob, address carol, uint256 initFunds, uint256 amount1, uint256 amount2) {
    env e;
    // Inputs
    uint256[] allocations = [amount1, amount2];

    mathint sumAmounts = amount1 + amount2;
    require to_mathint(initFunds) >= sumAmounts;

    // Preconditions
    require _owner != 0 && alice != 0 && bob != 0 && carol != 0;
    require(alice != bob && alice != carol && bob != carol);

    // Set up the initial state
    uint256 initialAliceShares = vault.balanceOf(alice);
    uint256 initialOwnerShares = vault.balanceOf(_owner);

    require asset.allowance(alice, currentContract) >= initFunds;
    require asset.balanceOf(alice) >= initFunds;

    uint256 shares = vault.deposit(e, initFunds, currentContract);
    asset.approve(e, currentContract, shares);
    uint256 bobTotalPrincipalBefore = receiverTotalPrincipal(bob);
    uint256 carolTotalPrincipalBefore = receiverTotalPrincipal(carol);

    // Call the openMultiple function
    address[] receivers = [bob, carol];

    require nextStreamId() == 1;

    uint256[] streamIds = openMultiple(e, _owner, shares, receivers, allocations, 0);

    // Postconditions
    assert streamIds.length == 1;
    assert streamIds[0] == 1;
    assert nextStreamId() == 2;
    // Check the state updates
    uint256 aliceSharesAfter = vault.balanceOf(alice);
    uint256 ownerSharesAfter = vault.balanceOf(_owner);
    uint256 contractSharesAfter = vault.balanceOf(currentContract);

    // Alice's shares
    assert to_mathint(aliceSharesAfter) == initialAliceShares - (shares * sumAmounts) / WAD();
    // Owner's shares (unchanged)
    assert ownerSharesAfter == initialOwnerShares;
    // Contract's shares
    assert to_mathint(contractSharesAfter) == (shares * sumAmounts) / WAD();
    // Bob's shares
    assert to_mathint(receiverTotalShares(bob)) == shares * allocations[0] / WAD();
    // Carol's shares
    assert to_mathint(receiverTotalShares(carol)) == shares * allocations[1] / WAD();

    assert to_mathint(receiverTotalPrincipal(bob)) == bobTotalPrincipalBefore + initFunds * allocations[0] / WAD();
    assert receiverPrincipal(bob, 1) == initFunds;

    assert to_mathint(receiverTotalPrincipal(carol)) == carolTotalPrincipalBefore + initFunds * allocations[0] / WAD();
    assert receiverPrincipal(carol, 1) == initFunds;
}

/**
 * @Rule Integrity property for the `openMultipleUsingPermit` function
 * @Category High
 * @Description  The `openMultipleUsingPermit` function should open multiple yield streams using ERC4626 permit for approval.
 */

rule integrity_of_openMultipleUsingPermit(address _owner, address alice, address bob, address carol, uint256 initFunds, uint256 amount1, uint256 amount2,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;
    // Inputs
    uint256[] allocations = [amount1, amount2];

    mathint sumAmounts = amount1 + amount2;
    require to_mathint(initFunds) >= sumAmounts;

    // Preconditions
    require _owner != 0 && alice != 0 && bob != 0 && carol != 0;
    require(alice != bob && alice != carol && bob != carol);

    // Set up the initial state
    uint256 initialAliceShares = vault.balanceOf(alice);
    uint256 initialOwnerShares = vault.balanceOf(_owner);

    require asset.allowance(alice, currentContract) >= initFunds;
    require asset.balanceOf(alice) >= initFunds;

    uint256 shares = vault.deposit(e, initFunds, currentContract);
    asset.approve(e, currentContract, shares);
    uint256 bobTotalPrincipalBefore = receiverTotalPrincipal(bob);
    uint256 carolTotalPrincipalBefore = receiverTotalPrincipal(carol);

    // Call the openMultiple function
    address[] receivers = [bob, carol];

    require nextStreamId() == 1;

    // Call the function
    uint256[] streamIds = openMultipleUsingPermit(e, _owner, shares, receivers, allocations, 0, deadline, v, r, s);

    // Postconditions
    assert streamIds.length == 1;
    assert streamIds[0] == 1;
    assert nextStreamId() == 2;
    // Check the state updates
    uint256 aliceSharesAfter = vault.balanceOf(alice);
    uint256 ownerSharesAfter = vault.balanceOf(_owner);
    uint256 contractSharesAfter = vault.balanceOf(currentContract);

    // Alice's shares
    assert to_mathint(aliceSharesAfter) == initialAliceShares - (shares * sumAmounts) / WAD();
    // Owner's shares (unchanged)
    assert ownerSharesAfter == initialOwnerShares;
    // Contract's shares
    assert to_mathint(contractSharesAfter) == (shares * sumAmounts) / WAD();
    // Bob's shares
    assert to_mathint(receiverTotalShares(bob)) == shares * allocations[0] / WAD();
    // Carol's shares
    assert to_mathint(receiverTotalShares(carol)) == shares * allocations[1] / WAD();

    assert to_mathint(receiverTotalPrincipal(bob)) == bobTotalPrincipalBefore + initFunds * allocations[0] / WAD();
    assert receiverPrincipal(bob, 1) == initFunds;

    assert to_mathint(receiverTotalPrincipal(carol)) == carolTotalPrincipalBefore + initFunds * allocations[0] / WAD();
    assert receiverPrincipal(carol, 1) == initFunds;
}

/**
 * @Rule Integrity property for the `depositAndOpen` function
 * @Category High
 * @Description Ensures that the `depositAndOpen` function creates a new yield stream with the correct parameters, deposit the specified principal amount, and update the contract state accordingly, regardless of the caller.
 */
rule integrity_of_depositAndOpen(address owner, address streamer, address receiver, uint256 principal, uint256 maxLossOnOpenTolerance) {
    env e;
    // Preconditions
    require owner != 0;
    require streamer != 0 && receiver != 0 && streamer != receiver && streamer == e.msg.sender && principal > 0;

    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialBalanceStreamer = asset.balanceOf(streamer);
    uint256 initialBalanceThis = asset.balanceOf(currentContract);
    uint256 initialVaultBalanceThis = vault.balanceOf(currentContract);
    uint256 initialBalanceOwner = asset.balanceOf(owner);

    require asset.balanceOf(currentContract) >= principal;
    require nextStreamId() == 1;
    require initialBalanceOwner >= principal;

    uint256 shares = previewDepositAndOpen(receiver, principal, maxLossOnOpenTolerance);
    require initialBalanceStreamer >= principal && initialVaultBalanceThis + shares <= 2 ^ 256 - 1;

    uint256 streamId = depositAndOpen(e, owner, receiver, principal, maxLossOnOpenTolerance);

    assert streamId == 1;
    assert nextStreamId() == 2;
    assert ownerOf(streamId) == streamer;
    assert streamIdToReceiver(streamId) == receiver;
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal;
    assert receiverPrincipal(receiver, streamId) == principal;
    assert to_mathint(asset.balanceOf(streamer)) == initialBalanceStreamer - principal;
    assert to_mathint(vault.balanceOf(currentContract)) == initialVaultBalanceThis + shares;
    assert to_mathint(asset.balanceOf(owner)) == initialBalanceOwner - principal;
}

/**
 * @Rule Integrity property for the `depositAndOpenUsingPermit` function
 * @Category High
 * @Description Ensures that the `depositAndOpenUsingPermit` function opens a new yield stream using ERC20 permit for approval, allocating the underlying asset as principal.
 */
rule integrity_of_depositAndOpenUsingPermit(address owner, address streamer, address receiver, uint256 principal, uint256 maxLossOnOpenTolerance,
    uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;
    // Preconditions
    require owner != 0;
    require streamer != 0 && receiver != 0 && streamer != receiver && streamer == e.msg.sender && principal > 0;

    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialBalanceStreamer = asset.balanceOf(streamer);
    uint256 initialBalanceThis = asset.balanceOf(currentContract);
    uint256 initialVaultBalanceThis = vault.balanceOf(currentContract);
    uint256 initialBalanceOwner = asset.balanceOf(owner);

    require asset.balanceOf(currentContract) >= principal;
    require initialBalanceOwner >= principal;

    uint256 shares = previewDepositAndOpen(receiver, principal, maxLossOnOpenTolerance);
    require initialBalanceStreamer >= principal && initialVaultBalanceThis + shares <= 2 ^ 256 - 1;

    assert shares == vault.convertToShares(principal);
    require nextStreamId() == 1;

    // Call the `depositAndOpen` function
    uint256 streamId = depositAndOpenUsingPermit(e, owner, receiver, principal, maxLossOnOpenTolerance, deadline, v, r, s);

    assert streamId == 1;
    assert nextStreamId() == 2;
    assert ownerOf(streamId) == streamer;
    assert streamIdToReceiver(streamId) == receiver;
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares + shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal + principal;
    assert receiverPrincipal(receiver, streamId) == principal;
    assert to_mathint(asset.balanceOf(streamer)) == initialBalanceStreamer - principal;
    assert to_mathint(vault.balanceOf(currentContract)) == initialVaultBalanceThis + shares;
    assert to_mathint(asset.balanceOf(owner)) == initialBalanceOwner - principal;
}

/**
 * @Rule Integrity property for the `depositAndOpenMultiple` function
 * @Category High
 * @Description Ensures that the `depositAndOpenMultiple` function opens multiple yield streams using ERC20 permit for approval, allocating the underlying asset as principal.
 */
rule integrity_of_depositAndOpenMultiple(address owner, address dave, address bob, uint256 _principal, address[] _receivers, uint256[] _allocations, uint256 _maxLossOnOpenTolerance) {
    env e;
    require owner != 0;
    require dave != bob && dave == e.msg.sender;
    require _principal > 0;
    require asset.balanceOf(dave) == _principal;

    require(asset.balanceOf(dave) >= _principal && asset.allowance(dave, currentContract) >= _principal);
    uint256 initialBalanceOwner = asset.balanceOf(owner);
    require initialBalanceOwner >= _principal;

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
        owner,
        _principal,
        _receivers,
        _allocations,
        _maxLossOnOpenTolerance);

    require ownerOf(streamIds[0]) == dave;

    // Postconditions
    assert streamIds.length == 1;
    assert streamIds[0] == initialNextStreamId;
    assert to_mathint(nextStreamId()) == initialNextStreamId + 1;
    assert to_mathint(receiverTotalPrincipal(bob)) == initialBobPrincipal + _principal;
    assert receiverPrincipal(bob, streamIds[0]) == _principal && vault.balanceOf(currentContract) == shares;
    assert to_mathint(asset.balanceOf(owner)) == initialBalanceOwner - _principal;
}

/**
 * @Rule Integrity property for the `depositAndOpenMultipleUsingPermit` function
 * @Category High
 * @Description Ensures that the `depositAndOpenMultipleUsingPermit` function opens multiple yield streams using ERC20 permit for approval, allocating the underlying asset as principal.
 */
rule integrity_of_depositAndOpenMultipleUsingPermit(address owner, address dave, address bob, uint256 principal,
        address[] receivers,
        uint256[] allocations,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s) {
    env e;
    require owner != 0;
    require dave != bob && dave == e.msg.sender;
    require principal > 0;
    require to_mathint(deadline) == e.block.timestamp + 1;
    require asset.balanceOf(dave) == principal;

    require(asset.balanceOf(dave) >= principal && asset.allowance(dave, currentContract) >= principal);
    uint256 initialBalanceOwner = asset.balanceOf(owner);
    require initialBalanceOwner >= principal;

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
        owner,
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
    assert streamIds.length == 1;
    assert streamIds[0] == initialNextStreamId;
    assert to_mathint(nextStreamId()) == initialNextStreamId + 1;
    assert to_mathint(receiverTotalPrincipal(bob)) == initialBobPrincipal + principal;
    assert receiverPrincipal(bob, streamIds[0]) == principal && vault.balanceOf(currentContract) == shares;
    assert to_mathint(asset.balanceOf(owner)) == initialBalanceOwner - principal;
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

    // Preconditions
    require _shares > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    // Call the `topUp` function
    uint256 principal = topUp(e, _streamId, _shares);

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
    uint256 principal = topUpUsingPermit(e, _streamId, _shares, deadline, v, r, s);

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

    // Preconditions
    require _principal > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    // Call the `depositAndTopUp` function
    uint256 shares = depositAndTopUp(e, _streamId, _principal);

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

    // Preconditions
    require _principal > 0;
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    // Call the `depositAndTopUpUsingPermit` function
    uint256 shares = depositAndTopUpUsingPermit(e, _streamId, _principal, deadline, v, r, s);

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

    // Preconditions
    require ownerOf(_streamId) == streamer;
    require receiver != 0;

    // Capture the initial state
    uint256 initialTotalShares = receiverTotalShares(receiver);
    uint256 initialTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialPrincipal = receiverPrincipal(receiver, _streamId);

    require initialTotalPrincipal >= initialPrincipal;

    // Call the `close` function
    uint256 shares = close(e, _streamId);

    // Postconditions
    assert streamIdToReceiver(_streamId) == 0;
    assert receiverPrincipal(receiver, _streamId) == 0;
    assert to_mathint(receiverTotalShares(receiver)) == initialTotalShares - shares;
    assert to_mathint(receiverTotalPrincipal(receiver)) == initialTotalPrincipal - initialPrincipal;
    assert tokenCIDs(_streamId).length == 0;
}

/**
 * @Rule Integrity property for the `claimYield` function
 * @Category High
 * @Description The `claimYield` function should transfer the correct amount of yield to the specified address, update the receiverTotalShares mapping correctly, and emit the YieldClaimed event with the correct parameters
 */
rule integrity_of_claimYield(address _receiver, address _sendTo) {
    env e;
    // Preconditions
    // The `_sendTo` address should not be the zero address
    require _sendTo != 0 && e.msg.sender == _receiver;
    require isApprovedClaimer(e.msg.sender, _receiver);

    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 expectedAssets = vault.previewRedeem(yieldInShares);

    // Call the `claimYield` function
    uint256 assets = claimYield(e, _receiver, _sendTo);

    // Postconditions
    assert(assets == expectedAssets);
    // The `claimYield` function should update the receiverTotalShares mapping correctly
    asset to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore - yieldInShares;
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

    claimYield(e, bob, bob);

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

    claimYield(e, bob, carol);

    mathint claimed = to_mathint(asset.balanceOf(carol));

    assert delta(claimed, previewClaim) <= 1;
    assert vault.balanceOf(alice) == 0;
    assert asset.balanceOf(bob) == 0;
    assert delta(claimed, previewClaim) <= 1;
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
    
    uint256 claimed = claimYield(e, carol, carol);

    assert to_mathint(claimed) == alicesPrincipal + bobsPrincipal;
    assert asset.balanceOf(carol) == claimed;
    assert previewClaimYield(carol) == 0;
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

    uint256 claimed = claimYieldInShares(e, bob, bob);

    assert delta(claimed, expectedYieldInShares) <= 1;
    assert asset.balanceOf(bob) == 0;
    assert to_mathint(vault.balanceOf(bob)) == _shares + claimed;
    assert vault.balanceOf(alice) == 0;
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

    claimYieldInShares(e, bob, carol);

    mathint claimed = to_mathint(vault.balanceOf(carol));

    assert delta(claimed, expectedYieldInShares) <= 1;
    assert vault.balanceOf(alice) == 0;
    assert vault.balanceOf(bob) == _shares;
    assert delta(claimed, expectedYieldInShares) <= 1;
    assert asset.balanceOf(carol) == 0;
}

/**
 * @Rule Integrity property for the `setTokenCID` function
 * @Category High
 * @Description  The `setTokenCID` function should ensure that the setTokenCID function only allows the contract owner to update the token CID
 **/
rule integrity_of_setTokenCID(uint256 _tokenId, string _cid) {
    env e; 
    // Preconditions
    // The `setTokenCID` function should be called by the owner of the token
    require(ownerOf(_tokenId) == e.msg.sender);
    // The `setTokenCID` function should set the token's CID
    require _cid.length > 0;

    // Call the `setTokenCID` function
    setTokenCID(e, _tokenId, _cid);

    // Postconditions
    // The `setTokenCID` function should set the token's CID
    assert(compareStrings(tokenCIDs(_tokenId), _cid));
}

/**
 * @Rule Integrity property for the `approveClaimer` function
 * @Category High
 * @Description The `approveClaimer` function should update the receiverToApprovedClaimers mapping correctly and revert if the _claimer address is the zero address
 */
rule integrity_of_approveClaimer(address receiver, address _claimer) {
    env e;
    // Precondition
    // The `approveClaimer` function should be callable by the `receiver` address
    require receiver == e.msg.sender;
    // The `_claimer` address should not be the zero address
    require _claimer != 0;

    // Call the `approveClaimer` function
    approveClaimer(e, _claimer);

    // Postconditions
    // The `approveClaimer` function should update the receiverToApprovedClaimers mapping correctly
    assert receiverToApprovedClaimers(receiver, _claimer);
}

/**
 * @Rule Integrity property for the `revokeClaimer` function
 * @Category High
 * @Description The `revokeClaimer` function should update the receiverToApprovedClaimers mapping correctly and revert if the _claimer address is the zero address
 */
rule integrity_of_revokeClaimer(address receiver, address _claimer) {
    env e;
    // Precondition
    // receiver should be the caller
    require receiver == e.msg.sender;
    // The `_claimer` address should not be the zero address
    require _claimer != 0;

    // Call the `revokeClaimer` function
    revokeClaimer(e, _claimer);

    // Postconditions
    // The `revokeClaimer` function should update the receiverToApprovedClaimers mapping correctly
    assert(!receiverToApprovedClaimers(receiver, _claimer));
}

/**
 * @Rule Verify `yield` calculation when `totalshares` is greater than `totalprincipal`
 * @Category Low
 * @Descritption The yield should be calculated correctly when the total shares is greater than the total principal.
 */
rule verify_yieldcalculation_when_totalshares_is_greater_than_totalprincipal(address receiver) {
    env e;
    uint256 principal = receiverTotalPrincipal(receiver);
    uint256 currentValue = vault.convertToAssets(receiverTotalShares(receiver));
    uint256 yield;
    require currentValue > principal;
    require to_mathint(yield) == currentValue - principal;

    assert(previewClaimYield(receiver) == yield);
}

/**
 * @Rule Composition of `approve` and `revokeClaimer`
 * @Category High
 * @Description Revoke claimer should revoke approval created by approveClaimer.
 */

rule composition_of_approve_and_revokeClaimer(address receiver, address _claimer) {
    env e;
    require receiver == e.msg.sender;
    require _claimer != 0;
    approveClaimer(e, _claimer);
    assert receiverToApprovedClaimers(receiver, _claimer);
    revokeClaimer(e, _claimer);
    assert(!receiverToApprovedClaimers(receiver, _claimer));
}

/**
 * @Rule Composition of `open` and `topUp`
 * @Category High
 * @Description Composition of Open and TopUp
 */
rule composition_of_open_and_topUp(address _owner, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance, uint256 _additionalShares) {
    env e;
    // Preconditions
    require _receiver != 0 && e.msg.sender != 0 && _owner != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;
    uint256 initialOwnerShareBalance = vault.balanceOf(_owner);

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);
    uint256 nextStreamIdBefore = nextStreamId();
    
    uint256 streamId = open(e, _owner, _receiver, _shares, _maxLossOnOpenTolerance);

    uint256 principal = topUp(e, streamId, _additionalShares);

    uint256 nextStreamIdAfter = nextStreamId();

    assert streamIdToReceiver(streamId) == _receiver;
    assert  to_mathint(receiverTotalShares(_receiver)) == receiverTotalSharesBefore + _shares;
    assert  to_mathint(nextStreamId()) == nextStreamIdBefore + 1;
    assert  to_mathint(vault.balanceOf(e.msg.sender)) == initialStreamerShareBalance - _shares;
    assert  ownerOf(streamId) == _owner;
    assert  vault.balanceOf(_owner) == initialOwnerShareBalance;
    assert to_mathint(receiverTotalShares(_receiver)) == _shares + _additionalShares;
    assert receiverPrincipal(_receiver, streamId) == getPrincipal(streamId);
    assert principal == vault.convertToAssets(_additionalShares);
}

/**
 * @Rule Composition of `open` and `close`
 * @Category High
 * @Description Opening and closing a stream should be atomic
 */
rule composition_of_open_and_close(address _owner, address _receiver, uint256 _shares, uint256 _maxLossOnOpenTolerance) {
    env e; 
    // Preconditions
    require _receiver != 0 && e.msg.sender != 0 && _owner != 0;
    require _shares > 0;
    require _maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= _shares;

    // Get the initial state
    uint256 receiverTotalSharesBefore = receiverTotalShares(_receiver);
    uint256 receiverTotalPrincipalBefore = receiverTotalPrincipal(_receiver);

    uint256 streamId = open(e, _owner, _receiver, _shares, _maxLossOnOpenTolerance);

    uint256 closedShares = close(e, streamId);

    // Postconditions
    assert streamIdToReceiver(streamId) == 0;
    assert receiverPrincipal(_receiver, streamId) == 0;
    assert receiverTotalShares(_receiver) == receiverTotalSharesBefore;
    assert tokenCIDs(streamId).length == 0;
    assert receiverTotalPrincipal(_receiver) == receiverTotalPrincipalBefore;
}

/**
 * @Rule relationshiip between `previewOpen` and `previewDepositAndOpen`
 * @Category High-level
 * @Description Establishes the relationship between PreviewOpen and PreviewDepositAndOpen
 */
rule relationshiip_between_previewOpen_and_previewDepositAndOpen(env e, address receiver, uint256 shares, uint256 maxLossOnOpenTolerance) {
    require shares > 0;
    uint256 principal = previewOpen(receiver, shares, maxLossOnOpenTolerance);
    uint256 depositAndOpen = previewDepositAndOpen(receiver, principal, maxLossOnOpenTolerance);
    assert depositAndOpen == vault.convertToShares(principal);
}

/**
 * @Rule Composition of `topUp` and `close`
 * @Category High-level
 * @Description Topping up a yield stream and then immediately closing it should leave the contract state unchanged
 */
rule composition_of_topUp_and_close(uint256 streamId, uint256 shares) {
    env e;
    // Get the initial state
    address receiver = streamIdToReceiver(streamId);
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialReceiverPrincipal = receiverPrincipal(receiver, streamId);

    // Top up the stream
    topUp(e, streamId, shares);

    // Close the stream immediately
    close(e, streamId);

    // Assert that the state is unchanged
    assert receiverTotalShares(receiver) == initialReceiverTotalShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
    assert receiverPrincipal(receiver, streamId) == initialReceiverPrincipal;
}

/**
 * @Rule Composition of `deposit`, `topUp` and `close`
 * @Category High-level
 * @Description Depositing additional principal and topping up a yield stream, and then immediately closing it should leave the contract state unchanged
 */
rule composition_of_deposit_and_topUp_and_close(uint256 streamId, uint256 principal) {
    env e;
    // Get the initial state
    address receiver = streamIdToReceiver(streamId);
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 initialReceiverPrincipal = receiverPrincipal(receiver, streamId);

    // Deposit and top up the stream
    depositAndTopUp(e, streamId, principal);

    // Close the stream immediately
    close(e, streamId);

    // Assert that the state is unchanged
    assert receiverTotalShares(receiver) == initialReceiverTotalShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
    assert receiverPrincipal(receiver, streamId) == initialReceiverPrincipal;
}

/**
 * @Rule Composition of `openMultiple` and `close`
 * @Category High-level
 * @Description Opens multiple streams and closes them
*/
rule composition_of_openMultiple_and_close(address owner, uint256 shares, address[] receivers, uint256[] allocations, uint256 maxLossOnOpenTolerance) {
    env e;
    require (shares > 0);
    require (receivers.length == allocations.length);
    require (receivers.length == 2);
    uint256[] initialReceiverTotalShares = [ receiverTotalShares(receivers[0]), receiverTotalShares(receivers[1]) ];
    uint256[] initialReceiverTotalPrincipal = [ receiverTotalPrincipal(receivers[0]), receiverTotalPrincipal(receivers[1]) ];
    uint256[] streamIds = openMultiple(e, owner, shares, receivers, allocations, maxLossOnOpenTolerance);
    close(e, streamIds[0]);
    close(e, streamIds[1]);
    assert receiverTotalShares(receivers[0]) == initialReceiverTotalShares[0];
    assert receiverTotalPrincipal(receivers[0]) == initialReceiverTotalPrincipal[0];
    assert receiverTotalShares(receivers[1]) == initialReceiverTotalShares[1];
    assert receiverTotalPrincipal(receivers[1]) == initialReceiverTotalPrincipal[1];
}

/**
 * @Rule Composition of `open`, `topUp` and `close`
 * @Category High-level
 * @Description Open, top up, and close a stream.
*/
rule composition_of_open_and_topUp_and_close(address owner, address receiver, uint256 shares, uint256 topUpShares, uint256 maxLossOnOpenTolerance) {
    env e;
    require owner != 0 && receiver != 0;
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);
    uint256 streamId = open(e, owner, receiver, shares, maxLossOnOpenTolerance);
    topUp(e, streamId, topUpShares);
    close(e, streamId);
    assert receiverTotalShares(receiver) == initialReceiverTotalShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
    assert receiverPrincipal(receiver, streamId) == 0;
}

/**
 @Rule Composition of `open` and `claimYieldInShares`
 @Category High-level
 @Description Open a stream and claim yield in shares in a single transaction.
*/
rule composition_of_open_and_claimYieldInShares(address owner, address receiver, uint256 shares, uint256 maxLossOnOpenTolerance, uint256 yieldShares) {
    env e;
    require owner != 0 && receiver != 0;
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);

    uint256 streamId = open(e, owner, receiver, shares, maxLossOnOpenTolerance);

    uint256 currentTotalAssets = vault.totalAssets();
    uint256 currentTotalSupply = vault.totalSupply();
    require to_mathint(vault.totalAssets()) == currentTotalAssets + yieldShares;
    require to_mathint(vault.totalSupply()) == currentTotalSupply + yieldShares;

    claimYieldInShares(e, receiver, receiver);

    assert to_mathint(receiverTotalShares(receiver)) == initialReceiverTotalShares + yieldShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
}

/**
 @Rule Composition of `open` and `claimYield`
 @Category High-level
 @Description Open a stream and claim yields in a single transaction.
*/
rule composition_of_open_and_claimYield(address owner, address receiver, uint256 shares, uint256 maxLossOnOpenTolerance, uint256 yieldShares) {
    env e;
    require owner != 0 && receiver != 0;
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);

    uint256 streamId = open(e, owner, receiver, shares, maxLossOnOpenTolerance);

    uint256 currentTotalAssets = vault.totalAssets();
    uint256 currentTotalSupply = vault.totalSupply();
    require to_mathint(vault.totalAssets()) == currentTotalAssets + yieldShares;
    require to_mathint(vault.totalSupply()) == currentTotalSupply + yieldShares;

    claimYield(e, receiver, receiver);
    assert receiverTotalShares(receiver) == initialReceiverTotalShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
}

/**
 @Rule Composition of `deposit`, `open` and `claimYield`
 @Category High-level
 @Description Composition of deposit, open, and claim yield
*/
rule composition_of_deposit_and_open_and_claimYield(
    address owner,
    address receiver,
    uint256 principal,
    uint256 maxLossOnOpenTolerance,
    uint256 yieldShares
) {
    env e;
    require owner != 0 && receiver != 0;
    uint256 initialReceiverTotalShares = receiverTotalShares(receiver);
    uint256 initialReceiverTotalPrincipal = receiverTotalPrincipal(receiver);

    uint256 streamId = depositAndOpen(e, owner, receiver, principal, maxLossOnOpenTolerance);

    uint256 currentTotalAssets = vault.totalAssets();
    uint256 currentTotalSupply = vault.totalSupply();
    require to_mathint(vault.totalAssets()) == currentTotalAssets + yieldShares;
    require to_mathint(vault.totalSupply()) == currentTotalSupply + yieldShares;

    claimYield(e, receiver, receiver);

    assert receiverTotalShares(receiver) == initialReceiverTotalShares;
    assert receiverTotalPrincipal(receiver) == initialReceiverTotalPrincipal;
}

/**
 @Rule Composition of `openMultiple`, `topUp` and `claimYieldInShares`
 @Category High-level
 @Description Composition of Open Multiple and Top Up and Claim Yield in Shares
*/
rule composition_of_openMultiple_and_topUp_and_claimYieldInShares(
    address owner,
    uint256 shares,
    address[] receivers,
    uint256[] allocations,
    uint256 maxLossOnOpenTolerance,
    uint256 topUpStreamId,
    uint256 topUpShares,
    uint256 yieldShares
) {
    env e;
    require owner != 0;
    require receivers.length == allocations.length;
    require receivers.length == 2;
    uint256[] initialReceiverTotalShares = [ receiverTotalShares(receivers[0]), receiverTotalShares(receivers[1]) ];
    uint256[] initialReceiverTotalPrincipal = [ receiverTotalPrincipal(receivers[0]), receiverTotalPrincipal(receivers[1]) ];

    uint256[] streamIds = openMultiple(e, owner, shares, receivers, allocations, maxLossOnOpenTolerance);
    
    topUp(e, topUpStreamId, topUpShares);

    uint256 currentTotalAssets = vault.totalAssets();
    uint256 currentTotalSupply = vault.totalSupply();
    require to_mathint(vault.totalAssets()) == currentTotalAssets + yieldShares;
    require to_mathint(vault.totalSupply()) == currentTotalSupply + yieldShares;

    claimYieldInShares(e, receivers[0], receivers[0]);

    assert to_mathint(receiverTotalShares(receivers[0])) == initialReceiverTotalShares[0] + yieldShares;
    assert receiverTotalPrincipal(receivers[0]) == initialReceiverTotalPrincipal[0];
    assert receiverTotalShares(receivers[1]) == initialReceiverTotalShares[1];
    assert receiverTotalPrincipal(receivers[1]) == initialReceiverTotalPrincipal[1];
}

/**
 @Rule Composition of `openMultiple`, `topUp` and `claimYield`
 @Category High-level
 @Description Composes OpenMultiple, TopUp, and Claim Yields
*/
rule composition_of_openMultiple_and_topUp_and_claimYield(
    address owner,
    uint256 shares,
    address[] receivers,
    uint256[] allocations,
    uint256 maxLossOnOpenTolerance,
    uint256 topUpStreamId,
    uint256 topUpShares,
    uint256 yieldShares
) {
    env e;
    require owner != 0;
    require receivers.length == allocations.length;
    require receivers.length == 2;
    uint256[] initialReceiverTotalShares = [ receiverTotalShares(receivers[0]), receiverTotalShares(receivers[1]) ];
    uint256[] initialReceiverTotalPrincipal = [ receiverTotalPrincipal(receivers[0]), receiverTotalPrincipal(receivers[1]) ];

    uint256[] streamIds = openMultiple(e, owner, shares, receivers, allocations, maxLossOnOpenTolerance);
    
    topUp(e, topUpStreamId, topUpShares);

    uint256 currentTotalAssets = vault.totalAssets();
    uint256 currentTotalSupply = vault.totalSupply();
    require to_mathint(vault.totalAssets()) == currentTotalAssets + yieldShares;
    require to_mathint(vault.totalSupply()) == currentTotalSupply + yieldShares;

    claimYield(e, receivers[0], receivers[0]);

    assert receiverTotalShares(receivers[0]) == initialReceiverTotalShares[0];
    assert receiverTotalPrincipal(receivers[0]) == initialReceiverTotalPrincipal[0];
    assert receiverTotalShares(receivers[1]) == initialReceiverTotalShares[1];
    assert receiverTotalPrincipal(receivers[1]) == initialReceiverTotalPrincipal[1];
}

/**
 * @Rule Consistency between `previewClaimYield` and `previewClaimYieldInSharesConsistency`
 * @Category High-level
 * @Description Ensures that the previewClaimYield and previewClaimYieldInShares functions are consistent for each receiver.
 */
rule consistency_between_previewClaimYield_and_previewClaimYieldInShares(address receiver) {
    require receiver != 0;
    uint256 previewYield = previewClaimYield(receiver);
    uint256 previewYieldInShares = previewClaimYieldInShares(receiver);

    uint256 expectedYieldInShares = vault.convertToShares(previewYield);

    assert previewYieldInShares >= expectedYieldInShares;
}

/**
 * @Rule Consistency between `previewOpen`, `previewDeposit` and `open`
 * @Category High-level
 * @Description Ensures that the previewOpen and previewDepositAndOpen functions are consistent for a given receiver, shares, and maxLossOnOpenTolerance.
 */
rule consistency_between_previewOpen_and_previewDeposit_and_open(address receiver, uint256 shares, uint256 maxLossOnOpenTolerance) {
    require receiver != 0;
    uint256 previewOpenPrincipal = previewOpen(receiver, shares, maxLossOnOpenTolerance);
    uint256 previewDepositAndOpenShares = previewDepositAndOpen(receiver, previewOpenPrincipal, maxLossOnOpenTolerance);

    assert previewDepositAndOpenShares <= shares;
}

/**
 * @Rule Consistency between `previewOpen`, `previewClose` and `previewClaimYieldInShares`
 * @Category High-level
 * @Description Ensures that the previewOpen, previewClose, and previewClaimYieldInShares functions are consistent for a given receiver, shares, and maxLossOnOpenTolerance.
 */
rule consistency_betweeb_previewOpen_and_previewClose_and_previewClaimYieldInShares(address owner, address receiver, uint256 shares, uint256 maxLossOnOpenTolerance) {
    env e;
    // Preconditions
    require receiver != 0 && e.msg.sender != 0 && owner != 0;
    require shares > 0;
    require maxLossOnOpenTolerance <= 10 ^ 17; // 10%
    uint256 initialStreamerShareBalance = vault.balanceOf(e.msg.sender);
    require initialStreamerShareBalance >= shares;

    uint256 previewOpenPrincipal = previewOpen(receiver, shares, maxLossOnOpenTolerance);
    uint256 previewOpenShares = vault.convertToShares(previewOpenPrincipal);

    uint256 streamId = open(e, owner, receiver, shares, maxLossOnOpenTolerance);

    uint256 previewCloseShares;
    uint256 previewClosePrincipal;
    (previewCloseShares, previewClosePrincipal) = previewClose(streamId);

    uint256 previewClaimYieldInShares = previewClaimYieldInShares(receiver);

    assert previewCloseShares == previewOpenShares &&
     previewClosePrincipal == previewOpenPrincipal &&
     previewClaimYieldInShares == 0;
}

