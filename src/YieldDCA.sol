// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract YieldDCA {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC4626;
    using SafeERC20 for IERC20;

    struct Deposit {
        uint256 shares;
        uint256 principal;
        uint256 epoch;
    }

    struct EpochInfo {
        uint256 yieldSpent;
        uint256 dcaPrice;
        uint256 pricePerShare;
    }

    uint256 public constant DCA_PERIOD = 2 weeks;

    IERC20 public dcaToken;
    IERC4626 public vault;
    ISwapper public swapper;

    uint256 public currentEpoch = 1; // starts from 1
    uint256 public currentEpochTimestamp = block.timestamp;
    uint256 public totalPrincipalDeposted;
    mapping(address => Deposit) public deposits;
    mapping(uint256 => EpochInfo) public epochDetails;

    constructor(IERC20 _dcaToken, IERC4626 _vault, ISwapper _swapper) {
        dcaToken = _dcaToken;
        vault = _vault;
        swapper = _swapper;

        // approve swapper to spend deposits on DCA token
        IERC20(vault.asset()).approve(address(swapper), type(uint256).max);
    }

    function deposit(uint256 _amount) external {
        uint256 principal = vault.convertToAssets(_amount);
        vault.safeTransferFrom(msg.sender, address(this), _amount);

        Deposit storage position = deposits[msg.sender];

        // check if user has already deposited in the past
        if (position.epoch != 0 && position.epoch < currentEpoch) {
            (uint256 shares, uint256 dcaTokens) = _calculateBalances(position);
            position.shares = shares;

            if (dcaTokens != 0) {
                dcaToken.safeTransfer(msg.sender, dcaTokens);
            }
        }

        position.shares += _amount;
        position.principal += principal;
        position.epoch = currentEpoch;

        totalPrincipalDeposted += principal;
    }

    function executeDCA() external {
        if (block.timestamp < currentEpochTimestamp + DCA_PERIOD) return;

        uint256 yieldInShares = calculateCurrentYieldInShares();

        // TODO: or revert if yield is 0?
        if (yieldInShares == 0) return;

        uint256 yield = vault.redeem(yieldInShares, address(this), address(this));
        // TODO: use asset.balanceOf here instead of yield?

        uint256 realizedPricePerShare = yield.mulDivDown(1e18, yieldInShares);
        uint256 tokensBought = _buyDcaToken(yield);
        uint256 tokenPrice = tokensBought.mulDivDown(1e18, yield);

        epochDetails[currentEpoch] =
            EpochInfo({yieldSpent: yield, dcaPrice: tokenPrice, pricePerShare: realizedPricePerShare});

        currentEpoch++;
        currentEpochTimestamp = block.timestamp;
    }

    function calculateCurrentYieldInShares() public view returns (uint256) {
        uint256 balance = vault.balanceOf(address(this));
        uint256 totalPrincipalInShares = vault.convertToShares(totalPrincipalDeposted);

        return balance > totalPrincipalInShares ? balance - totalPrincipalInShares : 0;
    }

    // NOTE: uses around 300k gas iterating thru 200 epochs. If epochs were to be 2 weeks long, 200 epochs would be about 7.6 years
    function withdraw() external {
        Deposit memory user = deposits[msg.sender];
        // TODO: reconsider this to allow withdrawing in the same epoch as deposit
        require(user.epoch < currentEpoch, "Cannot withdraw in the same epoch");

        (uint256 sharesRemaining, uint256 totalDcaTokensForUser) = _calculateBalances(user);

        // withdraw remaining shares
        if (sharesRemaining > vault.balanceOf(address(this))) {
            sharesRemaining = vault.balanceOf(address(this));
        }

        vault.safeTransfer(msg.sender, sharesRemaining);

        if (totalDcaTokensForUser > dcaToken.balanceOf(address(this))) {
            totalDcaTokensForUser = dcaToken.balanceOf(address(this));
        }

        dcaToken.safeTransfer(msg.sender, totalDcaTokensForUser);

        // update
        totalPrincipalDeposted -= user.principal;

        // update user position
        delete deposits[msg.sender];
    }

    function _buyDcaToken(uint256 _amountIn) private returns (uint256 amountOut) {
        uint256 balanceBefore = dcaToken.balanceOf(address(this));
        uint256 amountOutMin = 0;

        // TODO: handle slippage somehow
        amountOut = swapper.execute(vault.asset(), address(dcaToken), _amountIn, amountOutMin);

        require(
            dcaToken.balanceOf(address(this)) >= balanceBefore + amountOut, "received less DCA tokens than expected"
        );
    }

    function balanceOf(address _user) public view returns (uint256 shares, uint256 dcaTokens) {
        return _calculateBalances(deposits[_user]);
    }

    function _calculateBalances(Deposit memory _deposit) internal view returns (uint256 shares, uint256 dcaTokens) {
        if (_deposit.epoch == 0) return (0, 0);

        shares = _deposit.shares;

        for (uint256 i = _deposit.epoch; i < currentEpoch; i++) {
            EpochInfo memory epoch = epochDetails[i];

            if (epoch.yieldSpent == 0) continue;

            uint256 sharesValue = shares.mulWadDown(epoch.pricePerShare);

            if (sharesValue <= _deposit.principal) continue;

            uint256 usersYield = sharesValue - _deposit.principal;
            uint256 sharesSpent = usersYield.divWadDown(epoch.pricePerShare);

            shares -= sharesSpent;
            dcaTokens += usersYield.mulWadDown(epoch.dcaPrice);
        }
    }
}

