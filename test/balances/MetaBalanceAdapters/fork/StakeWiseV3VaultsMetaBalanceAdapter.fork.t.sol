// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title StakeWiseV3VaultsMetaParityForkTest (Gnosis)
/// @notice Fork tests for the StakeWise V3 vaults meta-adapter against real Gnosis contracts.
///         leg-for-leg (exact) against the real Gnosis Genesis vault and real holders. Both adapters share one
///         BalancesHarnessForFork registry.
contract StakeWiseV3VaultsMetaParityForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant VAULT = 0x4b4406Ed8659D03423490D8b62a1639206dA0A7a;
    address public constant TEST_USER = 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f;
    address public constant TEST_USER2 = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

    /// @dev The two other configured Gnosis instances (see
    ///      `script/config/nav-config/meta-balance-adapters/100.json`). Both are `GnoVault` implementations, which
    ///      are not ERC20s and whose `name()` reverts — they pin the tier-2 symbol+address fallback branch.
    address public constant CONFIGURED_VAULT_2 = 0x00025C729A3364FaEf02c7D1F577068d87E90ba6;
    address public constant CONFIGURED_VAULT_3 = 0x2Cd404D9d75436e7d6dDbCcc2fB9cF7C06941BF1;

    /// @dev Two real `GnoErc20Vault` instances registered in the Gnosis `VaultsRegistry` (0x7d014B3C…). They are not
    ///      configured on NAVCalculator today, but adding one is a MANAGER `addMetaInstances` config TX against this
    ///      immutable adapter — so the named branch must work on real chain state, not just against mocks.
    address public constant NAMED_VAULT_A = 0x5fa6AA1EBBbbcBFD8757B6F56ABBE468AC3a6026; // "Stakers Union GNO"
    address public constant NAMED_VAULT_B = 0x5F07fa4f2F9173D6d9a3dBcF24C0933213CEF7B7; // "Portugal Staked GNO"
    uint256 public constant FORK_BLOCK_1 = 38_449_644;
    uint256 public constant FORK_BLOCK_2 = 35_261_999;

    StakeWiseV3VaultsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
    }

    function _deploy() internal {
        balances = _deployBalancesForAdapter(GNO);
        // Gnosis StakeWise OsTokenVaultController (same one osToken_CustomPriceFeed uses for osGNO).
        meta =
            new StakeWiseV3VaultsMetaBalanceAdapter(GNO, 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a, address(balances));
    }

    function _vaultInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(VAULT)));
    }

    /// @notice Sums (staking, borrow) over a position array.
    function _legs(INAVCalculator.PositionBalance[] memory p) internal pure returns (uint256 staking, uint256 borrow) {
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].isDebt) borrow += p[i].amount;
            else staking += p[i].amount;
        }
    }

    function test_user1_hasPosition() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();
        (uint256 s, uint256 b) = _legs(meta.getAdapterPositionsForInstances(TEST_USER, _vaultInstance(), address(0)));
        assertTrue(s > 0 || b > 0, "user1 should have a position");
    }

    function test_user2_withDebt() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_2);
        _deploy();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER2, _vaultInstance(), address(0));
        assertTrue(p.length > 0, "user2 should have a position");
    }

    function test_identityDerivedOnChain() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER, _vaultInstance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(VAULT), "positionId = vault address");
            assertEq(p[i].balanceAsset.asset, GNO);
        }
    }

    /// @notice Two real ERC20-variant vaults yield different final label elements — the property the leaf exists for.
    function test_positionLabels_distinctForNamedVaults() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();

        string[] memory a = meta.positionLabels(abi.encode(NAMED_VAULT_A));
        string[] memory b = meta.positionLabels(abi.encode(NAMED_VAULT_B));

        assertEq(a.length, 2, "named vault yields category + leaf");
        assertEq(a[0], "Vault");
        assertEq(a[1], "Stakers Union GNO");

        assertEq(b.length, 2);
        assertEq(b[0], "Vault");
        assertEq(b[1], "Portugal Staked GNO");

        assertTrue(
            keccak256(bytes(a[a.length - 1])) != keccak256(bytes(b[b.length - 1])),
            "distinct instances must produce distinct final label elements"
        );
    }

    /// @notice The three configured Gnosis instances are non-ERC20 vaults whose `name()` reverts on chain, so each
    ///         falls back to `"GNO <vault address>"` — a non-blank, per-instance leaf. This is the case the change
    ///         exists for: on `main` all three rendered an identical `["Vault"]`.
    /// @dev The on-chain counterpart of `test_positionLabels_distinctForUnnamedVaults`, and the reason the leaf
    ///      keeps the address even though consumers render a coordinate column beside it (settled 2026-07-27 —
    ///      see the `positionLabels` NatSpec). These three are REAL unnamed `GnoVault`s, not mocks, so this is the
    ///      direct evidence that a symbol-only leaf would collapse all of them to one `["Vault", "GNO"]`. The
    ///      pairwise loop below is the assertion that would fail; it is the point of the test, not a formality.
    function test_positionLabels_configuredVaults_fallBackToSymbolAndAddress() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();

        address[] memory configured = new address[](3);
        configured[0] = VAULT;
        configured[1] = CONFIGURED_VAULT_2;
        configured[2] = CONFIGURED_VAULT_3;

        bytes32[] memory leaves = new bytes32[](configured.length);
        for (uint256 i = 0; i < configured.length; i++) {
            string[] memory l = meta.positionLabels(abi.encode(configured[i]));
            assertEq(l.length, 2, "leaf present for a vault with no on-chain name");
            assertEq(l[0], "Vault");
            assertEq(l[1], string.concat("GNO ", configured[i].toHexString()));
            leaves[i] = keccak256(bytes(l[1]));
        }

        // The property the change exists for: no two configured instances share a final label element.
        for (uint256 i = 0; i < leaves.length; i++) {
            for (uint256 j = i + 1; j < leaves.length; j++) {
                assertTrue(leaves[i] != leaves[j], "configured instances must produce distinct final label elements");
            }
        }
    }

    /// @notice A positionId pointing at a code-less address must not revert this display-only view.
    function test_positionLabels_noCode_failsOpen() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();
        string[] memory l = meta.positionLabels(abi.encode(address(0xdead)));
        assertEq(l.length, 2);
        assertEq(l[0], "Vault");
        assertEq(l[1], string.concat("GNO ", address(0xdead).toHexString()));
    }
}
