// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {ERC4626WrapBalanceOracle} from "src/balances/protocols/ERC4626Wrap.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ERC4626WrapBalanceOracle fork tests — Savings GHO (sGHO)
/// @notice Tests ERC4626WrapBalanceOracle against the real sGHO contract on Ethereum mainnet.
///         sGHO is a standard ERC-4626 vault whose `asset()` is GHO; the adapter must report
///         `convertToAssets(balanceOf(account))` denominated in GHO.
/// @dev Establishes a real position by funding an account with GHO (via `deal`) and depositing
///      into the live sGHO contract, then cross-checks the oracle against an actual `redeem` to
///      confirm the reported amount equals the redeemable GHO (i.e. no exit-fee/cooldown skew that
///      would make `convertToAssets` over-report).
contract ERC4626WrapBalanceOracleForkTest_sGHO is BalanceAdapterTestBase {
    // Savings GHO (sGHO) and its underlying asset (GHO)
    IERC4626 public constant SGHO = IERC4626(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
    IERC20 public constant GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);

    // Recent stable mainnet block where sGHO is live
    uint256 public constant FORK_BLOCK = 25_220_000;

    address public user = makeAddr("sghoUser");
    uint256 public constant DEPOSIT = 100_000e18;

    ERC4626WrapBalanceOracle public oracle;

    function setUp() public override {
        super.setUp(); // dispatches to this contract's _setupFork() override
        _setupOracle();
        _openPosition();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(address(GHO));
        oracle = new ERC4626WrapBalanceOracle(address(SGHO), address(balances));
    }

    /// @notice Fund `user` with GHO and deposit it into the real sGHO vault.
    function _openPosition() internal {
        deal(address(GHO), user, DEPOSIT);
        vm.startPrank(user);
        GHO.approve(address(SGHO), DEPOSIT);
        SGHO.deposit(DEPOSIT, user);
        vm.stopPrank();
        assertGt(SGHO.balanceOf(user), 0, "user should hold sGHO shares after deposit");
    }

    // ============================================
    // Sanity: real contract wiring
    // ============================================

    function test_assetIsGho() public view {
        assertEq(SGHO.asset(), address(GHO), "sGHO underlying must be GHO");
        assertEq(oracle.ASSET(), address(GHO));
        assertEq(address(oracle.WRAPPER()), address(SGHO));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(GHO));
    }

    // ============================================
    // Real position: the oracle must equal convertToAssets(shares)
    // ============================================

    function test_getOracleBalanceForAsset_matchesConvertToAssets() public view {
        uint256 shares = SGHO.balanceOf(user);
        uint256 expected = SGHO.convertToAssets(shares);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(user, address(GHO));
        assertEq(amount, expected, "oracle must report convertToAssets(shares)");
        assertFalse(isDebt, "savings position is always credit");

        // The freshly-deposited position is worth ~the deposit (sGHO trades at a small premium).
        assertApproxEqRel(amount, DEPOSIT, 0.005e18, "reported value should be ~the deposited GHO");
    }

    /// @notice The strongest "does it work" check: the oracle's reported amount must match the GHO
    ///         actually returned by redeeming the shares — proving no exit fee/cooldown makes
    ///         `convertToAssets` over-report.
    function test_reportedAmount_matchesActualRedemption() public {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(user, address(GHO));
        uint256 shares = SGHO.balanceOf(user);

        uint256 ghoBefore = GHO.balanceOf(user);
        vm.prank(user);
        SGHO.redeem(shares, user, user);
        uint256 redeemed = GHO.balanceOf(user) - ghoBefore;

        assertApproxEqAbs(amount, redeemed, 2, "oracle amount must match redeemable GHO (within rounding)");
    }

    // ============================================
    // Positions
    // ============================================

    function test_getOracleBalances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(user);
        assertEq(assets.length, 1, "one position");
        assertEq(assets[0], address(GHO));
        assertGt(amounts[0], 0);
        assertFalse(isDebt[0]);
    }

    function test_getOraclePositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 1, "one position");
        assertEq(positions[0].balanceAsset.asset, address(GHO));
        assertGt(positions[0].amount, 0);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ERC4626);
        assertEq(positions[0].positionId, abi.encode(address(SGHO)));
        assertTrue(positions[0].positionKind == PositionKind.Supplied);
    }

    function test_getOraclePositions_withAssetFilter() public view {
        INAVCalculator.PositionBalance[] memory hit = oracle.getOraclePositions(user, address(GHO));
        assertEq(hit.length, 1);
        assertGt(hit[0].amount, 0);

        INAVCalculator.PositionBalance[] memory miss = oracle.getOraclePositions(user, address(0xdead));
        assertEq(miss.length, 0);
    }

    // ============================================
    // Negative cases
    // ============================================

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0xdead), address(GHO));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(user, address(0xdead));
        assertEq(amount, 0);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(address(0xdead));
        assertEq(assets.length, 0);
    }
}

