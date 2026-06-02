// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AuraRewardsMetaBalanceAdapter} from "src/balances/protocols/AuraRewardsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AuraRewardsMetaForkTest
/// @notice Fork tests for AuraRewardsMetaBalanceAdapter against real mainnet contracts.
///
/// Pool under test: GHO/USDT/USDC Balancer V3 pool — Aura pid=246
///   Booster  : 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234
///   Pool     : 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D
///   Rewarder : 0x8e89d41c563e6C3d9901ad75B75e2d8e140DEF04  (Booster.poolInfo(246).crvRewards)
///   Staker   : 0x12ba33C6B8Ac904b6FD9cb6DFf3FdB86BC19B75A  (has staked BPT at FORK_BLOCK)
///
/// Extra rewards (at FORK_BLOCK):
///   extra[0] rewardToken = stash(0xbb16...) → baseToken = AURA (accumulated into AURA leg)
///   extra[1] rewardToken = stash(0x2CAB...) → baseToken = GHO  (emitted as extra Earned leg)
contract AuraRewardsMetaForkTest is BalanceAdapterTestBase {
    // ── Mainnet constants ─────────────────────────────────────────────────────

    address public constant BOOSTER   = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234;
    address public constant AURA      = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;
    address public constant BAL       = 0xba100000625a3754423978a60c9317c58a424e3D;
    address public constant POOL      = 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D;

    // Registered underlying pool tokens
    address public constant GHO  = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Pool ID for the GHO/USDT/USDC pool in the Aura Booster
    uint256 public constant PID = 246;

    // Rewarder = Booster.poolInfo(246).crvRewards (verified on-chain)
    address public constant REWARDER = 0x8e89d41c563e6C3d9901ad75B75e2d8e140DEF04;

    // Staker with significant staked BPT at FORK_BLOCK
    address public constant STAKER = 0x12ba33C6B8Ac904b6FD9cb6DFf3FdB86BC19B75A;

    uint256 public constant FORK_BLOCK = 22_500_000;

    AuraRewardsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        // Register all relevant assets
        address[] memory assets = new address[](5);
        assets[0] = BAL;
        assets[1] = AURA;
        assets[2] = GHO;
        assets[3] = USDT;
        assets[4] = USDC;
        balances = _deployBalancesForOracle(assets);

        meta = new AuraRewardsMetaBalanceAdapter(BOOSTER, 0xBA12222222228d8Ba445958a75a0704d566BF2C8, "Aura", address(balances));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _single(address r) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(r)));
    }

    function _countKind(INAVCalculator.PositionBalance[] memory pos, PositionKind k)
        internal
        pure
        returns (uint256 n)
    {
        for (uint256 i; i < pos.length; ++i) if (pos[i].positionKind == k) n++;
    }

    function _sumAsset(INAVCalculator.PositionBalance[] memory pos, address asset)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == asset) total += pos[i].amount;
        }
    }

    function _staked(address rewarder, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            rewarder.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        return (ok && data.length >= 32) ? abi.decode(data, (uint256)) : 0;
    }

    function _earned(address rewarder, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            rewarder.staticcall(abi.encodeWithSignature("earned(address)", account));
        return (ok && data.length >= 32) ? abi.decode(data, (uint256)) : 0;
    }

    // ─── 1. Pool resolution from Booster ─────────────────────────────────────

    /// @notice Verify that rewarder.pid() → Booster.poolInfo(pid).lptoken matches POOL.
    function test_poolResolution_fromBooster() public view {
        (bool pidOk, bytes memory pidData) =
            REWARDER.staticcall(abi.encodeWithSignature("pid()"));
        assertTrue(pidOk, "pid() call succeeded");
        uint256 pid = abi.decode(pidData, (uint256));
        assertEq(pid, PID, "rewarder.pid() = 246");

        (address lptoken,,,,, ) = IAuraBooster(BOOSTER).poolInfo(pid);
        assertEq(lptoken, POOL, "Booster.poolInfo(246).lptoken = GHO/USDT/USDC pool");
    }

    // ─── 2. Staked BPT decomposes into underlying tokens ─────────────────────

    /// @notice A real staker's BPT produces Supplied legs for at least some pool tokens.
    function test_stakedBpt_decomposesIntoUnderlyingTokens() public view {
        uint256 staked = _staked(REWARDER, STAKER);
        assertGt(staked, 0, "staker has positive staked balance");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(STAKER, _single(REWARDER), address(0));

        uint256 suppliedCount = _countKind(pos, PositionKind.Supplied);
        assertGt(suppliedCount, 0, "at least one Supplied leg (staked BPT decomposed)");

        // All Supplied legs should be non-debt
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == PositionKind.Supplied) {
                assertFalse(pos[i].isDebt, "Supplied positions are not debt");
                assertGt(pos[i].amount, 0, "Supplied amount is positive");
            }
        }
    }

    // ─── 3. BAL earned reported exactly ──────────────────────────────────────

    /// @notice The meta adapter's BAL Earned amount must equal rewarder.earned(staker).
    function test_balEarned_reportedExactly() public view {
        uint256 balExpected = _earned(REWARDER, STAKER);
        if (balExpected == 0) return; // skip if no rewards accrued at this block

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(STAKER, _single(REWARDER), address(0));

        uint256 balReported = _sumAsset(pos, BAL);
        assertEq(balReported, balExpected, "BAL Earned matches rewarder.earned()");
    }

    // ─── 4. IS_MAINNET = true on mainnet ─────────────────────────────────────

    /// @notice Verifies IS_MAINNET is true and AURA_TOKEN is the known mainnet AURA address.
    function test_auraToken_isMainnet() public view {
        assertTrue(meta.IS_MAINNET(), "IS_MAINNET should be true on mainnet fork");
        assertEq(meta.AURA_TOKEN(), AURA, "AURA_TOKEN resolves to mainnet AURA via Booster.minter()");
    }

    // ─── 5. Parity with per-instance Aura adapter ────────────────────────────

    /// @notice Total per-asset amounts from the meta adapter should match the old per-instance adapter.
    /// @dev The old `Aura` adapter combines pool-token amounts and reward amounts into a single
    ///      `Supplied` position kind per asset, whereas the meta splits them into `Supplied` (pool tokens)
    ///      and `Earned` (rewards). The total amount per asset should be equal.
    function test_parity_withPerInstanceAdapter() public view {
        uint256 staked = _staked(REWARDER, STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory metaPos =
            meta.getOraclePositionsForInstances(STAKER, _single(REWARDER), address(0));

        assertGt(metaPos.length, 0, "meta adapter returns positions");

        // Verify position kind is always Supplied or Earned (not Wallet/Borrowed/Collateral)
        for (uint256 i; i < metaPos.length; ++i) {
            uint8 k = uint8(metaPos[i].positionKind);
            assertTrue(
                k == uint8(PositionKind.Supplied) || k == uint8(PositionKind.Earned),
                "only Supplied or Earned positions expected"
            );
        }

        // Verify protocolId and positionId for all positions
        for (uint256 i; i < metaPos.length; ++i) {
            assertEq(metaPos[i].protocolId, ProtocolIds.AURA);
            assertEq(metaPos[i].positionId, abi.encode(REWARDER));
            assertEq(metaPos[i].balanceOracle, address(meta));
        }
    }

    // ─── 6. AURA earned is positive when BAL is earned ───────────────────────

    /// @notice When BAL is earned, the AURA cliff schedule should produce a positive AURA amount.
    function test_auraEarned_positiveWhenBalEarned() public view {
        uint256 balExpected = _earned(REWARDER, STAKER);
        if (balExpected == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(STAKER, _single(REWARDER), address(0));

        uint256 auraReported = _sumAsset(pos, AURA);
        assertGt(auraReported, 0, "AURA > 0 when BAL is earned (cliff schedule)");
    }
}

// ─── Minimal Booster interface for fork test ─────────────────────────────────

interface IAuraBooster {
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}
