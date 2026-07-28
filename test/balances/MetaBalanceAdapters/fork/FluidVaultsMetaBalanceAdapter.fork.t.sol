// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title FluidVaultsMetaParityForkTest
/// @notice Validates the Fluid vaults meta-adapter against the real mainnet wstETH/USDC T1 vault: the on-chain
///         `constantsView` token decode + VaultResolver read path of the meta-adapter
///         (parity over getAdapterPositions). Both adapters share one BalancesHarnessForFork.
contract FluidVaultsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant VAULT = 0x51197586F6A9e2571868b6ffaef308f3bdfEd3aE; // wstETH/USDC
    address public constant VAULT_B = 0x4045720a33193b4Fe66c94DFbc8D37B0b4D9B469; // sUSDe/USDC (configured)
    address public constant VAULT_C = 0x40D9b8417E6E1DcD358f04E3328bCEd061018A82; // weETH/wstETH (configured)
    address public constant VAULT_A_TWIN = 0x1982CC7b1570C2503282d0A0B41F69b3B28fdcc3; // same wstETH/USDC pair
    address public constant SMART_VAULT = 0xe0E722E9daF03b468a05Aca6cCE8D2e9F91D1e6D; // T3 (type 30000)
    address public constant VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant FORK_BLOCK = 23_950_000;

    address public user = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

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
        balances = _deployBalancesForAdapter(assetsList);

        meta = new FluidVaultsMetaBalanceAdapter(VAULT_RESOLVER, address(balances));
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

    /// @notice Meta-adapter returns positions for user in the vault.
    function test_metaBalance_doesNotRevert() public view {
        // Verifies the adapter resolves the vault's tokens via constantsView and aggregates NFT positions
        // without reverting. A holder with positions in this specific vault would assert amounts > 0;
        // this test validates the call path regardless of whether the test address holds a position.
        meta.getAdapterPositionsForInstances(user, _instance(), address(0));
    }

    /// @notice The meta-adapter decodes the real vault's tokens (wstETH collateral, USDC debt) via constantsView.
    function test_instanceAssets_decodedFromVault() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instance());
        assertEq(a.length, 2);
        assertEq(a[0], WSTETH, "collateral token");
        assertEq(a[1], USDC, "debt token");
    }

    /// @notice Two real configured vaults must be distinguishable by their final label element — the whole
    ///         point of the change (both previously returned just ["Vault"]).
    function test_positionLabels_realVaults_haveDistinctLeaves() public view {
        string[] memory a = meta.positionLabels(abi.encode(VAULT));
        string[] memory b = meta.positionLabels(abi.encode(VAULT_B));

        assertEq(a.length, 2, "wstETH/USDC vault: expected [category, leaf]");
        assertEq(b.length, 2, "sUSDe/USDC vault: expected [category, leaf]");
        assertEq(a[0], "Vault");
        assertEq(a[1], "wstETH/USDC #4");
        assertEq(b[1], "sUSDe/USDC #7");
        assertTrue(
            keccak256(bytes(a[a.length - 1])) != keccak256(bytes(b[b.length - 1])),
            "two configured vaults share a final label element"
        );
    }

    /// @notice A real Smart (T3) vault is gated. NOTE: this alone does not prove the gate works — the T1
    ///         decode already reverts on this vault (its `constantsView` word 6, a `uint8` slot, holds an
    ///         address), so these assertions also hold with the gate removed. See
    ///         `test_gate_isLoadBearing_whenResolverTypesVaultNonT1` for the real regression test.
    function test_smartVault_isGated() public view {
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(SMART_VAULT)));

        assertEq(meta.getAdapterPositionsForInstances(user, ins, address(0)).length, 0, "no legs for a T3 vault");

        string[] memory l = meta.positionLabels(abi.encode(SMART_VAULT));
        assertEq(l.length, 1, "smart vault collapses to the category-only label");
        assertEq(l[0], "Vault");
    }

    /// @notice The gate must be load-bearing: a genuine, cleanly-decoding T1 vault that the resolver types as
    ///         non-T1 must report nothing. Without the gate this vault decodes fine and labels normally, so
    ///         deleting or inverting the gate fails this test.
    function test_gate_isLoadBearing_whenResolverTypesVaultNonT1() public {
        // Sanity: ungated, this vault is fully readable.
        assertEq(meta.positionLabels(abi.encode(VAULT))[1], "wstETH/USDC #4");

        vm.mockCall(
            VAULT_RESOLVER,
            abi.encodeWithSignature("getVaultType(address)", VAULT),
            abi.encode(uint256(30000)) // resolver now claims this T1 vault is a Smart vault
        );

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(VAULT)));
        assertEq(meta.getAdapterPositionsForInstances(user, ins, address(0)).length, 0, "gate must drop legs");
        assertEq(meta.underlyingAssetsSupportedForInstances(ins).length, 0, "gate must drop assets");
        assertEq(meta.positionLabels(abi.encode(VAULT)).length, 1, "gate must collapse the label");
        vm.clearMockedCalls();
    }

    /// @notice All three mainnet-configured vaults resolve through the gate and label distinctly.
    function test_allConfiguredVaults_readThroughGate() public view {
        address[3] memory vaults = [VAULT, VAULT_B, VAULT_C];
        string[3] memory expected = ["wstETH/USDC #4", "sUSDe/USDC #7", "weETH/wstETH #6"];
        for (uint256 i = 0; i < vaults.length; i++) {
            bytes32[] memory ins = new bytes32[](1);
            ins[0] = bytes32(uint256(uint160(vaults[i])));
            assertEq(meta.underlyingAssetsSupportedForInstances(ins).length, 2, "configured vault must resolve");
            string[] memory l = meta.positionLabels(abi.encode(vaults[i]));
            assertEq(l.length, 2, "configured vault must have a leaf");
            assertEq(l[1], expected[i]);
        }
    }

    /// @notice A real same-pair twin of a configured vault: the pair alone would collide, the id keeps them
    ///         distinct. 0x1982CC7b is a second live wstETH/USDC T1 vault.
    function test_samePairTwin_hasDistinctLeaf() public view {
        string[] memory a = meta.positionLabels(abi.encode(VAULT));
        string[] memory t = meta.positionLabels(abi.encode(VAULT_A_TWIN));

        // Both must actually HAVE a leaf — without this the inequality below passes vacuously when the twin
        // resolves to nothing and labels ["Vault"], proving nothing about same-pair distinctness.
        assertEq(a.length, 2, "configured vault must have a leaf");
        assertEq(t.length, 2, "twin must have a leaf");
        assertEq(a[1], "wstETH/USDC #4");
        assertEq(t[1], "wstETH/USDC #14", "twin shares the pair, differs only by vault id");
        assertTrue(
            keccak256(bytes(t[t.length - 1])) != keccak256(bytes(a[a.length - 1])),
            "same-pair twin must not share the configured vault's leaf"
        );
    }
}
