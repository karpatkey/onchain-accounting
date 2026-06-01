// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/protocols/FluidVaultsMeta.sol";
import {FluidVaultBalanceOracle} from "src/balances/protocols/FluidVault.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
/// @title FluidVaultsMetaParityForkTest
/// @notice Validates the Fluid vaults meta-adapter against the real mainnet wstETH/USDC T1 vault: the on-chain
///         `constantsView` token decode + VaultResolver read path match the per-vault FluidVaultBalanceOracle
///         (parity over getOraclePositions). Both adapters share one BalancesHarnessForFork.
contract FluidVaultsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant VAULT = 0x51197586F6A9e2571868b6ffaef308f3bdfEd3aE; // wstETH/USDC
    address public constant VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant FORK_BLOCK = 23_950_000;

    address public user = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

    FluidVaultBalanceOracle public per;
    FluidVaultsMetaBalanceAdapter public meta;
    address[] internal assetsList;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        assetsList = new address[](2);
        assetsList[0] = WSTETH;
        assetsList[1] = USDC;
        balances = _deployBalancesForOracle(assetsList);

        per = new FluidVaultBalanceOracle(VAULT, VAULT_RESOLVER, address(balances));
        meta = new FluidVaultsMetaBalanceAdapter(VAULT_RESOLVER, "Fluid", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(VAULT)));
    }

    function _sums(INAVCalculator.PositionBalance[] memory p, address asset)
        internal
        pure
        returns (uint256 credit, uint256 debt)
    {
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset != asset) continue;
            if (p[i].isDebt) debt += p[i].amount;
            else credit += p[i].amount;
        }
    }

    /// @notice Read-path parity: the meta-adapter's collateral/debt for the vault matches the per-vault adapter
    ///         (validates the on-chain constantsView decode + resolver NFT aggregation produce identical output).
    function test_parity() public view {
        INAVCalculator.PositionBalance[] memory perPos = per.getOraclePositions(user, address(0));
        INAVCalculator.PositionBalance[] memory metaPos =
            meta.getOraclePositionsForInstances(user, _instance(), address(0));
        for (uint256 a = 0; a < assetsList.length; a++) {
            (uint256 pc, uint256 pd) = _sums(perPos, assetsList[a]);
            (uint256 mc, uint256 md) = _sums(metaPos, assetsList[a]);
            assertEq(mc, pc, "collateral parity");
            assertEq(md, pd, "debt parity");
        }
    }

    /// @notice The meta-adapter decodes the real vault's tokens (wstETH collateral, USDC debt) via constantsView.
    function test_instanceAssets_decodedFromVault() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instance());
        assertEq(a.length, 2);
        assertEq(a[0], WSTETH, "collateral token");
        assertEq(a[1], USDC, "debt token");
    }
}
