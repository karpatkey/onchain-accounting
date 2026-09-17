// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";

/// @notice Minimal meta-adapter: reports one `Staking` leg per governed coordinate, treating the coordinate as
///         an ERC20 whose balance is the position. That is the wallet-yield shape — the family whose
///         coordinates are plain token addresses, and therefore the one that can collide with the default
///         adapter's namespace. No mock in `test/mocks/` implements `IMetaBalanceAdapter`; every existing
///         meta registration test is a fork test, which is precisely why the unit-level ownership rules below
///         went unexercised.
contract Mock_OwnershipMetaAdapter is IMetaBalanceAdapter {
    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IBalanceAdapter).interfaceId || id == type(IMetaBalanceAdapter).interfaceId
            || id == type(IERC165).interfaceId;
    }

    function getAdapterPositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _positions(account, instances, assetFilter);
    }

    function _positions(address account, bytes32[] memory instances, address)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = new INAVCalculator.PositionBalance[](instances.length);
        uint256 n;
        for (uint256 i; i < instances.length; ++i) {
            address token = address(uint160(uint256(instances[i])));
            if (token == address(0)) continue;
            positions[n] = INAVCalculator.PositionBalance({
                balanceAsset: INAVCalculator.Asset({asset: token, symbol: "T", decimals: 18}),
                balanceAdapter: address(this),
                amount: Mock_ERC20(token).balanceOf(account),
                isDebt: false,
                protocolBrand: "mock",
                protocolId: "mock",
                protocolSubId: "mock-vaults",
                positionId: abi.encode(token),
                positionKind: PositionKind.Staking,
                isLocked: false,
                positionInstanceId: bytes32(0)
            });
            ++n;
        }
        assembly {
            mstore(positions, n)
        }
    }

    function getAdapterPositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        // Mirrors `MetaBalanceAdapter`: read the NAV-configured set and fan out over it.
        return _positions(account, IBalances(msg.sender).getMetaInstances(address(this)), assetFilter);
    }

    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        pure
        returns (address[] memory a)
    {
        a = new address[](instances.length);
        for (uint256 i; i < instances.length; ++i) {
            a[i] = address(uint160(uint256(instances[i])));
        }
    }

    function underlyingAssetsSupported() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterBalanceForAsset(address, address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function getAdapterBalances(address) external pure returns (address[] memory, uint256[] memory, bool[] memory) {
        return (new address[](0), new uint256[](0), new bool[](0));
    }
}

