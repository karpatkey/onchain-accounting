// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancerV2GaugesMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV2GaugesMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IBalV2Vault {
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface IV2Gauge {
    function lp_token() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface IV2Bpt {
    function getPoolId() external view returns (bytes32);
    function totalSupply() external view returns (uint256);
}

/// @title BalancerV2GaugesMetaForkTest
/// @notice Proves BalancerV2GaugesMetaBalanceAdapter reproduces the on-chain pro-rata share of a real account's
///         gauge-staked BPT for the B-stETH-STABLE gauge on mainnet. Expected per-token amounts are computed
///         directly from the Vault's live balances and the BPT supply (`balances[i] * staked / totalSupply`), so
///         this is a self-consistent oracle test (no per-instance V2 gauge adapter exists to parity against). The
///         BAL inflation math is byte-identical to BalancerV3GaugesMeta (real-staker fork-tested there); the
///         staked-share decomposition uses the same BalancerV2PoolLib proven in BalancerV2PoolsMeta.fork.t.sol.
contract BalancerV2GaugesMetaForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant BALANCER_MINTER = 0x239e55F427D44C3cc793f49bFB507ebe76638a2b;
    address public constant GAUGE = 0xcD4722B7c24C29e0413BDCd9e51404B4539D14aE; // B-stETH-STABLE gauge
    address public constant BPT = 0x32296969Ef14EB0c6d29669C550D4a0449130230; // Balancer stETH Stable Pool

    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = MAINNET_WETH;
    address public constant LDO = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32; // gauge extra reward token
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    // Account with a live staked balance in the gauge at FORK_BLOCK.
    address public constant STAKER = 0x1c953fd17bE2812AB08bbbE221BB7d2687fc884B;

    uint256 public constant FORK_BLOCK = 25_214_000;

    BalancerV2GaugesMetaBalanceAdapter public adapter;

    function setUp() public override {
        _setupFork();
        balances = _deployBalancesForOracle(_supportedAssets());
        adapter = new BalancerV2GaugesMetaBalanceAdapter(VAULT, BALANCER_MINTER, "Balancer V2", address(balances));
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _supportedAssets() internal pure returns (address[] memory assets) {
        assets = new address[](4);
        assets[0] = WSTETH;
        assets[1] = WETH;
        assets[2] = LDO;
        assets[3] = BAL;
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(GAUGE)));
    }

    /// @notice Staking legs equal `vaultBalance[token] * staked / totalSupply`, read live from chain.
    function test_stakedShareMatchesOnChain() public view {
        uint256 staked = IV2Gauge(GAUGE).balanceOf(STAKER);
        assertGt(staked, 0, "staker must have a gauge balance at this block");
        bytes32 poolId = IV2Bpt(BPT).getPoolId();
        uint256 ts = IV2Bpt(BPT).totalSupply();
        (address[] memory tokens, uint256[] memory bals,) = IBalV2Vault(VAULT).getPoolTokens(poolId);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(STAKER, _instance(), address(0));

        uint256 stakingLegs;
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceOracle, address(adapter));
            assertFalse(pos[i].isDebt);
            assertEq(pos[i].protocol, "Balancer V2");
            assertEq(pos[i].positionId, GAUGE.toHexString(), "positionId = gauge address");

            // Staking legs (wstETH / WETH) must match the pro-rata Vault share. Reward legs (LDO/BAL), if any,
            // are not pro-rata of the pool — skip them here (covered by the unit + V3 reward fork tests).
            address tok = pos[i].underlyingAsset.asset;
            if (tok != WSTETH && tok != WETH) continue;
            stakingLegs++;
            uint256 vaultBal;
            for (uint256 j = 0; j < tokens.length; j++) {
                if (tokens[j] == tok) vaultBal = bals[j];
            }
            assertEq(pos[i].amount, vaultBal * staked / ts, "staking leg = pro-rata share of Vault balance");
        }
        assertGt(stakingLegs, 0, "expected at least one staking leg");
    }

    /// @notice Identity (name + type) is derived on-chain from the gauge's lp_token BPT name.
    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(STAKER, _instance(), WSTETH);
        assertEq(pos.length, 1);
        assertEq(
            pos[0].positionDetail,
            "{\"protocol\":\"Balancer V2\",\"product\":\"LP\",\"name\":\"Balancer stETH Stable Pool\",\"type\":\"Staking\"}"
        );
    }

    /// @notice underlyingAssetsSupportedForInstances decodes pool tokens + reward tokens + BAL.
    function test_instanceAssets() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instance());
        // wstETH, WETH, LDO (reward), BAL
        assertEq(assets.length, 4);
        assertEq(assets[0], WSTETH);
        assertEq(assets[1], WETH);
        assertEq(assets[2], LDO);
        assertEq(assets[3], BAL);
    }
}