interface ISwapper {
    function execute(address _tokenIn, address _tokenOut, uint256 _amoountIn, uint256 _amountOutMin)
        external
        returns (uint256 amountOut);
}

contract SwapperMock is ISwapper {
    using FixedPointMathLib for uint256;

    uint256 exchangeRate = 1e18;

    function setExchangeRate(uint256 _exchangeRate) external {
        exchangeRate = _exchangeRate;
    }

    function execute(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256)
        external
        returns (uint256 amountOut)
    {
        // console2.log("Swapper: execute");
        // ... [Swap logic] ...
        amountOut = _amountIn.mulWadDown(exchangeRate);

        //        console2.log("amountIn", _amountIn);
        //console2.log("amountOut", amountOut);

        IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn);

        // console2.log("token out balance", IERC20(_tokenOut).balanceOf(address(this)));

        IERC20(_tokenOut).transfer(msg.sender, amountOut);
    }
}

contract YieldDCATest is Test {
    using FixedPointMathLib for uint256;

    YieldDCA yieldDca;
    MockERC20 asset;
    MockERC4626 vault;
    MockERC20 dcaToken;

    SwapperMock swapper;

    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

    function setUp() public {
        asset = new MockERC20("ERC20Mock", "ERC20Mock", 18);
        vault = new MockERC4626(MockERC20(address(asset)), "ERC4626Mock", "ERC4626Mock");
        dcaToken = new MockERC20("DCA Token", "DCA", 18);
        swapper = new SwapperMock();

        dcaToken.mint(address(swapper), 10000 ether);
        yieldDca = new YieldDCA(IERC20(address(dcaToken)), IERC4626(address(vault)), swapper);
    }

    function test_dca_oneDeposit() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 50%, ie 0.5 ether
         * 3. execute DCA at 3:1 exchange rate, ie by 1.5 DCA for 0.5 ether in yield
         * 4. alice withdraws and gets 1 ether in shares and 1.5 DCA token
         */
        uint256 depositAmount = 1 ether;
        asset.mint(alice, depositAmount);

        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vault.approve(address(yieldDca), shares);
        yieldDca.deposit(shares);
        vm.stopPrank();

        // generate 50% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)).mulWadDown(0.5e18));

        swapper.setExchangeRate(3e18);

        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        yieldDca.executeDCA();

        vm.prank(alice);
        yieldDca.withdraw();

        uint256 expectedYield = depositAmount.mulWadDown(0.5e18);
        uint256 expectedDcaToken = expectedYield.mulWadDown(3e18);

        console2.log("dca balance", dcaToken.balanceOf(alice));
        console2.log("shares balance", vault.balanceOf(alice));
        console2.log("shares value", vault.convertToAssets(vault.balanceOf(alice)));

        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaToken, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), depositAmount, 1, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);
    }

    function test_dca_oneDeposit_multipleDcaExecutions() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 5% over 200 dca cycles (epochs)
         * 3. execute DCA at 3:1 exchange in each cycle, 3 DCA tokens = 1 ether
         * 4. alice withdraws and gets 1 ether in shares and gets 0.05 * 200 * 3 = 30 DCA tokens
         */
        uint256 depositAmount = 1 ether;
        asset.mint(alice, depositAmount);

        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vault.approve(address(yieldDca), shares);
        yieldDca.deposit(shares);
        vm.stopPrank();

        // set exchange rate
        swapper.setExchangeRate(3e18);
        uint256 yieldPerEpoch = 0.05e18; // 5%
        uint256 epochs = 200;

        for (uint256 i = 0; i < epochs; i++) {
            asset.mint(address(vault), asset.balanceOf(address(vault)).mulWadDown(yieldPerEpoch));

            vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
            yieldDca.executeDCA();
        }

        vm.prank(alice);
        yieldDca.withdraw();

        console2.log("dca balance", dcaToken.balanceOf(alice));
        console2.log("shares balance", vault.balanceOf(alice));
        console2.log("shares value", vault.convertToAssets(vault.balanceOf(alice)));

        uint256 expectedDcaTokenBalance = 200 * depositAmount.mulWadDown(yieldPerEpoch).mulWadDown(3e18);
        assertApproxEqRel(dcaToken.balanceOf(alice), expectedDcaTokenBalance, 0.00001e18, "dca token balance");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), depositAmount, 0.00001e18, "principal");
        assertEq(vault.balanceOf(address(yieldDca)), 0);
    }

    function test_dca_twoDepositors_separatesBalancesOverTwoEpochsCorrectly() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice gets 3 DCA tokens)
         * 4. bob deposits 1 ether
         * 5. yield generated is 100% in the second epoch, ie 2 ether (from 2 deposits)
         * 6. execute DCA at 2:1 exchange, (bob gets 2 DCA tokens and alice gets 2 DCA tokens)
         * 7. alice withdraws and gets 1 ether in shares and 5 DCA tokens
         * 8. bob withdraws and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        uint256 alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        // step 2 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 3 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(3e18);
        yieldDca.executeDCA();

        // step 4 - bob deposits

        asset.mint(bob, 1 ether);
        vm.startPrank(bob);
        asset.approve(address(vault), 1 ether);
        uint256 bobsShares = vault.deposit(1 ether, bob);
        vault.approve(address(yieldDca), bobsShares);

        yieldDca.deposit(bobsShares);
        vm.stopPrank();

        // step 5 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 6 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(2e18);
        yieldDca.executeDCA();

        // step 7 - alice withdraws
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1e18, 1, "principal");

        console2.log("dca balance", dcaToken.balanceOf(alice));
        console2.log("shares balance", vault.balanceOf(alice));

        // step 8 - bob withdraws
        vm.prank(bob);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(bob), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 1e18, 1, "principal");

        console2.log("dca balance", dcaToken.balanceOf(bob));
        console2.log("shares balance", vault.balanceOf(bob));
    }

    function test_dca_separatesBalancesOverTwoEpochsCorrectlyForMultipleUsers() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, 3 DCA tokens = 1 ether (alice gets 3 DCA tokens)
         * 4. bob deposits 2 ether
         * 5. carol deposits 1 ether
         * 6. yield generated is 100% in the second epoch, ie 4 ether (from 3 deposits of 4 ether in total)
         * 7. execute DCA at 2:1 exchange, (bob gets 4 DCA tokens and alice & carol get 2 DCA tokens each)
         * 8. alice withdraws and gets 1 ether in shares and 5 DCA tokens
         * 9. bob withdraws and gets 2 ether in shares and 4 DCA tokens
         * 10. carol withdraws and gets 1 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        uint256 alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        // step 2 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 3 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(3e18);
        yieldDca.executeDCA();

        // step 4 - bob deposits
        asset.mint(bob, 2 ether);
        vm.startPrank(bob);
        asset.approve(address(vault), 2 ether);
        uint256 bobsShares = vault.deposit(2 ether, bob);
        vault.approve(address(yieldDca), bobsShares);

        yieldDca.deposit(bobsShares);
        vm.stopPrank();

        // step 5 - carol deposits
        asset.mint(carol, 1 ether);
        vm.startPrank(carol);
        asset.approve(address(vault), 1 ether);
        uint256 carolsShares = vault.deposit(1 ether, carol);
        vault.approve(address(yieldDca), carolsShares);

        yieldDca.deposit(carolsShares);
        vm.stopPrank();

        // step 6 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 7 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(2e18);
        yieldDca.executeDCA();

        // step 8 - alice withdraws
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 5e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1e18, 1, "principal");

        // step 9 - bob withdraws
        vm.prank(bob);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(bob), 4e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 2e18, 1, "principal");

        // step 10 - carol withdraws
        vm.prank(carol);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(carol), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(carol)), 1e18, 1, "principal");
    }

    function test_deposit_twoTimesInSameEpoch() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. alice deposits 1 ether again
         * 4. execute DCA at 2:1 exchange, (alice gets 2 DCA tokens)
         * 5. alice withdraws and gets 2 ether in shares and 2 DCA tokens
         */

        // step 1 - alice deposits
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        uint256 alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        // step 2 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 3 - alice deposits again
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertEq(dcaToken.balanceOf(alice), 0, "dca token balance");

        // step 4 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(2e18);
        yieldDca.executeDCA();

        // step 5 - alice withdraws
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 2e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 2e18, 1, "principal");
    }

    function test_deposit_twoTimesInDifferentEpochs() public {
        /**
         * scenario:
         * 1. alice deposits 1 ether
         * 2. yield generated is 100% in the first epoch, ie 1 ether
         * 3. execute DCA at 3:1 exchange, (alice gets 3 DCA tokens)
         * 4. alice deposits 1 ether again (receives 3 DCA tokens)
         * 5. generate 100% yield in the second epoch, ie 2 ether
         * 6. execute DCA at 2:1 exchange, (alice gets 4 DCA tokens)
         * 7. alice withdraws and gets 2 ether in shares and 4 DCA tokens (7 in total)
         */

        // step 1 - alice deposits
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        uint256 alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        // step 2 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 3 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(3e18);
        yieldDca.executeDCA();

        // step 4 - alice deposits again
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(vault), 1 ether);
        alicesShares = vault.deposit(1 ether, alice);
        vault.approve(address(yieldDca), alicesShares);
        yieldDca.deposit(alicesShares);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares balance");
        assertApproxEqRel(dcaToken.balanceOf(alice), 3e18, 0.00001e18, "dca token balance");

        // step 5 - generate 100% yield
        asset.mint(address(vault), asset.balanceOf(address(vault)));

        // step 6 - dca
        vm.warp(block.timestamp + yieldDca.DCA_PERIOD());
        swapper.setExchangeRate(2e18);
        yieldDca.executeDCA();

        // step 7 - alice withdraws
        vm.prank(alice);
        yieldDca.withdraw();

        assertApproxEqRel(dcaToken.balanceOf(alice), 7e18, 0.00001e18, "dca token balance");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 2e18, 1, "principal");
    }
}