/// @notice Drives the meta-instance lifecycle the existing handler never touches. `NAVCalculator.handler.t.sol`
///         exercises registerAsset / addAdapter / removeAdapter only, so no fuzz campaign in this repo has ever
///         called addMetaInstances, removeMetaInstances, addMetaBalanceAdapter or either default-adapter
///         inclusion toggle — the four writers between them own every route by which a holding can acquire a
///         second reporter.
/// @dev Every action swallows reverts. A refusal is the system working; only a SUCCEEDING call that lands in a
///      bad state may break an invariant.
contract MetaOwnershipHandler is Test {
    NAVCalculator public nav;
    address public manager;

    Mock_ERC20[] public tokens;
    Mock_OwnershipMetaAdapter[] public metas;

    constructor(NAVCalculator _nav, address _manager) {
        nav = _nav;
        manager = _manager;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function metaCount() external view returns (uint256) {
        return metas.length;
    }

    function _coord(uint256 seed) internal view returns (bytes32) {
        if (tokens.length == 0) return bytes32(0);
        return bytes32(uint256(uint160(address(tokens[seed % tokens.length]))));
    }

    function _meta(uint256 seed) internal view returns (address) {
        if (metas.length == 0) return address(0);
        return address(metas[seed % metas.length]);
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _addrs(address v) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = v;
    }

    function registerAsset(uint256 seed) external {
        if (tokens.length >= 6) return;
        Mock_ERC20 t = new Mock_ERC20("T", 18);
        Mock_CustomPriceFeed f = new Mock_CustomPriceFeed("T", address(t), bound(seed, 1e6, 1e10), 8);
        vm.prank(manager);
        try nav.registerAsset(address(t), address(f), IPrices.PriceType.Custom, type(uint256).max) {
            tokens.push(t);
        } catch {}
    }

    function addMetaAdapter() external {
        if (metas.length >= 3) return;
        Mock_OwnershipMetaAdapter m = new Mock_OwnershipMetaAdapter();
        vm.prank(manager);
        try nav.addMetaBalanceAdapter(address(m), new bytes32[](0)) {
            metas.push(m);
        } catch {}
    }

    /// @dev The route that must refuse a coordinate another adapter already governs.
    function claimCoordinate(uint256 mSeed, uint256 cSeed) external {
        address m = _meta(mSeed);
        bytes32 c = _coord(cSeed);
        if (m == address(0) || c == bytes32(0)) return;
        vm.prank(manager);
        try nav.addMetaInstances(m, _one(c)) {} catch {}
    }

    function releaseCoordinate(uint256 mSeed, uint256 cSeed) external {
        address m = _meta(mSeed);
        bytes32 c = _coord(cSeed);
        if (m == address(0) || c == bytes32(0)) return;
        vm.prank(manager);
        try nav.removeMetaInstances(m, _one(c)) {} catch {}
    }

    /// @dev Retirement. Must hand every coordinate back, or a later re-registration revives it (issue #335).
    function retireMetaAdapter(uint256 mSeed) external {
        address m = _meta(mSeed);
        if (m == address(0)) return;
        vm.prank(manager);
        try nav.removeBalanceAdapters(_addrs(m)) {} catch {}
    }

    /// @dev Re-registration with an EMPTY list — the exact shape that revived dormant residue, because the
    ///      guard it replaced scanned the incoming batch and an empty batch skipped it.
    function reregisterMetaAdapter(uint256 mSeed) external {
        address m = _meta(mSeed);
        if (m == address(0)) return;
        vm.prank(manager);
        try nav.addMetaBalanceAdapter(m, new bytes32[](0)) {} catch {}
    }

    function includeAsset(uint256 cSeed) external {
        bytes32 c = _coord(cSeed);
        if (c == bytes32(0)) return;
        vm.prank(manager);
        try nav.includeAssetInDefaultAdapter(address(uint160(uint256(c)))) {} catch {}
    }

    function excludeAsset(uint256 cSeed) external {
        bytes32 c = _coord(cSeed);
        if (c == bytes32(0)) return;
        vm.prank(manager);
        try nav.excludeAssetFromDefaultAdapter(address(uint160(uint256(c)))) {} catch {}
    }

    function mint(uint256 cSeed, uint256 amt) external {
        bytes32 c = _coord(cSeed);
        if (c == bytes32(0)) return;
        Mock_ERC20(address(uint160(uint256(c)))).mint(address(this), bound(amt, 0, 1e24));
    }
}

/// @title Meta-instance ownership invariants
/// @notice The three properties that together say "exactly one thing reports any given holding". Each is read
///         through the PRODUCTION getters rather than through `_claimant`, so they assert the observable
///         behaviour and would still bind if the internal representation changed again.
/// @dev These are the invariants the claimant map exists to make true. A suite that stays green against a
///      known defect is decorative, so each was FALSIFIED by reintroducing a fixed defect in
///      `NAVRegistryLib` one at a time and requiring red (tree restored after each):
///
///        | defect reintroduced                          | unit tests red | invariants red |
///        |----------------------------------------------|----------------|----------------|
///        | inclusion gate removed from `includeAsset…`   | 2              | I2             |
///        | `_claim` no longer disarms the default adapter| 2              | I2             |
///        | dual-claim check removed from `_claim`        | 3              | I1, I2, I3     |
///
///      I1 and I3 stay green under the first two, correctly: neither creates a cross-adapter claim, so
///      neither reaches a duplicate reconciliation key. I2 is the one that catches all three, which is why
///      it is stated as "never both" rather than as an XOR.
contract MetaInstanceOwnershipInvariantTest is SuperTest {
    MetaOwnershipHandler public handler;

    function setUp() public {
        setupAll();
        handler = new MetaOwnershipHandler(nav, navCalculatorManager);
        vm.prank(admin);
        nav.grantRole(MANAGER, address(handler));
        targetContract(address(handler));
    }

    /// @notice I1 — no coordinate is governed by two adapters, and none appears twice within one adapter.
    /// @dev Both halves are over-reports: `MetaBalanceAdapter` does not dedupe on read, so a repeat inside one
    ///      set double-counts exactly as a cross-adapter claim does.
    function invariant_I1_singleClaimantPerCoordinate() external view {
        address[] memory adapters = nav.getAllAdapters();
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory a = nav.getMetaInstances(adapters[i]);
            for (uint256 x; x < a.length; ++x) {
                for (uint256 y = x + 1; y < a.length; ++y) {
                    assertTrue(a[x] != a[y], "I1: coordinate repeated within one adapter");
                }
                for (uint256 j = i + 1; j < adapters.length; ++j) {
                    bytes32[] memory b = nav.getMetaInstances(adapters[j]);
                    for (uint256 y; y < b.length; ++y) {
                        assertTrue(a[x] != b[y], "I1: coordinate claimed by two adapters");
                    }
                }
            }
        }
    }

    /// @notice I2 — no registered asset is BOTH armed on the default adapter and governed by a meta adapter.
    /// @dev Deliberately NOT the XOR. "Reported by nobody" is a licensed state — an operator may exclude an
    ///      asset and govern it nowhere — and this repo permits under-reporting everywhere. Two reporters is
    ///      the direction that is never licensed, so that is what the invariant forbids.
    function invariant_I2_neverIncludedAndClaimed() external view {
        ERC20DefaultBalanceAdapter def = ERC20DefaultBalanceAdapter(nav.erc20DefaultBalanceAdapter());
        address[] memory adapters = nav.getAllAdapters();
        uint256 n = handler.tokenCount();
        for (uint256 t; t < n; ++t) {
            address token = address(handler.tokens(t));
            if (!def.isSupportedByDefault(token)) continue;
            bytes32 coord = bytes32(uint256(uint160(token)));
            for (uint256 i; i < adapters.length; ++i) {
                bytes32[] memory a = nav.getMetaInstances(adapters[i]);
                for (uint256 x; x < a.length; ++x) {
                    assertTrue(
                        a[x] != coord, "I2: asset both included in default adapter and claimed by a meta adapter"
                    );
                }
            }
        }
    }

    /// @notice I3 — no two positions in a NAV read share a reconciliation key.
    /// @dev The end-to-end statement of the same property, and the one that matches how the +$11,375.92
    ///      double-count actually presented: two well-formed legs for one holding, summed, with no health
    ///      flag. I1/I2 constrain configuration; this constrains what a reader sees.
    function invariant_I3_noDuplicateReconciliationKey() external view {
        INAVCalculator.Position[] memory p = nav.getAccountPositions(address(handler), address(0));
        for (uint256 i; i < p.length; ++i) {
            for (uint256 j = i + 1; j < p.length; ++j) {
                bool same = p[i].balanceAsset.asset == p[j].balanceAsset.asset
                    && p[i].protocolSubId == p[j].protocolSubId && p[i].positionKind == p[j].positionKind
                    && keccak256(p[i].positionId) == keccak256(p[j].positionId);
                assertTrue(!same, "I3: two positions share a reconciliation key");
            }
        }
    }
}