/// @title ERC4626WrapBalanceOracle fork tests — real sGHO holder (pinned on-chain values)
/// @notice Strongest real-case check: pins an actual on-chain sGHO holder at a fixed block and
///         asserts the adapter reports the holder's exact GHO value. Values captured on-chain at
///         block 25_230_126: balanceOf = 4_575_878_017_851_927_061_694_571 sGHO shares;
///         convertToAssets(shares) = 4_584_852_009_461_488_672_755_755 GHO.
contract ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder is BalanceAdapterTestBase {
    IERC4626 public constant SGHO = IERC4626(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
    IERC20 public constant GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);

    uint256 public constant FORK_BLOCK = 25_230_126;
    address public constant HOLDER = 0x5eF87DeC00a19d2b47EE0073d869F7d7feFF26ef;
    uint256 public constant EXPECTED_SHARES = 4_575_878_017_851_927_061_694_571;
    uint256 public constant EXPECTED_GHO = 4_584_852_009_461_488_672_755_755;

    ERC4626WrapBalanceOracle public oracle;

    function setUp() public override {
        super.setUp(); // dispatches to this contract's _setupFork() override
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(address(GHO));
        oracle = new ERC4626WrapBalanceOracle(address(SGHO), address(balances));
    }

    /// @notice Confirms the fork is pinned where the holder has the expected share balance.
    function test_realHolder_sharesAtBlock() public view {
        assertEq(SGHO.balanceOf(HOLDER), EXPECTED_SHARES, "holder sGHO shares at pinned block");
    }

    /// @notice Confirms the live vault's share->asset conversion matches the captured value.
    function test_realHolder_convertToAssets() public view {
        assertEq(SGHO.convertToAssets(EXPECTED_SHARES), EXPECTED_GHO, "convertToAssets at pinned block");
    }

    /// @notice The adapter must report the holder's position as exactly the convertToAssets GHO value.
    function test_realHolder_oracleReportsExactGho() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(HOLDER, address(GHO));
        assertEq(amount, EXPECTED_GHO, "oracle must report the holder's exact GHO value");
        assertFalse(isDebt, "savings position is always credit");
    }

    function test_realHolder_positions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(HOLDER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(GHO));
        assertEq(positions[0].amount, EXPECTED_GHO);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ERC4626);
        assertEq(positions[0].positionId, abi.encode(address(SGHO)));
        assertTrue(positions[0].positionKind == PositionKind.Supplied);
    }

    function test_realHolder_balances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(HOLDER);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(GHO));
        assertEq(amounts[0], EXPECTED_GHO);
        assertFalse(isDebt[0]);
    }
}

/// @title ERC4626WrapBalanceOracle fork tests — real sGHO holder at the verification block (2nd pinned point)
/// @notice Same holder as ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder, pinned at the verification block
///         25_287_877 (the block captured in the sGHO evidence-pack README). Augments — does not replace — the
///         original pin: the holder hasn't moved (share count is identical) so this is a pure yield-accrual
///         delta, giving a second regression point. The dev-anvil dashboard forks at latest (not this block),
///         so it is a live sanity check that drifts from this pinned value by design.
///         Values captured on-chain at block 25_287_877: balanceOf = 4_575_878_017_851_927_061_694_571 sGHO
///         shares; convertToAssets(shares) = 4_589_154_643_764_641_667_853_774 GHO (exact at the block's
///         timestamp — a live dev anvil reads marginally higher as it advances block.timestamp while mining).
contract ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder_Fresh is BalanceAdapterTestBase {
    IERC4626 public constant SGHO = IERC4626(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
    IERC20 public constant GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);

    uint256 public constant FORK_BLOCK = 25_287_877;
    address public constant HOLDER = 0x5eF87DeC00a19d2b47EE0073d869F7d7feFF26ef;
    uint256 public constant EXPECTED_SHARES = 4_575_878_017_851_927_061_694_571;
    uint256 public constant EXPECTED_GHO = 4_589_154_643_764_641_667_853_774;

    ERC4626WrapBalanceOracle public oracle;

    function setUp() public override {
        super.setUp(); // dispatches to this contract's _setupFork() override
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(address(GHO));
        oracle = new ERC4626WrapBalanceOracle(address(SGHO), address(balances));
    }

    /// @notice Share count is unchanged from the original pin — only the redeemable value accrued.
    function test_realHolder_sharesAtBlock() public view {
        assertEq(SGHO.balanceOf(HOLDER), EXPECTED_SHARES, "holder sGHO shares at verification block");
    }

    function test_realHolder_convertToAssets() public view {
        assertEq(SGHO.convertToAssets(EXPECTED_SHARES), EXPECTED_GHO, "convertToAssets at verification block");
    }

    function test_realHolder_oracleReportsExactGho() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(HOLDER, address(GHO));
        assertEq(amount, EXPECTED_GHO, "oracle must report the holder's exact GHO value");
        assertFalse(isDebt, "savings position is always credit");
    }

    function test_realHolder_positions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(HOLDER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(GHO));
        assertEq(positions[0].amount, EXPECTED_GHO);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ERC4626);
        assertEq(positions[0].positionId, abi.encode(address(SGHO)));
        assertTrue(positions[0].positionKind == PositionKind.Supplied);
    }

    /// @notice getOracleBalances must agree with getOracleBalanceForAsset / getOraclePositions at this pin —
    ///         exercises the evidence-pack claim that all three views return the same GHO value.
    function test_realHolder_balances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(HOLDER);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(GHO));
        assertEq(amounts[0], EXPECTED_GHO);
        assertFalse(isDebt[0]);
    }
}
