// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancerV2PoolsMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV2PoolsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IBalV2Vault {
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface IBalV2Bpt {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title BalancerV2PoolsMetaForkTest
/// @notice Proves BalancerV2PoolsMetaBalanceAdapter reproduces the on-chain pro-rata share of a real account's
///         wallet-held BPT for the canonical B-80BAL-20WETH pool on mainnet. The expected per-token amounts are
///         computed directly from the Vault's live balances and the BPT supply (`balances[i] * walletBpt /
///         totalSupply`), so this is a self-consistent oracle test (no per-instance V2 adapter exists to parity
///         against). B-80BAL-20WETH is a legacy weighted pool, so `getActualSupply()` reverts and the adapter
///         falls back to `totalSupply()`.
contract BalancerV2PoolsMetaForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant BPT = 0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56; // Balancer 80 BAL 20 WETH
    bytes32 public constant POOL_ID = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;

    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    address public constant WETH = MAINNET_WETH;

    // EOA holding ~16,915 B-80BAL-20WETH BPT in-wallet at FORK_BLOCK.
    address public constant HOLDER = 0xc9Cea7A3984CefD7a8D2A0405999CB62e8d206DC;

    uint256 public constant FORK_BLOCK = 25_214_000;

    BalancerV2PoolsMetaBalanceAdapter public adapter;

    function setUp() public override {
        _setupFork();
        balances = _deployBalancesForOracle(_supportedAssets());
        adapter = new BalancerV2PoolsMetaBalanceAdapter(VAULT, "Balancer V2", address(balances));
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _supportedAssets() internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = BAL;
        assets[1] = WETH;
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = POOL_ID; // raw poolId, used directly
    }

    /// @notice Each emitted leg equals `vaultBalance[token] * walletBpt / totalSupply`, read live from chain.
    function test_walletShareMatchesOnChain() public view {
        uint256 walletBpt = IBalV2Bpt(BPT).balanceOf(HOLDER);
        uint256 ts = IBalV2Bpt(BPT).totalSupply();
        assertGt(walletBpt, 0, "holder must hold BPT at this block");

        (address[] memory tokens, uint256[] memory bals,) = IBalV2Vault(VAULT).getPoolTokens(POOL_ID);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(HOLDER, _instance(), address(0));
        assertEq(pos.length, 2, "BAL + WETH legs");

        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceOracle, address(adapter));
            assertFalse(pos[i].isDebt);
            assertEq(pos[i].protocol, "Balancer V2");
            assertEq(pos[i].positionId, BPT.toHexString(), "positionId = BPT address");

            address tok = pos[i].underlyingAsset.asset;
            // Find this token's live Vault balance.
            uint256 vaultBal;
            for (uint256 j = 0; j < tokens.length; j++) {
                if (tokens[j] == tok) vaultBal = bals[j];
            }
            assertEq(pos[i].amount, vaultBal * walletBpt / ts, "leg = pro-rata share of Vault balance");
        }
    }

    /// @notice assetFilter restricts the legs to a single underlying token.
    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory pos = adapter.getOraclePositionsForInstances(HOLDER, _instance(), WETH);
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, WETH);
    }

    /// @notice Identity (name) is derived on-chain from the BPT token name.
    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(HOLDER, _instance(), address(0));
        assertEq(
            pos[0].positionDetail,
            "{\"protocol\":\"Balancer V2\",\"product\":\"LP\",\"name\":\"Balancer 80 BAL 20 WETH\",\"type\":\"Supply\"}"
        );
    }

    /// @notice underlyingAssetsSupportedForInstances decodes the pool's tokens from the Vault.
    function test_instanceAssets() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instance());
        assertEq(assets.length, 2);
        assertEq(assets[0], BAL);
        assertEq(assets[1], WETH);
    }
}
