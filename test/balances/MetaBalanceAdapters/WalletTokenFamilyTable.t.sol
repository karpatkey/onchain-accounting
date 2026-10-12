// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test, Vm} from "forge-std/Test.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {
    WalletTokenMetaBalanceAdapterBase
} from "src/balances/MetaBalanceAdapters/WalletTokenMetaBalanceAdapterBase.sol";
import {
    AaveSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AaveSavingsWalletMetaBalanceAdapter.sol";
import {
    AnkrStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AnkrStakedEthWalletMetaBalanceAdapter.sol";
import {
    CoinbaseStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/CoinbaseStakedEthWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";
import {
    EtherFiStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EtherFiStakedEthWalletMetaBalanceAdapter.sol";
import {
    KelpRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/KelpRestakedEthWalletMetaBalanceAdapter.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    LiquidCollectiveStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LiquidCollectiveStakedEthWalletMetaBalanceAdapter.sol";
import {
    MapleSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/MapleSavingsWalletMetaBalanceAdapter.sol";
import {
    NexusMutualVaultsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/NexusMutualVaultsWalletMetaBalanceAdapter.sol";
import {
    RenzoRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RenzoRestakedEthWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    RocketPoolStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RocketPoolStakedEthWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    SparkSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SparkSavingsWalletMetaBalanceAdapter.sol";
import {
    StaderStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StaderStakedEthWalletMetaBalanceAdapter.sol";
import {
    StakeWiseV3OsTokenWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StakeWiseV3OsTokenWalletMetaBalanceAdapter.sol";

/// @dev Stand-in for the default adapter's inclusion list, reporting nothing as included — the
///      post-exclusion steady state, which is the only state in which this family reports at all.
contract NothingIncludedStub {
    function isSupportedByDefault(address) external pure returns (bool) {
        return false;
    }
}

/// @title Wallet-yield family truth table
/// @author KPK
/// @notice Pins the `positionKind` of EVERY member of the wallet-held yield-token family, and ties a new
///         member to this table with a census.
/// @dev The family's unit suite next door tests the shared BASE thoroughly, but asserts identity on only four
///      of the seventeen members. The remaining thirteen could each carry the wrong `positionKind` — the one
///      field a subclass exists to set — and nothing would say so. `positionKind` does not affect NAV value,
///      which is exactly why no value test can catch it: it is the reconciliation key an accounting consumer
///      joins on, so a wrong kind is a silently mis-attributed position rather than a wrong number.
///
///      The kind is not a free choice. The rule is the protocol's own verb for the PAR-EXIT path: unstake,
///      withdrawal queue or cooldown over staked principal is `Staking`; redeeming a deposit or vault share is
///      `Supplied`. Secondary-market sellability is irrelevant, as is a wrapper's liquidity buffer. Each row
///      below is that rule applied, so a future edit that "fixes" one to match a marketing label fails here.
///
///      Two rows are worth naming because the rule and intuition disagree:
///
///        * **Ethena (sUSDe) is `Staking`, not `Supplied`.** It looks like a savings vault, but its exit is
///          `cooldownShares`, and classifying it as staking keeps it coherent with the separate
///          `EthenaCooldownBalanceAdapter` that reports the same position mid-cooldown.
///        * **Reserve (ETH+) is `Supplied`, not `Staking`.** Its config label says "LST" and it holds staked
///          ETH underneath, but Reserve itself stakes nothing — the exit is a basket redeem. The verb rule
///          answers on Reserve's own exit path, not on what its collateral happens to be.
contract WalletTokenFamilyTableTest is Test {
    /// @dev Number of concrete adapters under `src/balances/MetaBalanceAdapters/walletYield/`. Pinned so that
    ///      adding one fails {test_walletYieldFamilyCensus} until its kind is also pinned below.
    uint256 internal constant WALLET_YIELD_ADAPTER_COUNT = 17;

    Mock_NAVCalculator internal nav;
    Mock_ERC20 internal token;
    address internal alice = address(0xA11CE);

    address[] internal adapters;
    PositionKind[] internal expectedKinds;
    string[] internal labels;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        // Armed BEFORE any adapter is constructed: `ERC20_DEFAULT_ADAPTER` is immutable, so an adapter built
        // while the mock still answers address(0) would be permanently disarmed.
        nav.setErc20DefaultBalanceAdapter(address(new NothingIncludedStub()));
        token = new Mock_ERC20("YIELD", 18);
        nav.registerAsset(address(token), 18, "YIELD");
        _row(address(new AaveSavingsWalletMetaBalanceAdapter(address(nav))), PositionKind.Supplied, "AaveSavings");
        _row(address(new AnkrStakedEthWalletMetaBalanceAdapter(address(nav))), PositionKind.Staking, "AnkrStakedEth");
        _row(
            address(new CoinbaseStakedEthWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "CoinbaseStakedEth"
        );
        _row(address(new EthenaSavingsWalletMetaBalanceAdapter(address(nav))), PositionKind.Staking, "EthenaSavings");
        _row(
            address(new EtherFiStakedEthWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "EtherFiStakedEth"
        );
        _row(
            address(new KelpRestakedEthWalletMetaBalanceAdapter(address(nav))), PositionKind.Staking, "KelpRestakedEth"
        );
        _row(address(new LidoStakedEthWalletMetaBalanceAdapter(address(nav))), PositionKind.Staking, "LidoStakedEth");
        _row(
            address(new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "LiquidCollectiveStakedEth"
        );
        _row(address(new MapleSavingsWalletMetaBalanceAdapter(address(nav))), PositionKind.Supplied, "MapleSavings");
        _row(
            address(new NexusMutualVaultsWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Supplied,
            "NexusMutualVaults"
        );
        _row(
            address(new RenzoRestakedEthWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "RenzoRestakedEth"
        );
        _row(address(new ReserveBasketsWalletMetaBalanceAdapter(address(nav))), PositionKind.Supplied, "ReserveBaskets");
        _row(
            address(new RocketPoolStakedEthWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "RocketPoolStakedEth"
        );
        _row(address(new SkySavingsWalletMetaBalanceAdapter(address(nav))), PositionKind.Supplied, "SkySavings");
        _row(address(new SparkSavingsWalletMetaBalanceAdapter(address(nav))), PositionKind.Supplied, "SparkSavings");
        _row(
            address(new StaderStakedEthWalletMetaBalanceAdapter(address(nav))), PositionKind.Staking, "StaderStakedEth"
        );
        _row(
            address(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(address(nav))),
            PositionKind.Staking,
            "StakeWiseV3OsToken"
        );
    }

    function _row(address a, PositionKind k, string memory label) internal {
        adapters.push(a);
        expectedKinds.push(k);
        labels.push(label);
    }

    function _ins() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(address(token))));
    }

    /// @notice Every member reports the kind its protocol's exit path implies.
    function test_everyMemberReportsItsPinnedKind() public {
        token.mint(alice, 1e18);
        for (uint256 i; i < adapters.length; ++i) {
            INAVCalculator.PositionBalance[] memory p = WalletTokenMetaBalanceAdapterBase(adapters[i])
                .getAdapterPositionsForInstances(alice, _ins(), address(0));
            assertEq(p.length, 1, string.concat(labels[i], ": expected exactly one leg"));
            assertEq(
                uint256(uint8(p[0].positionKind)),
                uint256(uint8(expectedKinds[i])),
                string.concat(labels[i], ": positionKind does not match the par-exit rule")
            );
        }
    }

    /// @notice Every member is value-neutral: the amount is the raw balance, for all seventeen.
    /// @dev The migration's whole safety claim. The four-member identity suite next door proves it for four;
    ///      a subclass that introduced a conversion would be invisible in the other thirteen.
    function test_everyMemberIsValueNeutral() public {
        token.mint(alice, 7.25e18);
        for (uint256 i; i < adapters.length; ++i) {
            INAVCalculator.PositionBalance[] memory p = WalletTokenMetaBalanceAdapterBase(adapters[i])
                .getAdapterPositionsForInstances(alice, _ins(), address(0));
            assertEq(p[0].amount, 7.25e18, string.concat(labels[i], ": amount must equal balanceOf exactly"));
            assertEq(p[0].balanceAsset.asset, address(token), string.concat(labels[i], ": asset must be the token"));
            assertFalse(p[0].isDebt, string.concat(labels[i], ": must never be debt"));
        }
    }

    /// @notice Members do not share a `protocolSubId` — each is a distinct reconciliation namespace.
    /// @dev Two members sharing a subId would silently merge two protocols' positions under one key, which is
    ///      the failure this family exists to prevent in the first place.
    function test_everyMemberHasADistinctSubId() public {
        token.mint(alice, 1e18);
        bytes32[] memory seen = new bytes32[](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            INAVCalculator.PositionBalance[] memory p = WalletTokenMetaBalanceAdapterBase(adapters[i])
                .getAdapterPositionsForInstances(alice, _ins(), address(0));
            assertTrue(p[0].protocolSubId != bytes32(0), string.concat(labels[i], ": subId must be set"));
            for (uint256 j; j < i; ++j) {
                assertTrue(
                    seen[j] != p[0].protocolSubId, string.concat(labels[i], ": protocolSubId collides with ", labels[j])
                );
            }
            seen[i] = p[0].protocolSubId;
        }
    }

    /// @notice The table covers the whole family.
    /// @dev Without this, adding an eighteenth adapter simply leaves it untested — the tables above iterate
    ///      what `setUp` registered, so they would pass at seventeen forever. Counts compiled artifacts whose
    ///      source still lives under `walletYield/`, the same shape as the meta-adapter censuses.
    function test_walletYieldFamilyCensus() public view {
        assertEq(adapters.length, WALLET_YIELD_ADAPTER_COUNT, "table does not cover the pinned family size");
        assertEq(
            _countWalletYieldAdapters("out"),
            WALLET_YIELD_ADAPTER_COUNT,
            "walletYield adapter count changed: add the new adapter to setUp with its par-exit kind and bump"
            " WALLET_YIELD_ADAPTER_COUNT."
        );
    }

    /// @dev Counts concrete artifacts compiled from `src/balances/MetaBalanceAdapters/walletYield/`. Filtering
    ///      on the recorded source path is required, not tidy: the `unit` CI job does not compile, it downloads
    ///      the build job's `out/`, which is produced incrementally on a BRANCH-SHARED sticky disk and so
    ///      carries artifacts belonging to other branches entirely.
    function _countWalletYieldAdapters(string memory relDir) internal view returns (uint256 count) {
        Vm.DirEntry[] memory dirs = vm.readDir(string.concat(vm.projectRoot(), "/", relDir));
        for (uint256 i; i < dirs.length; ++i) {
            if (!_endsWith(dirs[i].path, "WalletMetaBalanceAdapter.sol")) continue;
            Vm.DirEntry[] memory artifacts = vm.readDir(dirs[i].path);
            for (uint256 j; j < artifacts.length; ++j) {
                if (!_endsWith(artifacts[j].path, "WalletMetaBalanceAdapter.json")) continue;
                string memory json = vm.readFile(artifacts[j].path);
                if (bytes(vm.parseJsonString(json, ".bytecode.object")).length <= 2) continue; // abstract/iface
                if (!vm.keyExists(json, ".ast.absolutePath")) continue;
                string memory src = vm.parseJsonString(json, ".ast.absolutePath");
                if (!_contains(src, "/walletYield/")) continue;
                // `vm.exists` REVERTS outside `fs_permissions`; a production adapter always lives under `src/`.
                if (!_startsWith(src, "src/")) continue;
                if (!vm.exists(string.concat(vm.projectRoot(), "/", src))) continue;
                ++count;
            }
        }
    }

    function _startsWith(string memory v, string memory p) internal pure returns (bool) {
        bytes memory b = bytes(v);
        bytes memory q = bytes(p);
        if (b.length < q.length) return false;
        for (uint256 i; i < q.length; ++i) {
            if (b[i] != q[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory v, string memory s) internal pure returns (bool) {
        bytes memory b = bytes(v);
        bytes memory q = bytes(s);
        if (b.length < q.length) return false;
        for (uint256 i; i < q.length; ++i) {
            if (b[b.length - q.length + i] != q[i]) return false;
        }
        return true;
    }

    function _contains(string memory v, string memory needle) internal pure returns (bool) {
        bytes memory b = bytes(v);
        bytes memory n = bytes(needle);
        if (b.length < n.length) return false;
        for (uint256 i; i <= b.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (b[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
