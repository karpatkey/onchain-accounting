// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
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

    /// @notice Longest market id accepted as a label leaf; anything longer degrades to "" (the label then drops
    ///         the leaf and renders as just `["Market"]`). Far above any real Aave market id.
    /// @dev Currently IMPLIED by {MAX_RETURN_BYTES} rather than independently enforced: past the size check below,
    ///      `size <= MAX_RETURN_BYTES`, and `len <= size - 64` then forces `len <= 256` on its own — so the
    ///      `len > MAX_LABEL_BYTES` clause cannot fire today. It is kept because the two constants express one
    ///      invariant, `MAX_RETURN_BYTES == 64 + MAX_LABEL_BYTES`, and they must move together: that equality is
    ///      also what guarantees there is no off-by-one rejecting a *valid* maximum-length label (a canonical
    ///      256-byte string encodes to exactly 320 bytes). Raise one without the other and the clause stops being
    ///      redundant — which is precisely when you want it already there.
    uint256 private constant MAX_LABEL_BYTES = 256;

    /// @notice Hard ceiling on returndata **copied into this contract's memory** for a label probe: the two ABI head
    ///         words plus {MAX_LABEL_BYTES} of payload (64 + 256 = 320). Written as a literal because inline assembly
    ///         accepts only direct number constants.
    /// @dev This, not the gas stipend, is what bounds the *caller's* cost. A stipend alone does not: a hostile
    ///      provider can `return(0, 200_000)` — its own memory expansion for ~200 KB costs it well under
    ///      {LABEL_READ_GAS} — while this contract pays `returndatacopy` plus its own monotonically growing memory,
    ///      charged outside the stipend and quadratic in total. Passing an explicit output size to `staticcall` copies
    ///      at most this many bytes whatever the callee returns, so the cost is flat. `returndatasize()` still reports
    ///      the true size, so an oversized reply is rejected rather than silently truncated.
    uint256 private constant MAX_RETURN_BYTES = 320;

    /// @notice Gas stipend for a label probe. Generous for a real (even proxied) metadata read, and it bounds the
    ///         callee's own execution — including a write-protection abort, which consumes everything forwarded.
    /// @dev Necessary but NOT sufficient on its own; see {MAX_RETURN_BYTES} for the caller-side bound.
    uint256 private constant LABEL_READ_GAS = 100_000;

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
        address pool = _poolOf(dp);
        // positionId is the instance Pool — one position per instance. The reserve is NOT in positionId; each
        // reserve's legs are distinguished by balanceAsset + positionKind (multi-leg convention).
        // Routed through the hook (not re-derived inline) so `positionIds()` advertises these exact bytes.
        bytes memory pid = _instancePositionId(instance);

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
    ///      unavailable; empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address pool = abi.decode(pid, (address));
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
    ///      views, or answers them with anything unusable (label then drops the market leaf). Both hops go through the
    ///      raw-call readers below rather than `try`/`catch`, because `try`/`catch` does not cover every way these
    ///      reads fail — see {_safeAddressRead} / {_safeStringRead}.
    function _marketId(address pool) internal view returns (string memory) {
        address ap = _safeAddressRead(pool, IAaveAddressesProviderSource.ADDRESSES_PROVIDER.selector);
        if (ap == address(0)) return "";
        return _safeStringRead(ap, IAavePoolAddressesProvider.getMarketId.selector);
    }

    /// @notice Fail-open read of a parameterless, `address`-returning view. `address(0)` on every failure path.
    /// @dev `positionLabels` is display-only and MUST NOT revert, and a `try`/`catch` around this call would not
    ///      make that true. Three distinct failure classes, only one of which `catch` handles:
    ///        1. `target` has **no code** — a high-level call reverts via Solidity's `extcodesize` precheck *before*
    ///           the call, in this frame, so `catch` never sees it;
    ///        2. the call **reverts** — the one class `catch` does cover;
    ///        3. the call **succeeds but the returndata is not decodable as an `address`** — fewer than 32 bytes, or
    ///           32 bytes with dirty upper bits. Solidity's decoder runs in THIS frame after the call returned, so
    ///           its revert propagates straight past `catch`.
    ///      A raw `staticcall` turns class 2 into a `false` return; the codesize guard covers class 1; the explicit
    ///      `returndatasize()` check plus a `uint160` mask (rather than `abi.decode(…, (address))`, which validates
    ///      the upper bits and reverts) covers class 3. Output is written into scratch space with an explicit size, so
    ///      nothing is copied beyond one word however much the callee returns.
    function _safeAddressRead(address target, bytes4 selector) private view returns (address) {
        if (target.code.length == 0) return address(0);
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            // Scratch space (0x00–0x3f): selector in the first word, the single return word in the second.
            // `bytes4` is left-aligned, so the 4 bytes at 0x00 are exactly the selector.
            mstore(0x00, selector)
            ok := staticcall(LABEL_READ_GAS, target, 0x00, 0x04, 0x20, 0x20)
            size := returndatasize()
            word := mload(0x20)
        }
        if (!ok || size < 32) return address(0);
        return address(uint160(word));
    }

    /// @notice Fail-open read of a parameterless, `string`-returning view. "" on every failure path.
    /// @dev Same three classes as {_safeAddressRead}; class 3 is the one a `try`/`catch` silently misses, and the
    ///      shapes are not hypothetical — all reproduced on solc 0.8.34: empty returndata (an ERC-1967 proxy whose
    ///      implementation slot points at a code-less address, so the `delegatecall` succeeds returning nothing), a
    ///      `bytes32` market id (MKR-era style), a bare offset word with no length word, a nonsense offset, and an
    ///      absurd declared length.
    ///
    ///      So the ABI head is validated *before* decoding. A canonical `string` return is
    ///      `[offset = 0x20][length][payload…]`: require two full words, an offset of exactly `0x20`, a non-zero
    ///      length within {MAX_LABEL_BYTES}, and a payload that fits inside the returndata. Bounding on the raw
    ///      declared length is sufficient — a memory-source `abi.decode` bounds on that length, not on `ceil32` of it.
    ///
    ///      The probe is gas-capped and output-capped, and both are load-bearing rather than defensive: a raw
    ///      `staticcall` assigning `(bool, bytes memory)` always `returndatacopy`s the response *including a revert
    ///      payload*, which the parameterless `catch {}` this replaced never did. Uncapped, this rewrite would be
    ///      strictly worse than the old `try`/`catch` against a hostile provider. See {MAX_RETURN_BYTES}.
    function _safeStringRead(address target, bytes4 selector) private view returns (string memory) {
        if (target.code.length == 0) return "";

        bytes memory data = new bytes(MAX_RETURN_BYTES);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            ok := staticcall(LABEL_READ_GAS, target, 0x00, 0x04, add(data, 0x20), MAX_RETURN_BYTES)
            size := returndatasize()
        }
        // A `string` return needs at least the offset and length words. An oversized reply is rejected outright rather
        // than truncated: a canonical reply for a <= MAX_LABEL_BYTES string never exceeds MAX_RETURN_BYTES, so
        // anything larger is malformed or hostile.
        if (!ok || size < 64 || size > MAX_RETURN_BYTES) return "";

        // Shrink to what was actually returned so the payload bound below — and `abi.decode`'s own bounds check — are
        // exact. Only ever shrinks: `size <= MAX_RETURN_BYTES` is the allocated length.
        assembly ("memory-safe") {
            mstore(data, size)
        }

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        if (offset != 0x20 || len == 0 || len > MAX_LABEL_BYTES || len > size - 64) return "";

        return abi.decode(data, (string));
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
