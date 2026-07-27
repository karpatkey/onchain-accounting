// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockCurveToken,
    MockCurvePool,
    MockCurveGauge,
    MockCurveMinter
} from "test/balances/MetaBalanceAdapters/CurveMocks.sol";

contract CurveGaugesMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockCurveMinter minter;
    CurveGaugesMetaBalanceAdapter meta;

    MockCurveToken usdc;
    MockCurveToken dai;
    MockCurveToken crv;
    MockCurveToken ldoReward;

    address alice = makeAddr("alice");

    // Pool IS the LP token (self-LP)
    MockCurvePool pool;
    MockCurveGauge gauge;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        minter = new MockCurveMinter();

        usdc = new MockCurveToken("USDC", 6);
        dai = new MockCurveToken("DAI", 18);
        crv = new MockCurveToken("CRV", 18);
        ldoReward = new MockCurveToken("LDO", 18);

        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(dai), 18, "DAI");
        nav.registerAsset(address(crv), 18, "CRV");
        nav.registerAsset(address(ldoReward), 18, "LDO");

        // Pool IS the LP token
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        pool = new MockCurvePool(coins);
        gauge = new MockCurveGauge(address(pool));

        meta = new CurveGaugesMetaBalanceAdapter(address(minter), address(crv), address(nav));
    }

    function _instance(address g) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(g)));
    }

    // ─── interface ────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    // ─── staked LP decomposition ──────────────────────────────────────────────

    function test_stakedLp_decomposes_proRata() public {
        // 1000 LP total; alice stakes 100 (10%)
        pool.setTotalSupply(1_000e18);
        pool.setPoolBalance(0, 500e6); // 500 USDC
        pool.setPoolBalance(1, 500e18); // 500 DAI
        gauge.setStaked(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        // Expect 2 Staking legs (USDC, DAI) — no CRV if integrate_fraction is 0, no extra rewards
        uint256 staking = _countKind(pos, PositionKind.Staking);
        assertEq(staking, 2, "2 Staking legs");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 50e6); // 10% of 500 USDC
        assertEq(pos[1].balanceAsset.asset, address(dai));
        assertEq(pos[1].amount, 50e18); // 10% of 500 DAI
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Staking));
        assertFalse(pos[0].isDebt);
    }

    function test_positionIdentity() public {
        gauge.setStaked(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));
        assertGt(pos.length, 0);
        assertEq(pos[0].protocolSubId, ProtocolIds.CURVE_GAUGES);
        assertEq(pos[0].protocolId, ProtocolIds.CURVE);
        assertEq(pos[0].positionId, abi.encode(address(gauge)));
        assertEq(pos[0].balanceAdapter, address(meta));
    }

    function test_noStake_butRewards_stillReported() public {
        // Alice has 0 staked LP but has unclaimed rewards
        gauge.setIntegrateFraction(alice, 500e18);
        // minter.minted = 0 → claimable = 500 CRV

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        assertEq(pos.length, 1);
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Rewards));
        assertEq(pos[0].balanceAsset.asset, address(crv));
        assertEq(pos[0].amount, 500e18);
    }

    // ─── CRV rewards ──────────────────────────────────────────────────────────

    function test_crvRewards_lowerBound() public {
        gauge.setStaked(alice, 50e18);
        gauge.setIntegrateFraction(alice, 1_000e18);
        minter.setMinted(alice, address(gauge), 300e18); // already claimed 300 CRV

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        uint256 rewards = _countKind(pos, PositionKind.Rewards);
        assertEq(rewards, 1);

        INAVCalculator.PositionBalance memory crvPos = _findAsset(pos, address(crv));
        assertEq(crvPos.amount, 700e18); // 1000 - 300 = 700 CRV claimable lower bound
        assertEq(uint8(crvPos.positionKind), uint8(PositionKind.Rewards));
        assertFalse(crvPos.isDebt);
    }

    function test_crvRewards_alreadyClaimedAll_zero() public {
        gauge.setStaked(alice, 50e18);
        gauge.setIntegrateFraction(alice, 500e18);
        minter.setMinted(alice, address(gauge), 500e18); // fully claimed

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        // No CRV Rewards leg (amount is 0)
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == address(crv)) {
                assertTrue(pos[i].amount == 0 || uint8(pos[i].positionKind) != uint8(PositionKind.Rewards));
            }
        }
    }

    function test_noMinter_noCrvReported() public {
        // Deploy meta with no minter (L2 / RewardsOnlyGauge)
        CurveGaugesMetaBalanceAdapter l2Meta = new CurveGaugesMetaBalanceAdapter(address(0), address(crv), address(nav));

        gauge.setStaked(alice, 100e18);
        gauge.setIntegrateFraction(alice, 9_999e18); // large, but minter is 0

        INAVCalculator.PositionBalance[] memory pos =
            l2Meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].balanceAsset.asset == address(crv), "no CRV without minter");
        }
    }

    // ─── extra reward tokens ──────────────────────────────────────────────────

    function test_extraRewards_emittedAsRewards() public {
        gauge.setStaked(alice, 100e18);
        gauge.addRewardToken(address(ldoReward));
        gauge.setClaimableReward(address(ldoReward), alice, 42e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        INAVCalculator.PositionBalance memory ldoPos = _findAsset(pos, address(ldoReward));
        assertEq(ldoPos.amount, 42e18);
        assertEq(uint8(ldoPos.positionKind), uint8(PositionKind.Rewards));
    }

    function test_extraReward_unregistered_skipped() public {
        MockCurveToken unknown = new MockCurveToken("UNKN", 18);
        gauge.addRewardToken(address(unknown));
        gauge.setClaimableReward(address(unknown), alice, 100e18);
        gauge.setStaked(alice, 50e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].balanceAsset.asset == address(unknown));
        }
    }

    function test_crvNotDoubleCountedAsExtraReward() public {
        // CRV is both earned via Minter AND listed as reward_token(0)
        gauge.setStaked(alice, 50e18);
        gauge.setIntegrateFraction(alice, 200e18);
        gauge.addRewardToken(address(crv)); // CRV in extra rewards list
        gauge.setClaimableReward(address(crv), alice, 999e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));

        uint256 crvCount;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == address(crv)) crvCount++;
        }
        assertEq(crvCount, 1, "CRV reported exactly once (Minter path, not extra-reward path)");
    }

    // ─── asset filter ─────────────────────────────────────────────────────────

    function test_assetFilter_onlyMatchingCoin() public {
        gauge.setStaked(alice, 100e18);
        gauge.setIntegrateFraction(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(usdc));

        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].balanceAsset.asset, address(usdc));
        }
        assertGt(pos.length, 0);
    }

    // ─── isolation ────────────────────────────────────────────────────────────

    function test_badInstance_isolated() public {
        gauge.setStaked(alice, 100e18);

        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xdead)))); // bad gauge
        instances[1] = bytes32(uint256(uint160(address(gauge))));

        INAVCalculator.PositionBalance[] memory pos = meta.getAdapterPositionsForInstances(alice, instances, address(0));
        assertGt(pos.length, 0, "good gauge still returned");
    }

    // ─── positionLabels ───────────────────────────────────────────────────────

    function test_positionLabels_format() public {
        pool.setTotalSupply(1_000e18);
        pool.setPoolBalance(0, 500e6);
        pool.setPoolBalance(1, 500e18);
        gauge.setStaked(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(gauge)), address(0));
        assertGt(pos.length, 0);
        string[] memory labels = meta.positionLabels(pos[0].positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Staking Gauge");
        assertEq(labels[1], "USDC/DAI");
    }

    // ─── underlyingAssetsSupported ────────────────────────────────────────────

    function test_instanceAssets_coinsAndCrv() public {
        gauge.addRewardToken(address(ldoReward));

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_instance(address(gauge)));

        // Should contain USDC, DAI (pool coins) + CRV (minter) + LDO (extra reward)
        assertEq(assets.length, 4);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _countKind(INAVCalculator.PositionBalance[] memory pos, PositionKind kind)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == kind) count++;
        }
    }

    function _findAsset(INAVCalculator.PositionBalance[] memory pos, address asset)
        internal
        pure
        returns (INAVCalculator.PositionBalance memory)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == asset) return pos[i];
        }
        revert("asset not found");
    }

    /// @dev `positionLabels` is display-only and must never revert, and must never label a coordinate this adapter
    ///      never emitted. Both were reachable before: `abi.decode(pid, (address))` reverts on a word with dirty
    ///      upper 96 bits, and a `pid.length < 32` guard let a foreign MULTI-word coordinate through to be labelled
    ///      from its first word. The decode now goes through `MetaBalanceAdapter._pidAddress`, whose own accept window is
    ///      pinned exhaustively in `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case pins that THIS
    ///      adapter routes through it.
    ///
    ///      The clean-coordinate assertion is what keeps the rest load-bearing. A shape-valid but unknown
    ///      coordinate still resolves to the category-only label (the fail-open leaf collapse), so a view that
    ///      rejected everything would fail here rather than pass the rejections trivially.

    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        address coord = address(0xBEEF);

        assertGt(meta.positionLabels(abi.encode(coord)).length, 0, "one clean word is the accepted shape");

        assertEq(meta.positionLabels("").length, 0, "empty");
        assertEq(meta.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(coord)) | (uint256(1) << 255);
        assertEq(meta.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(meta.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }
}
