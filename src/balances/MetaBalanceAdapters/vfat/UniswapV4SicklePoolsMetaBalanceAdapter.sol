// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

import {SickleHeldPositions} from "src/balances/MetaBalanceAdapters/vfat/SickleHeldPositions.sol";
import {IExtsload, IV4PositionManager, PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {V4PositionIndex} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4PositionIndex.sol";
import {V4StateLibrary} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4StateLibrary.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";

/// @title Uniswap V4 Sickle Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable meta-adapter that reports an account's Uniswap V4 LP across every configured pool — the
///         in-range liquidity (`Supplied`) and the full unclaimed fees (`Fees`) of each position NFT held, **including
///         the ones held through the account's vfat Sickle**. The instance coordinate is the V4 `bytes32` pool id; the
///         active pool set is governed on NAVCalculator (`addMetaInstances`/`removeMetaInstances`, MANAGER-gated).
///         The PositionManager, the PoolManager singleton and the {V4PositionIndex} are chain-level constants pinned
///         in the constructor.
///
/// @dev **INSTANCE COORDINATE.** The V3 sibling widens a pool ADDRESS into bytes32; V4 has no per-pool contract at
///      all (one PoolManager singleton holds every pool's state), so the instance IS the `bytes32` pool id, used raw.
///      Consequently `positionId = abi.encode(bytes32 poolId)` and {_instancePositionId} is overridden — the base's
///      default `abi.encode(_toAddress(instance))` would reject every real coordinate here, since a pool id has dirty
///      upper bits by construction. The position NFT id rides in the typed `positionInstanceId`, exactly as in V3.
///
/// @dev **DISCOVERY vs AUTHORITY.** V4's PositionManager is Solmate ERC721 with no enumeration extension, so there is
///      no `tokenOfOwnerByIndex` to walk (measured on 4663: it reverts). {V4PositionIndex} answers "which tokenIds
///      might this holder have", which chain state cannot. It is a HINT and is treated as one: every id it returns is
///      re-checked here against `POSITION_MANAGER.ownerOf(tokenId)` AND against the pool id re-derived from the
///      position's own PoolKey, before a single wei is valued. A stale entry left by a rebalance and a deliberately
///      poisoned one are the same thing to this adapter — skipped. The index can therefore never inflate the NAV,
///      only fail to grow it, and that failure mode is observable through {coverage}.
///
/// @dev **NEVER REVERTING ON INCOMPLETENESS.** `PriceFeedLib._getAdapterPositions` reads an adapter revert as
///      "nothing to report". An adapter that reverted to signal "my index is behind" would therefore price the whole
///      portfolio at ZERO — strictly worse than under-reporting one pool. Incompleteness is consequently surfaced as
///      data, via {coverage}, for the operator to assert on offchain.
///
/// @dev **Both pool currencies must be registered in NAVCalculator** or the position is dropped whole — NAV values an
///      LP from the sum of its two legs, so a half-priced LP would silently understate it. This is the same rule as
///      `UniswapV3PoolsMetaBalanceAdapter`'s, applied per position rather than per instance for the one reason it has
///      to be: a V4 pool id is a one-way hash, so the currencies are not knowable until a position in that pool has
///      been read. `assetFilter` only gates which of the two legs are emitted.
///
/// @dev **FEES AND THE PROTOCOL FEE.** Uncollected fees are `feeGrowthInside - feeGrowthInsideLast` times the
///      position's liquidity over Q128, exactly as in V3 — V4 just keeps the position's last-seen growth in the
///      PoolManager's position state instead of in the NFT manager. The V4 protocol fee is a SURCHARGE taken off the
///      swap input BEFORE `lpFee` applies to the remainder, not a cut of LP fees: META-USDG on 4663 has `lpFee` 3000
///      and `protocolFee` 500/500 (**measured**), i.e. swappers pay 0.05% + 0.3%·(1 − 0.05%) = 34.99 bp of which LPs
///      receive 29.99 bp. LP fee growth is already net of it. There is nothing to subtract here, and subtracting
///      anything would under-report. (The sibling `FablesSickleRangesMetaBalanceAdapter` DOES subtract, because the
///      Fables hook takes its cut at accrual; the two are not inconsistent, they are different venues.)
///
/// @dev **NATIVE ETHER.** V4 trades native ether directly, as `Currency` zero — there is no WETH in the PoolKey of a
///      native pool, `currency0` IS `address(0)`. The NAV cannot hold that: `registerAsset(address(0), …)` reverts
///      `InvalidArguments()`, because the NAV represents native ether by the ERC-7528 sentinel
///      `0xEeee…eEeE` (`Balances.NATIVE_ADDRESS`), which IS registered and priced. An adapter emitting the raw zero
///      address would hand the NAV a leg it cannot price — and since `PriceFeedLib` DROPS an unpriceable leg instead
///      of reverting, the position's entire native side vanishes from `getAccountNav` with no revert, no stale flag
///      and no entry in `stalePriceAssets`. **That is not hypothetical: it shipped.** On 4663 (PR #10, discovered
///      14 Sep 2026, fixed 16 Sep, verified on chain 17 Sep) the unmapped zero made the native side of one position
///      disappear — `getAdapterPositions` returned 24 rows, `getAccountPositions` 22, the two missing being the ETH
///      principal and ETH fees of tokenId 2475032, worth **about 1,660 USDG** (**measured** 14 Sep 2026; note the
///      source repo records this figure inconsistently across its own pages, as 1,846 / 1,710 / 1,660 — 1,660 is the
///      value in `experiments/2026-09-11-first-deployment.md`). Every currency read out of a PoolKey is consequently
///      mapped through {_asNavAsset} before it is stored or emitted.
///
/// @dev Valuation = instantaneous on-chain amounts (docs/decisions/0017-lp-valuation-instantaneous-amounts.md): the
///      in-range split is computed from the pool's live `slot0.sqrtPriceX96`/`tick` read via `extsload` and the
///      position's liquidity; fees are the full unclaimed amount. NAVCalculator prices the reported amounts with
///      external oracles.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts, FixedPoint128) — combined
///      work is GPL-2.0-or-later (docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md).
contract UniswapV4SicklePoolsMetaBalanceAdapter is MetaBalanceAdapter, SickleHeldPositions {
    using V4StateLibrary for IExtsload;

    /// @notice Bounded iteration limit for per-holder position discovery, matching
    ///         `UniswapV3PoolsMetaBalanceAdapter.MAX_POSITIONS`.
    /// @dev **Why it is needed here even though the enumeration source is an index rather than the chain.**
    ///      {V4PositionIndex.index} is permissionless and unbounded by design (see that contract for why opening it
    ///      is the safe choice), so the number of ids this loop walks is attacker-growable: anyone can file junk ids
    ///      against a tracked holder for the cost of the write. Each one then costs an `ownerOf` staticcall per
    ///      configured instance. On 4663 that was estimated at roughly 330k gas per junk id against a 10.0M read and
    ///      a ~32M per-tx ceiling (**simulated**, 2 Oct 2026), i.e. ~100 junk ids stop a settlement. The cap bounds
    ///      that: the worst case degrades from a NAV-read DoS into a bounded **under-report**, the direction this
    ///      family always fails in. For any real holding the cap is a no-op — the largest live book on 4663 is 8
    ///      positions behind 20 filed ids (**measured**, block 90,186,157).
    /// @dev **This is a deliberate addition to the 4663 original, which had no cap.** There it was the known-open
    ///      half of the finding above; the V3 sibling in this repo already carries the same guard with the same
    ///      number, and an uncapped loop is not something to re-introduce.
    uint256 public constant MAX_POSITIONS = 1000;

    /// @notice Uniswap V4 PositionManager — the ownership authority and the source of every PoolKey.
    IV4PositionManager public immutable POSITION_MANAGER;

    /// @notice The PoolManager singleton holding every pool's state, read via `extsload`.
    IExtsload public immutable POOL_MANAGER;

    /// @notice Permissionless holder -> tokenId discovery index. A hint; see the contract note.
    V4PositionIndex public immutable POSITION_INDEX;

    /// @notice ERC-7528 convention for ETH address representation
    /// @dev This is the identifier the NAV knows native ether by: the same literal `Balances.NATIVE_ADDRESS`
    ///      declares and registers for the chain's native token, mirrored here exactly as
    ///      `ERC20DefaultBalanceAdapter.NATIVE_ADDRESS` mirrors it. Every V4 `Currency` of `address(0)` is mapped
    ///      onto it by {_asNavAsset} before it is stored or emitted, for the reason in the contract note.
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @dev poolId -> the pool's two currencies, learned from a self-validating PoolKey preimage. `[1] == address(0)`
    ///      means "no key submitted for this pool" and is used as that marker throughout; see {_asNavAsset} for why
    ///      slot 1 can never legitimately be zero.
    mapping(bytes32 => address[2]) private _poolCurrencies;

    /// @notice A tokenId handed to {learnPoolKeys} does not resolve to a usable PoolKey.
    error UnknownPosition(uint256 tokenId);

    event PoolKeyRegistered(bytes32 indexed poolId, address currency0, address currency1);

    /// @param positionManager_ The Uniswap V4 PositionManager for this chain. Must be a contract.
    /// @param poolManager_     The Uniswap V4 PoolManager singleton for this chain. Must be a contract.
    /// @param positionIndex_   The {V4PositionIndex} deployed against `positionManager_`. Must be a contract.
    /// @param navCalculator_   The NAVCalculator contract for asset-registry access. Must be a contract.
    /// @param sickleFactory_   vfat SickleFactory for this chain. Must be a contract.
    constructor(
        address positionManager_,
        address poolManager_,
        address positionIndex_,
        address navCalculator_,
        address sickleFactory_
    ) MetaBalanceAdapter(navCalculator_) SickleHeldPositions(sickleFactory_) {
        AddressCheckLib.requireContract(positionManager_, "PositionManager");
        AddressCheckLib.requireContract(poolManager_, "PoolManager");
        AddressCheckLib.requireContract(positionIndex_, "V4PositionIndex");
        POSITION_MANAGER = IV4PositionManager(positionManager_);
        POOL_MANAGER = IExtsload(poolManager_);
        POSITION_INDEX = V4PositionIndex(positionIndex_);
    }

    //
    // Identity hooks
    //

    /// @notice Broadest brand grouping — the same brand the V2/V3 adapters report.
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP;
    }

    /// @notice Ecosystem/version id. V4 is one product, so the ecosystem and sub slugs match (as they do for V3).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP_V4;
    }

    /// @notice Per-product slug; selects the positionId decode schema, which here is a raw `bytes32` pool id.
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP_V4;
    }

    //
    // Meta hooks
    //

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Resolved explicitly to {SickleHeldPositions}: both parents declare this hook, {MetaBalanceAdapter} as the
    ///      abstract fan-out point and {SickleHeldPositions} as the two-holder implementation of it, and the whole
    ///      point of this adapter is that the second one wins. The concrete per-venue read lives in
    ///      {_holderPositions}, which the mixin calls once for the account and once for its Sickle.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override(MetaBalanceAdapter, SickleHeldPositions)
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return SickleHeldPositions._instancePositions(account, instance, assetFilter);
    }

    /// @inheritdoc SickleHeldPositions
    /// @dev `instance` is the V4 pool id. Walks the holder's filed ids (capped at {MAX_POSITIONS}), keeps the ones
    ///      the PositionManager still attributes to `holder` whose PoolKey hashes to this instance, and emits up to
    ///      4 legs per position: `Supplied` x2 (in-range split) + `Fees` x2 (full unclaimed) — dropping zeros,
    ///      honouring `assetFilter`, and dropping any position whose currencies are not both registered.
    function _holderPositions(address holder, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        uint256[] memory ids = POSITION_INDEX.indexedTokenIds(holder);
        uint256 max = ids.length > MAX_POSITIONS ? MAX_POSITIONS : ids.length;
        if (max == 0) return new INAVCalculator.PositionBalance[](0);

        bytes memory positionId = _instancePositionId(instance);
        // Up to 4 legs per position (liq0, liq1, fee0, fee1).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](max * 4);
        uint256 count;

        // The registry/filter gate is resolved once, from the first position that matches. Every matched position in
        // this instance provably shares one PoolKey — matching IS `keccak256(abi.encode(key)) == instance` — so its
        // currencies, their registry records and the filter decision are identical for all of them, and repeating the
        // two `getRegisteredAsset` calls per position would be pure waste.
        bool gateResolved;
        INAVCalculator.Asset memory a0;
        INAVCalculator.Asset memory a1;
        bool emit0;
        bool emit1;

        for (uint256 i; i < max; ++i) {
            Legs memory legs = _legs(holder, instance, ids[i]);
            if (!legs.matched) continue;

            if (!gateResolved) {
                gateResolved = true;
                bool reg0;
                bool reg1;
                (a0, reg0) = _getAssetInfo(legs.currency0);
                (a1, reg1) = _getAssetInfo(legs.currency1);
                // Both currencies or nothing: valuing the LP split needs both oracle prices.
                if (reg0 && reg1) {
                    emit0 = assetFilter == address(0) || assetFilter == legs.currency0;
                    emit1 = assetFilter == address(0) || assetFilter == legs.currency1;
                }
            }
            if (!emit0 && !emit1) return new INAVCalculator.PositionBalance[](0);

            bytes32 instanceId = bytes32(ids[i]);
            if (emit0 && legs.amount0 != 0) {
                temp[count++] = _row(a0, legs.amount0, positionId, PositionKind.Supplied, instanceId);
            }
            if (emit1 && legs.amount1 != 0) {
                temp[count++] = _row(a1, legs.amount1, positionId, PositionKind.Supplied, instanceId);
            }
            if (emit0 && legs.fees0 != 0) {
                temp[count++] = _row(a0, legs.fees0, positionId, PositionKind.Fees, instanceId);
            }
            if (emit1 && legs.fees1 != 0) {
                temp[count++] = _row(a1, legs.fees1, positionId, PositionKind.Fees, instanceId);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Only pools whose PoolKey preimage has been submitted to {registerPoolKeys} can be named, because a V4
    ///      pool id is a one-way hash and the PoolManager has no `poolKey(poolId)` getter. Returning a short list —
    ///      or an empty one — is explicitly sanctioned by `IBalanceAdapter`, and nothing on the NAV pricing path
    ///      depends on this method: the valuation reads each PoolKey straight off the position.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address[2] memory pair = _poolCurrencies[instance];
        if (pair[1] == address(0)) return new address[](0);
        assets = new address[](2);
        assets[0] = pair[0];
        assets[1] = pair[1];
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev **Mandatory override, not a convenience.** The coordinate is a raw `bytes32` pool id, so the base default
    ///      `abi.encode(_toAddress(instance))` would revert on every real coordinate, and even where it did not it
    ///      would advertise ids no position ever carries — silently breaking {IPositionEnumerable}'s byte-identity
    ///      guarantee. positionId = `abi.encode(bytes32 poolId)`; it is the same bytes {_holderPositions} stamps on
    ///      every leg.
    function _instancePositionId(bytes32 instance) internal pure override returns (bytes memory) {
        return abi.encode(instance);
    }

    //
    // Completeness gate
    //

    /// @notice How much of what `holder` actually holds this adapter can currently see.
    /// @dev The completeness gate, and the whole reason the index can be left permissionless. `indexedLive <
    ///      heldTotal` means the index is behind — positions were minted (a rebalance) and nobody has called
    ///      {V4PositionIndex.index} for them yet, so those positions are missing from the NAV. This is deliberately a
    ///      VIEW and not a revert: see the contract note on the NAV failing open. On 4663 the operator asserts
    ///      equality after every deploy and every rebalance, because the one time that assertion was missing — 17 to
    ///      20 Sep 2026 — an unindexed tokenId hid 29.5% of a fund from its share price for three days (**measured**).
    /// @param holder The address holding the NFTs — for a deployed portfolio, the Sickle, not the Safe. This does NOT
    ///        walk the Sickle indirection; pass {SickleHeldPositions.sickleOf}'s result to ask about the Sickle.
    /// @return indexedLive Filed ids that `holder` still owns.
    /// @return heldTotal `POSITION_MANAGER.balanceOf(holder)` — every V4 position NFT it holds, indexed or not.
    function coverage(address holder) external view returns (uint256 indexedLive, uint256 heldTotal) {
        indexedLive = POSITION_INDEX.liveCount(holder);
        heldTotal = POSITION_MANAGER.balanceOf(holder);
    }

    //
    // PoolKey preimages (descriptive only)
    //

    /// @notice Record a pool's currencies from its PoolKey preimage.
    /// @dev Permissionless and self-validating: the key is only accepted under the pool id it hashes to, and a
    ///      preimage of a keccak256 cannot be forged, so there is nothing here to gate and no admin to be a
    ///      bottleneck. It exists because V4 pool ids are one-way and {_instanceAssets} / {positionLabels} have to
    ///      name the assets behind the governed instance set. **Purely descriptive: {_holderPositions} never consults
    ///      this map**, it reads the PoolKey straight off the position, so an unregistered pool is still valued in
    ///      full. Entries are write-once; a second submission of an already-known pool is a no-op.
    function registerPoolKeys(PoolKey[] calldata keys) external {
        uint256 n = keys.length;
        for (uint256 i; i < n; ++i) {
            // The id is derived from the RAW key — it is a preimage of the pool id — and only the STORED currency is
            // normalised.
            _record(keccak256(abi.encode(keys[i])), keys[i].currency0, keys[i].currency1);
        }
    }

    /// @notice Same as {registerPoolKeys}, sourcing the keys from live positions instead of from calldata.
    /// @dev Convenience for an operator who has tokenIds but not the keys typed out. Reverts on a tokenId whose key
    ///      is unusable, so a caller who got the list wrong finds out.
    function learnPoolKeys(uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenIds[i]);
            if (key.currency1 == address(0)) revert UnknownPosition(tokenIds[i]);
            _record(keccak256(abi.encode(key)), key.currency0, key.currency1);
        }
    }

    /// @notice The currencies recorded for `poolId`, or `(0, 0)` if no PoolKey preimage has been submitted.
    function poolCurrencies(bytes32 poolId) external view returns (address currency0, address currency1) {
        return (_poolCurrencies[poolId][0], _poolCurrencies[poolId][1]);
    }

    /// @dev Write-once storage of one validated key. `currency0` is normalised; `currency1` is not, because
    ///      `currency1 == address(0)` is this map's "no such pool" marker (see {_asNavAsset}).
    function _record(bytes32 poolId, address rawCurrency0, address currency1) private {
        if (_poolCurrencies[poolId][1] != address(0)) return;
        address currency0 = _asNavAsset(rawCurrency0);
        _poolCurrencies[poolId] = [currency0, currency1];
        emit PoolKeyRegistered(poolId, currency0, currency1);
    }

    //
    // Valuation
    //

    /// @notice One position's four candidate legs, plus whether it belongs to the instance being queried.
    /// @dev A struct in its own frame rather than eight locals threaded through the fan-out loop; it also keeps the
    ///      authority checks and the maths in one place that can be read top to bottom.
    struct Legs {
        bool matched;
        address currency0;
        address currency1;
        uint256 amount0;
        uint256 amount1;
        uint256 fees0;
        uint256 fees1;
    }

    /// @dev Values ONE position, and only if the PositionManager says `holder` owns it right now AND its pool id,
    ///      re-derived from its own PoolKey, is exactly `instance`. Both checks are the reason the index can be left
    ///      open: a poisoned or stale entry fails one of them and contributes nothing.
    function _legs(address holder, bytes32 instance, uint256 tokenId) private view returns (Legs memory legs) {
        // THE AUTHORITY CHECK. Nothing past this line runs for a position the PositionManager does not currently
        // attribute to `holder`.
        if (_ownerOf(tokenId) != holder) return legs;

        (PoolKey memory key, uint256 info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        if (keccak256(abi.encode(key)) != instance) return legs;

        (int24 tickLower, int24 tickUpper) = _ticks(info);
        V4StateLibrary.Snapshot memory s =
            POOL_MANAGER.snapshot(instance, address(POSITION_MANAGER), tickLower, tickUpper, bytes32(tokenId));

        (legs.amount0, legs.amount1) = LiquidityAmounts.getAmountsForLiquidity(
            s.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            POSITION_MANAGER.getPositionLiquidity(tokenId)
        );

        unchecked {
            legs.fees0 = _feeAmount(s.feeGrowthInside0X128 - s.feeGrowthInside0LastX128, s.liquidity);
            legs.fees1 = _feeAmount(s.feeGrowthInside1X128 - s.feeGrowthInside1LastX128, s.liquidity);
        }

        legs.matched = true;
        legs.currency0 = _asNavAsset(key.currency0);
        legs.currency1 = key.currency1;
    }

    /// @dev `PositionInfo` packing: bit 0 `hasSubscriber`, bits 8..31 `tickLower`, bits 32..55 `tickUpper`, bits 56..
    ///      the truncated pool id. Both ticks are int24 two's complement, so the cast through `uint24` before `int24`
    ///      is what restores the sign. Verified on 4663 tokenId 2268430: (211380, 211800), both multiples of the
    ///      pool's tickSpacing 60 (**measured**).
    function _ticks(uint256 info) private pure returns (int24 tickLower, int24 tickUpper) {
        // Casting is safe because these ARE the packed fields: `PositionInfo` stores each tick as an int24 at a known
        // offset, and the uint24 hop is what carries the sign bit through.
        // forge-lint: disable-next-line(unsafe-typecast)
        tickLower = int24(uint24(info >> 8));
        // forge-lint: disable-next-line(unsafe-typecast)
        tickUpper = int24(uint24(info >> 32));
    }

    /// @dev Fee legs must never be able to revert this read: a revert here is read by the NAV as "no positions",
    ///      which is a zero NAV. A fee-growth delta large enough to overflow the multiplication is not reachable from
    ///      real pool state (it would mean fees on the order of 1e38 raw tokens), so declining to report such a leg
    ///      costs nothing real and removes the revert that `Math.mulDiv` would otherwise raise.
    function _feeAmount(uint256 growthDelta, uint128 liquidity) private pure returns (uint256) {
        if (growthDelta == 0 || liquidity == 0) return 0;
        if (growthDelta > type(uint256).max / liquidity) return 0;
        return Math.mulDiv(growthDelta, liquidity, FixedPoint128.Q128);
    }

    /// @dev Maps a PoolKey currency onto the identifier the NAV actually knows. Only `currency0` can ever be native:
    ///      V4 requires `currency0 < currency1` and native ether is `Currency` zero, so it sorts first in every pool
    ///      that trades it. `currency1 == address(0)` therefore does not mean "native" anywhere in this contract — it
    ///      means "no such pool", which is exactly how {learnPoolKeys}, {_record} and {_instanceAssets} read it, and
    ///      normalising it would destroy that marker.
    function _asNavAsset(address currency) private pure returns (address) {
        return currency == address(0) ? NATIVE_ADDRESS : currency;
    }

    /// @dev `ownerOf` reverts for a burned tokenId — the residue of every rebalance — which is expected traffic here
    ///      rather than an error, so the revert is absorbed and read as `address(0)`. One SLOAD behind one
    ///      staticcall, so no nested out-of-gas can hide inside the absorbed revert. A dirty word is rejected rather
    ///      than masked: it is a broken answer, not an owner.
    function _ownerOf(uint256 tokenId) private view returns (address) {
        (bool ok, address owner, bool malformed) = StaticCallLib.safeAddrStrict(
            address(POSITION_MANAGER), abi.encodeCall(IV4PositionManager.ownerOf, (tokenId))
        );
        return (ok && !malformed) ? owner : address(0);
    }

    //
    // Display
    //

    /// @inheritdoc IPositionDescribable
    /// @dev `["AMM Liquidity Pool", "<sym0>/<sym1>"]` (e.g. `["AMM Liquidity Pool", "ETH/USDG"]`). Unlike the V3
    ///      sibling there is no `<fee>%` segment and the leaf is not read from the coordinate: a V4 pool id is a
    ///      one-way hash, so the currencies come from the {registerPoolKeys} map and the leaf collapses to just the
    ///      category for a pool whose key has never been submitted. Symbols prefer the NAV's registered-asset record
    ///      — which is what resolves the native sentinel to the chain's native symbol, something no `symbol()` call
    ///      on `0xEeee…eEeE` ever could — and fall back to a live `symbol()` read with "?" for anything unreadable.
    ///      Empty for a malformed positionId (see {_pidWord}).
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory) {
        (bytes32 poolId, bool ok) = _pidWord(positionId);
        if (!ok) return new string[](0);
        address[2] memory pair = _poolCurrencies[poolId];
        string memory leaf = pair[1] == address(0) ? "" : string.concat(_symbolOf(pair[0]), "/", _symbolOf(pair[1]));
        return _labels("AMM Liquidity Pool", leaf);
    }

    /// @dev Registered symbol first, live `symbol()` second, "?" last. Fail-open throughout: `positionLabels` is a
    ///      display-only view and must not revert.
    function _symbolOf(address asset) private view returns (string memory) {
        (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(asset);
        if (found && bytes(info.symbol).length != 0) return info.symbol;
        return LabelLib.symbol(asset, "?");
    }

    /// @dev Builds a PositionBalance leg with the per-position `positionInstanceId`. The base `_leg` hardcodes
    ///      positionInstanceId to bytes32(0); V4 needs the NFT tokenId there, so the leg is built inline — identity
    ///      fields still come from the `_protocol*` hooks. Mirrors `UniswapV3PoolsMetaBalanceAdapter._row`.
    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bytes memory positionId,
        PositionKind kind,
        bytes32 positionInstanceId
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: _protocolBrand(),
            protocolId: _protocolId(),
            protocolSubId: _protocolSubId(),
            positionId: positionId,
            positionKind: kind,
            isLocked: false, // LP liquidity + unclaimed fees are always withdrawable
            positionInstanceId: positionInstanceId
        });
    }
}
