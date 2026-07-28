// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {IProtocolDataProvider, IAavePool} from "../BalanceAdapters/SparkLendBalanceAdapter.sol";

/// @notice Minimal views to derive an instance's identity on-chain from its ProtocolDataProvider.
interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
    function getMarketId() external view returns (string memory);
}

/// @title Aave V3 Instances Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave V3 instance (Core,
///         Prime, an L2 market, …). The set of instances to query is configured on NAVCalculator and passed as
///         `bytes32` coordinates — here each coordinate is the instance's **ProtocolDataProvider address** (widened
///         to bytes32). Within an instance, reserves are enumerated trustlessly via `getAllReservesTokens()`, so
///         reserve tokens are NOT separate coordinates. Emits up to two legs per reserve (Supply/Collateral +
///         Borrow), matching the legs the now-removed per-instance Aave V3 adapter emitted before ADR 0010 folded
///         every instance into this single meta-adapter. See ADR 0010.
/// @dev **Instance set is a governed allowlist — not auto-enumerated.** Aave exposes an on-chain
///      `PoolAddressesProviderRegistry` (mainnet `0xbaA999AC55EAce41CcAE355c77809e68Bb345170`,
///      `getAddressesProvidersList()`) that lists registered markets, and this adapter could in principle read it to
///      avoid governance seeding instances. We deliberately do NOT: the active set stays the MANAGER-curated
///      `bytes32[]` on NAVCalculator. Rationale — (1) NAV integrity: balances are read trustlessly from the instance,
///      so auto-including arbitrary markets would let an untrusted instance report a fabricated balance in a
///      NAV-registered asset; the allowlist is the mitigation. (2) The registry is unreliable as a source of truth
///      here anyway — it is stale (still lists the deprecated EtherFi market) and incomplete (omits the Horizon RWA
///      market, whose provider was never added to it). Use the registry off-chain to *propose* instances; governance
///      approves them. See BALANCE_ADAPTERS.md §6.1.
contract AaveV3InstancesMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Aave's `ReserveConfiguration.MAX_RESERVES_COUNT` — the user-configuration bitmap packs 2 bits
    ///         per reserve into one word, so it addresses ids 0..127.
    uint256 private constant MAX_RESERVES = 128;

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the instance's ProtocolDataProvider. Emits up to two rows per registered reserve:
    ///      Supply/Collateral (aToken balance) and Borrow. Aave V3 deprecated NEW stable borrows but legacy stable
    ///      debt can persist, so the Borrow leg is `variableDebt + stableDebt` (dropping stable debt would understate
    ///      debt and overstate NAV). The two debt kinds are summed into ONE `Borrowed` leg rather than emitted
    ///      separately: they would otherwise share the same `(protocolSubId, positionId, balanceAsset, positionKind)`
    ///      key and collide, and the sum is what NAV needs anyway. Skips unregistered reserves and respects
    ///      assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IProtocolDataProvider dp = IProtocolDataProvider(_toAddress(instance));
        // positionId is the instance Pool — one position per instance. The reserve is NOT in positionId; each
        // reserve's legs are distinguished by balanceAsset + positionKind (multi-leg convention).
        // Derived from the hook, and `pool` derived back out of it, so the emitted positionId and the one
        // `positionIds()` advertises cannot drift — while still resolving the Pool exactly once. Decoding our own
        // `abi.encode(address)` is the same assumption `positionLabels` already makes about this positionId.
        bytes memory pid = _instancePositionId(instance);
        address pool = abi.decode(pid, (address));

        // A borrow this adapter cannot report must never leave the account's supplies standing alone: the
        // position would count as pure credit and NAV be over-reported by the whole borrow. Checked across ALL
        // reserves and independently of `assetFilter` — a filtered view showing a supply while hiding an
        // unreportable borrow over-reports the same way. Under-reporting the whole instance is the safe
        // direction.
        if (_hasUnreportableDebt(dp, pool, account)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        IProtocolDataProvider.TokenData[] memory reserves = dp.getAllReservesTokens();
        // up to 2 legs per reserve: supply/collateral + one Borrow (variable + stable summed)
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](reserves.length * 2);
        uint256 count;

        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i].tokenAddress;
            if (assetFilter != address(0) && asset != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
            if (!found) continue;

            (uint256 aTokenBalance, uint256 stableDebt, uint256 variableDebt,,,,,, bool usageAsCollateral) =
                dp.getUserReserveData(asset, account);

            if (aTokenBalance > 0) {
                PositionKind kind = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                temp[count++] = _leg(assetInfo, aTokenBalance, false, pid, kind);
            }
            // Sum variable + legacy stable debt into a single Borrowed leg. Emitting them separately would
            // produce two rows with an identical reconciliation key (same pool positionId, same reserve
            // balanceAsset, same Borrowed kind), which is not univocal.
            uint256 totalDebt = variableDebt + stableDebt;
            if (totalDebt > 0) {
                temp[count++] = _leg(assetInfo, totalDebt, true, pid, PositionKind.Borrowed);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        IProtocolDataProvider.TokenData[] memory reserves =
            IProtocolDataProvider(_toAddress(instance)).getAllReservesTokens();
        assets = new address[](reserves.length);
        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market", <market id>]` — the leaf is the instance's on-chain market id
    ///      (e.g. "Aave Ethereum Market" vs "Aave V3 Lido Ethereum"), which distinguishes instances that share
    ///      the same protocolId. positionId is the instance Pool, so the label is per-instance, not per-reserve
    ///      (the reserve token lives in `balanceAsset`). Collapses to `["Market"]` if the market id is
    ///      unavailable; empty array for a malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        (address pool, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        return _labels("Market", _marketId(pool));
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3_LENDING;
    }

    /// @notice Resolves the instance's market id (for the display label) from its pool.
    /// @dev V3 Pool exposes `ADDRESSES_PROVIDER()`. Best-effort: returns "" if the pool/provider does not expose the
    ///      views, or answers them with anything unusable (label then drops the market leaf).
    ///
    ///      Both hops go through the shared hardened readers rather than `try`/`catch`, because `try`/`catch` covers
    ///      only one of the three ways these reads fail — a code-less target reverts at the `extcodesize` precheck
    ///      and undecodable returndata reverts in the decoder, both in THIS frame, past any `catch`. See
    ///      {StaticCallLib} and {LabelLib} for the guards. `safeAddr`'s masking is correct for `ap`: a garbage
    ///      provider address simply fails the next hop and the leaf drops, and `address(0)` carries no special
    ///      meaning here beyond "unreadable".
    function _marketId(address pool) internal view returns (string memory) {
        (, address ap) = StaticCallLib.safeAddr(
            pool, abi.encodeWithSelector(IAaveAddressesProviderSource.ADDRESSES_PROVIDER.selector)
        );
        if (ap == address(0)) return "";
        return LabelLib.readString(ap, IAavePoolAddressesProvider.getMarketId.selector, "");
    }

    /// @notice True iff the account borrows any reserve whose asset is NOT registered on the NAV, i.e. a debt
    ///         this adapter would silently drop.
    /// @dev Uses Aave's user-configuration bitmap: one call identifies exactly which reserves the account
    ///      borrows, so the registry check touches only those. Scanning every reserve's `getUserReserveData`
    ///      instead would cost one call per reserve (67 on mainnet today) on every read, including the
    ///      single-asset filtered path. Falls back to that scan only if the bitmap is unavailable (an older
    ///      pool, or a fork that does not implement it).
    function _hasUnreportableDebt(IProtocolDataProvider dp, address pool, address account) private view returns (bool) {
        // `try` does NOT catch Solidity's "call to non-contract address" check — it runs in this frame, so a
        // code-less pool would revert the whole read rather than fall back. Check explicitly first.
        if (pool.code.length == 0) return _hasUnreportableDebtByScan(dp, account);

        // Low-level, not `try`: `try` catches neither the non-contract check (pre-empted above) NOR a
        // return-data decode failure, so a pool answering this selector with fewer than 32 bytes would escape
        // the `catch` and revert the read instead of falling back to the scan.
        (bool cfgOk, bytes memory cfgRet) =
            pool.staticcall(abi.encodeWithSelector(IAavePool.getUserConfiguration.selector, account));
        if (!cfgOk || cfgRet.length < 32) return _hasUnreportableDebtByScan(dp, account);
        uint256 cfgData = abi.decode(cfgRet, (uint256));
        if (cfgData == 0) return false; // no supplies and no borrows

        // Iterate the bitmap's own key space (2 bits per reserve => 128 reserves) and resolve each BORROWED
        // reserve by its stored id. Indexing `getReservesList()` positionally would be wrong: that accessor
        // compacts out dropped reserves, so after any `dropReserve` list[i] is a different reserve than id i —
        // the guard would check the wrong asset, and ids past the compacted length would never be examined.
        // The id lookup is a low-level staticcall, NOT inside the `try` above: a revert raised in a `try`'s
        // success block is not caught by its own `catch`, so a pool answering `getUserConfiguration` but not
        // `getReserveAddressById` would revert the read instead of falling back.
        for (uint256 id = 0; id < MAX_RESERVES; id++) {
            if (cfgData & (1 << (id * 2)) == 0) continue; // not borrowing reserve `id`
            (bool ok, bytes memory ret) =
                pool.staticcall(abi.encodeWithSelector(IAavePool.getReserveAddressById.selector, uint16(id)));
            if (!ok || ret.length < 32) return _hasUnreportableDebtByScan(dp, account);
            // Mask rather than `abi.decode(ret, (address))`: that reverts on a word with dirty upper bits,
            // and a revert here would escape the fallback this branch exists to reach.
            address asset = address(uint160(abi.decode(ret, (uint256))));
            if (asset == address(0)) continue; // dropped reserve
            (, bool found) = _getAssetInfo(asset);
            if (found) continue; // reportable
            // The bit alone is not proof of debt: Aave clears it only on an exact-full repay
            // (`BorrowLogic.executeRepay`: `stableDebt + variableDebt - paybackAmount == 0`, unscaled), while
            // the debt token burns scaled with rounding — so a bit can outlive the debt. Suppressing on a
            // stale bit would erase the whole instance from NAV permanently, and would disagree with
            // `_hasUnreportableDebtByScan`, which requires debt > 0. Confirm before suppressing.
            (, uint256 stableDebt, uint256 variableDebt,,,,,,) = dp.getUserReserveData(asset, account);
            if (stableDebt + variableDebt > 0) return true;
        }
        return false;
    }

    /// @notice Fallback for a pool without the configuration bitmap: check every unregistered reserve for debt.
    function _hasUnreportableDebtByScan(IProtocolDataProvider dp, address account) private view returns (bool) {
        IProtocolDataProvider.TokenData[] memory reserves = dp.getAllReservesTokens();
        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i].tokenAddress;
            (, bool found) = _getAssetInfo(asset);
            if (found) continue; // reportable, so it cannot be silently dropped
            (, uint256 stableDebt, uint256 variableDebt,,,,,,) = dp.getUserReserveData(asset, account);
            if (stableDebt + variableDebt > 0) return true;
        }
        return false;
    }

    function _poolOf(IProtocolDataProvider dp) internal view returns (address) {
        return IAavePoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER()).getPool();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev **Aave V3 is the one meta-adapter whose positionId is not its instance coordinate.** The coordinate is
    ///      a `ProtocolDataProvider`; the emitted positionId is the `Pool` resolved from it via
    ///      `ADDRESSES_PROVIDER().getPool()`. The base default would return `abi.encode(dataProvider)`, so
    ///      `positionIds()` would advertise ids that no `PositionBalance` ever carries.
    ///
    ///      **The defect this prevents is a broken reconciliation, not a wrong label.** Measured against the
    ///      deployed adapter on mainnet, `positionLabels(dataProvider)` and `positionLabels(pool)` BOTH return
    ///      `["Market", "Aave Ethereum Market"]` — `_marketId` reads `ADDRESSES_PROVIDER()`, which a
    ///      ProtocolDataProvider also exposes and which points at the same provider, so the label happens to come
    ///      out right either way. What breaks is identity: a configuration view could not JOIN its enumerated
    ///      rows against real `PositionBalance.positionId` values, and would do so silently, because the labels
    ///      would look correct on both sides.
    function _instancePositionId(bytes32 instance) internal view override returns (bytes memory) {
        return abi.encode(_poolOf(IProtocolDataProvider(_toAddress(instance))));
    }
}
