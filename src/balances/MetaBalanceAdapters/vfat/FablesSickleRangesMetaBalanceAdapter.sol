// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {SickleHeldPositions} from "src/balances/MetaBalanceAdapters/vfat/SickleHeldPositions.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IExtsload, PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {V4StateLibrary} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4StateLibrary.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {
    IFablesHook,
    FablesRangeState,
    FablesUserPosition
} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";
import {FablesRangeIndex} from "src/balances/MetaBalanceAdapters/fables/FablesRangeIndex.sol";

/// @title Fables Sickle Ranges Meta Balance Adapter
/// @author KPK
/// @notice Reports an account's Fables hook ranges — including the ones held through its vfat **Sickle** — one
///         NAV instance per Uniswap V4 pool id. Each range contributes up to six legs: the unstaked principal
///         (`Supplied`) and the staked principal (`Staking`), both split across the pool's two currencies, and
///         the claimable fees (`Fees`). The governed pool set lives on NAVCalculator
///         (`addMetaInstances`/`removeMetaInstances`, MANAGER-gated); the PoolManager singleton and the
///         discovery index are pinned in the constructor.
///
/// @dev **WHY FABLES IS ITS OWN BRAND AND NOT A UNISWAP V4 SUB-ID.** `ProtocolIds.FABLES` is not a courtesy
///      slug. The account holds an ERC-6909 share in a range the HOOK owns, never a Uniswap position, and the
///      fee split, the claim fee and the staking behaviour are the hook's own. Filing these rows under
///      `ProtocolIds.UNISWAP` would make a portfolio view claim Uniswap liquidity the account cannot touch.
///      So brand, id and sub-id all collapse to `FABLES` — see the constant's own note in `ProtocolIds.sol`.
///
/// @dev **WHY A SEPARATE ADAPTER FROM THE UNISWAP V4 ONE.** These adapters are immutable and are swapped by
///      governance as a unit. Teaching the Uniswap V4 adapter a second venue would mean replacing the
///      contract that values an entire book in order to add a venue that book may not yet hold. Separate
///      contract, separate `protocolId`, separate governed instance set.
///
/// @dev **THE INSTANCE IS THE POOL ID, NOT THE RANGE ID.** Both are available and the pool id is the right
///      one. Instances are added by `addMetaInstances`, which is MANAGER-gated; a per-range instance would put
///      every re-centre behind that key and make the NAV go quiet exactly when the book moves. A pool id is
///      stable across every re-centre within the pool, so the governed set is written once. Identity:
///      positionId = `abi.encode(bytes32 poolId)` and the hook's rangeId rides in the ephemeral
///      `positionInstanceId` as `bytes32(rangeId)` — the same shape the Uniswap V4 sibling uses for its NFT id.
///
/// @dev **A SHARE IS A UNIT OF LIQUIDITY.** `deposit` mints `liquidity` ERC-6909 shares and applies exactly
///      that much liquidity to the hook's own V4 position; `withdraw` burns and removes the same. There is no
///      share price and no dilution, so `balanceOf(holder, rangeId)` feeds `LiquidityAmounts` unscaled.
///      MEASURED, not read off the source: 1,915 live ranges across all seven deployed hooks, zero mismatches
///      against PoolManager's own position storage, chain 4663 block 71,453,253, 24 Sep 2026.
///
/// @dev **THE HOOK IS THE V4 POSITION OWNER, WITH SALT ZERO.** The hook's `LedgerLib._onModify` calls
///      `poolManager.modifyLiquidity(..., salt: bytes32(0))` from inside the hook's own unlock callback and is
///      an inlined internal library, so `address(this)` is the hook throughout. The V4 position key is
///      therefore `keccak256(hook, tickLower, tickUpper, bytes32(0))` — the same {V4StateLibrary.snapshot} the
///      Uniswap V4 adapter uses, with two arguments changed.
///
/// @dev **STAKED SHARES ARE PRINCIPAL AND ARE NOT FEE-BEARING.** Staking routes a share's ENTIRE fee accrual
///      to the Fables distributor and pays an offchain emission claim instead. The principal stays fully
///      withdrawable — `withdraw` auto-unstakes — so it IS valued, as `PositionKind.Staking` per that enum's
///      own rule that the kind reflects the outermost action family. Its fee accrual is NOT valued, because
///      booking it would record revenue the fund can never receive. "Count staked and unstaked balances alike"
///      is therefore right for principal and wrong for fees, and this contract splits the two.
///
///      MEASURED 24 Sep 2026, and deliberately NOT a reason to drop the staking path: zero `Staked` events
///      over 3,000,000 blocks on all seven hooks, with `totalStaked == 0` on all 1,915 ranges. Live code with
///      no users today is still live code; an adapter that omitted the branch would misvalue the first staker
///      silently, which is the failure mode this whole family is built to avoid.
///
/// @dev **FEES ARE ALREADY NET, TWICE OVER — A DELIBERATE DIVERGENCE FROM THE UNISWAP V4 ADAPTER.** Both the
///      staked cut and the claim fee are taken at ACCRUAL, in the hook's `LedgerLib._split`, at the rate in
///      force while the fees were earned; `claimFees` takes nothing further. So `UserPosition.owed0/owed1`
///      must be discounted by NOTHING — doing it again would under-report — while the not-yet-synced backlog
///      must have BOTH cuts applied, because they have not happened to it yet. {_backlog} is that arithmetic,
///      mirroring `_split` term for term, residual carry included. The Uniswap V4 adapter subtracts nothing at
///      all (V4's protocol fee is a surcharge on swap input, so LP fee growth is already net there too). The
///      two adapters therefore look inconsistent and are not; this paragraph exists so nobody deletes the
///      subtraction here or adds one there.
///
/// @dev **NEVER REVERTING.** `PriceFeedLib._getAdapterPositions` reads an adapter revert as "nothing to
///      report", so a reverting adapter prices the whole account at ZERO. Every read here that could fail is
///      either behind {MetaBalanceAdapter}'s per-instance isolation or absorbed locally, and every arithmetic
///      guard resolves to "report less", never to a revert.
///
/// @dev **NATIVE ETHER.** A Fables pool can be a NATIVE ether pool: the hook's ETH ramp overrides the ledger's
///      native refusal and the recovered PoolKey then has `currency0 == address(0)`. The NAV cannot hold the
///      raw zero address — it represents native ether by the ERC-7528 sentinel {NATIVE_ADDRESS} — and
///      `PriceFeedLib` DROPS an unpriceable leg silently rather than reverting, so an unmapped zero would make
///      the whole ETH side of a position vanish with no stale flag and no error. MEASURED on the Uniswap V4
///      sibling, 14 Sep 2026: exactly that bug dropped the ETH principal and ETH fee legs of a live position
///      from an account read that otherwise looked healthy. Every currency is mapped through {_asNavAsset} at
///      registration time.
///
/// @dev **A HOOK IS ONLY EVER CALLED IF A GOVERNED POOL NAMES IT (correction, 24 Sep 2026, review of PR #46).**
///      {FablesRangeIndex} is permissionless and takes any `hook` address. The first version of this adapter
///      called `hook.balanceOf` for every filed entry before checking anything, so a stranger could file an
///      entry under a contract that answers the index (and so can never be pruned) but reverts for this
///      adapter. The meta framework's per-instance isolation then dropped the holder's read for EVERY
///      instance, real positions included, and {coverage} still read healthy. Reproduced on a live chain-4663
///      fork. Fixed by reading, per instance, ONLY the index bucket of the hook that instance's own PoolKey
///      names ({poolHook}) — which a self-validating preimage fixes beyond a caller's reach. The cost is
///      stated rather than hidden: an instance whose PoolKey has not been registered values NOTHING, so the
///      deployment runbook registers the key of every governed pool and gates on {poolHook} matching it.
///
/// @dev **BOTH POOL CURRENCIES MUST BE REGISTERED** in NAVCalculator or the whole instance is dropped — NAV
///      values an LP from the sum of its two legs, so a half-priced LP would silently understate it. This is
///      the same rule `UniswapV3PoolsMetaBalanceAdapter` applies. `assetFilter` only gates which of the legs
///      are emitted. (The chain-4663 original had no registry gate at all; it is added here because upstream's
///      `PriceFeedLib` is the thing that would otherwise drop half an LP.)
///
/// @dev Valuation is instantaneous on-chain amounts (docs/decisions/0017-lp-valuation-instantaneous-amounts.md):
///      the principal split comes from the pool's live `sqrtPriceX96`, read out of PoolManager storage via
///      `extsload`. Holder resolution is {SickleHeldPositions}' (ADR 0026).
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts, FixedPoint128) —
///      combined work is GPL-2.0-or-later (docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md).
contract FablesSickleRangesMetaBalanceAdapter is MetaBalanceAdapter, SickleHeldPositions {
    using V4StateLibrary for IExtsload;

    /// @notice ERC-7528 convention for ETH address representation — what the NAV registers native ether under.
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice The Uniswap V4 PoolManager singleton holding every pool's state, read via `extsload`.
    /// @dev Immutable and NEVER read off the hook. The hook that reaches this contract comes from a
    ///      permissionless index, so its `poolManager()` is attacker-controlled until proven otherwise;
    ///      asking it where to look would be asking the subject to nominate its own auditor. This is the
    ///      chain's PoolManager, fixed at construction.
    IExtsload public immutable POOL_MANAGER;

    /// @notice Permissionless holder → (hook, rangeId) discovery index.
    /// @dev Required, not an optimisation: ERC-6909 has no enumeration and no per-holder count, so a `view`
    ///      on the NAV hot path cannot derive a holder's ranges from chain state at all. See
    ///      {FablesRangeIndex} for why it is safe to leave open and {coverage} for what it cannot promise.
    FablesRangeIndex public immutable RANGE_INDEX;

    /// @dev poolId → the pool's two currencies, NAV-normalised, learned from a self-validating PoolKey
    ///      preimage. `currency1 == address(0)` is the "no key registered" marker: Uniswap V4 requires
    ///      `currency0 < currency1`, so a real `currency1` is never the zero address and {_asNavAsset} never
    ///      rewrites it.
    mapping(bytes32 => address[2]) private _poolCurrencies;

    /// @dev poolId → the hook its PoolKey names, from the same preimage. LOAD-BEARING: it is the only hook
    ///      {_holderPositions} will call for that instance. Taken from `key.hooks`, never from a
    ///      caller-supplied address, so it is exactly as trustworthy as the preimage — which is to say, as
    ///      trustworthy as keccak256.
    mapping(bytes32 => address) private _poolHook;

    /// @notice The hook has no preimage for this range, so its PoolKey cannot be learned.
    error UnknownRange(address hook, uint256 rangeId);

    event PoolKeyRegistered(bytes32 indexed poolId, address currency0, address currency1);

    /// @param poolManager_   The Uniswap V4 PoolManager singleton for this chain. Must be a contract.
    /// @param rangeIndex_    The {FablesRangeIndex} this adapter discovers ranges through. Must be a contract.
    /// @param sickleFactory_ vfat SickleFactory for this chain. Must be a contract.
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access. Must be a contract.
    constructor(address poolManager_, address rangeIndex_, address sickleFactory_, address navCalculator_)
        MetaBalanceAdapter(navCalculator_)
        SickleHeldPositions(sickleFactory_)
    {
        AddressCheckLib.requireContract(poolManager_, "PoolManager");
        AddressCheckLib.requireContract(rangeIndex_, "FablesRangeIndex");
        POOL_MANAGER = IExtsload(poolManager_);
        RANGE_INDEX = FablesRangeIndex(rangeIndex_);
    }

    //
    // Identity hooks
    //

    /// @notice Broadest brand grouping. Fables is its own brand, not a Uniswap one — see the contract docs.
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.FABLES;
    }

    /// @notice Ecosystem id. Fables is a single-product ecosystem, so this matches the brand and the sub-id.
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.FABLES;
    }

    /// @notice Per-product slug (selects the positionId decode schema: `abi.encode(bytes32 poolId)`).
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.FABLES;
    }

    //
    // Public surface
    //

    /// @notice How much of what `holder` holds this adapter can currently see.
    ///
    /// @dev **THERE IS NO DENOMINATOR, AND THIS METHOD DOES NOT INVENT ONE.** An ERC-721 venue can compare a
    ///      live count against `positionManager.balanceOf(holder)`, an independent on-chain count of what the
    ///      holder actually has. ERC-6909 has no such count: a Fables hook can answer "how many shares in
    ///      range X" but nothing anywhere answers "how many ranges". So this returns the index's own two
    ///      numbers and nothing more, and `live == filed` means only that no filed entry has emptied — it says
    ///      NOTHING about a range that was never filed.
    ///
    ///      The real completeness gate is consequently offchain, and it is STRONGER than a count would be
    ///      because it can name the missing range rather than merely count it. Two forms:
    ///        1. Compare {FablesRangeIndex.indexedRanges} against the hook's `Deposited` UNION ERC-6909
    ///           `Transfer` logs over FULL history. Both halves are load-bearing and MEASURED: on one range,
    ///           `Deposited`-only over 3,000,000 blocks sums 9,534,986,396,283 while the union over full
    ///           history sums 17,572,721,294,310, which is `totalShares` exactly. Shares are transferable, so
    ///           a holder can appear with no `Deposited` of its own, and a bounded log window silently misses
    ///           ranges funded before it (that range was first funded about 31.5M blocks, roughly 37 days,
    ///           before the window started).
    ///        2. Cheaper, and the one an operator runbook should use: the fund chooses its own ticks, so every
    ///           rangeId it will hold is known at quote time. Assert every rangeId in the executed plan is
    ///           filed.
    ///
    /// @param holder The address holding the shares — for a deployed portfolio, the Sickle, not the Safe. Does
    ///        NOT walk the Sickle indirection itself; pass {SickleHeldPositions.sickleOf} if that is what you
    ///        want to measure.
    /// @return live Filed entries that still carry a balance.
    /// @return filed Filed entries in total, live or stale.
    function coverage(address holder) external view returns (uint256 live, uint256 filed) {
        live = RANGE_INDEX.liveCount(holder);
        filed = RANGE_INDEX.indexedCount(holder);
    }

    /// @notice Record a pool's currencies and hook from its PoolKey preimage.
    ///
    /// @dev **A PERMISSIONLESS WRITE ON AN OTHERWISE IMMUTABLE ADAPTER, AND WHY THAT IS NOT A SETTER.** This
    ///      family's rule is immutable constructor args and no setters. This is neither: it is a
    ///      SELF-VALIDATING preimage registry. A key is only ever accepted under the pool id it hashes to, and
    ///      a keccak256 preimage cannot be forged, so the "write" adds no authority to anyone — it only makes
    ///      a fact the chain already fixed readable from here. There is nothing for an owner to own, hence no
    ///      owner, hence no operator bottleneck. It exists because Uniswap V4 pool ids are ONE-WAY: nothing on
    ///      chain maps a poolId back to its currencies, and `underlyingAssetsSupported()` must name assets.
    ///
    ///      It stopped being purely descriptive on 24 Sep 2026: the recorded `key.hooks` is now the only hook
    ///      {_holderPositions} will call for that instance, so an instance whose key has not been registered
    ///      reports NOTHING. Idempotent — a pool id already recorded is left exactly as it is, so a later
    ///      caller cannot overwrite a governed pool's hook.
    function registerPoolKeys(PoolKey[] calldata keys) external {
        uint256 n = keys.length;
        for (uint256 i; i < n; ++i) {
            _record(keccak256(abi.encode(keys[i])), keys[i]);
        }
    }

    /// @notice Same as {registerPoolKeys}, sourcing the keys from live ranges instead of from calldata.
    /// @dev Convenience for an operator who has rangeIds but not the keys typed out. Equally self-validating:
    ///      the pool id is derived from the RETURNED key, so a lying hook can only register a pool id that
    ///      matches no governed instance, which nothing then reads. A lying hook that returns a REAL key
    ///      records the real `key.hooks`, not itself — `hook` here is only ASKED, never stored.
    function learnPoolKeys(address hook, uint256[] calldata rangeIds) external {
        uint256 n = rangeIds.length;
        for (uint256 i; i < n; ++i) {
            (PoolKey memory key,,, bool set) = IFablesHook(hook).rangeKey(rangeIds[i]);
            if (!set) revert UnknownRange(hook, rangeIds[i]);
            _record(keccak256(abi.encode(key)), key);
        }
    }

    /// @notice The NAV-normalised currencies recorded for `poolId`, or `(0, 0)` if no preimage was submitted.
    function poolCurrencies(bytes32 poolId) external view returns (address currency0, address currency1) {
        return (_poolCurrencies[poolId][0], _poolCurrencies[poolId][1]);
    }

    /// @notice The hook `poolId`'s PoolKey names, or zero if no preimage has been submitted. The only hook
    ///         this adapter calls when valuing that instance; zero means the instance reports nothing.
    function poolHook(bytes32 poolId) external view returns (address) {
        return _poolHook[poolId];
    }

    //
    // Meta hooks
    //

    /// @inheritdoc SickleHeldPositions
    /// @dev `instance` is the Uniswap V4 pool id. Runs once for the account and once for its admitted Sickle,
    ///      inside the base's per-instance isolation, so a single malformed hook cannot take the account's
    ///      whole read down.
    ///
    ///      Reads ONLY the index bucket of the hook this instance's PoolKey names. Entries filed under any
    ///      other address are never loaded and never called, so a stranger's entry can neither revert this
    ///      read nor make it expensive. An instance with no registered key returns no rows at all.
    ///
    ///      There is no cap on the bucket. The per-hook bucketing already narrows the attack surface to ranges
    ///      the holder genuinely holds shares in on this one governed hook (the index refuses to file anything
    ///      else), leaving the ERC-6909 dust residual — someone gifting dust shares in many real ranges. That
    ///      is an OPEN medium finding (2 Oct 2026), and its failure mode is loud: the base classifies stipend
    ///      exhaustion as `INAVCalculator.InstanceGasExhausted` and reverts rather than returning a short
    ///      answer. SIMULATED on the Uniswap V4 sibling index: about 330k gas per junk entry against a 10.0M
    ///      read, so roughly 100 entries reach the per-transaction ceiling.
    function _holderPositions(address holder, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address hook = _poolHook[instance];
        if (hook == address(0)) return new INAVCalculator.PositionBalance[](0);

        address[2] memory pair = _poolCurrencies[instance];
        // Fast path: a non-zero `assetFilter` matching neither currency can only ever yield an empty result,
        // so skip the registry lookups and the whole bucket walk below.
        if (assetFilter != address(0) && assetFilter != pair[0] && assetFilter != pair[1]) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Both currencies must be registered: valuing the LP split needs both oracle prices.
        RowCtx memory ctx;
        bool reg0;
        bool reg1;
        (ctx.asset0, reg0) = _getAssetInfo(pair[0]);
        (ctx.asset1, reg1) = _getAssetInfo(pair[1]);
        if (!reg0 || !reg1) return new INAVCalculator.PositionBalance[](0);
        ctx.emit0 = assetFilter == address(0) || assetFilter == pair[0];
        ctx.emit1 = assetFilter == address(0) || assetFilter == pair[1];
        ctx.positionId = _instancePositionId(instance);

        uint256[] memory ids = RANGE_INDEX.indexedRangeIds(holder, hook);
        uint256 n = ids.length;
        // Six legs per range at most: unstaked principal x2, staked principal x2, fees x2.
        INAVCalculator.PositionBalance[] memory buf = new INAVCalculator.PositionBalance[](n * 6);
        uint256 k;

        for (uint256 i; i < n; ++i) {
            Legs memory legs = _legs(hook, holder, instance, ids[i]);
            if (!legs.matched) continue;
            ctx.positionInstanceId = bytes32(ids[i]);
            k = _emitLegs(buf, k, legs, ctx);
        }

        INAVCalculator.PositionBalance[] memory out = new INAVCalculator.PositionBalance[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
        return out;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Only pools whose PoolKey preimage has been submitted can be named — Uniswap V4 pool ids are
    ///      one-way. Returning a short list, or an empty one, is explicitly sanctioned by `IBalanceAdapter`,
    ///      and nothing on the NAV pricing path depends on this method.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address[2] memory pair = _poolCurrencies[instance];
        if (pair[1] == address(0)) return new address[](0);
        assets = new address[](2);
        assets[0] = pair[0];
        assets[1] = pair[1];
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev The coordinate is a raw `bytes32` pool id, not an address, so the base's address-encoding default
    ///      would both revert on a real pool id and advertise ids no leg ever carries.
    function _instancePositionId(bytes32 instance) internal view virtual override returns (bytes memory) {
        return abi.encode(instance);
    }

    //
    // Display
    //

    /// @inheritdoc IPositionDescribable
    /// @dev `["AMM Liquidity Pool", "<sym0>/<sym1>"]` (e.g. `["AMM Liquidity Pool", "ETH/USDG"]`). The leaf
    ///      comes from the pool's registered PoolKey preimage, because a pool id on its own names nothing —
    ///      an instance with no registered key collapses to the single-segment `["AMM Liquidity Pool"]` via
    ///      {_labels}, and a malformed positionId yields an empty array via {_pidWord}. The fee tier is
    ///      deliberately absent from the leaf: every Fables pool is created with the dynamic-fee flag, so
    ///      printing a number there would print the same meaningless constant for every pool.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory) {
        (bytes32 poolId, bool ok) = _pidWord(positionId);
        if (!ok) return new string[](0);
        address[2] memory pair = _poolCurrencies[poolId];
        if (pair[1] == address(0)) return _labels("AMM Liquidity Pool", "");
        return _labels("AMM Liquidity Pool", string.concat(_symbolOf(pair[0]), "/", _symbolOf(pair[1])));
    }

    /// @dev Symbol preferred from the NAV's registered-asset record, which already resolves {NATIVE_ADDRESS}
    ///      to the chain's native symbol — native ether has no `symbol()` to call, and a Fables pool can hold
    ///      it. Falls back to a direct ERC20 read, then to "?", so this never reverts a display-only view.
    function _symbolOf(address asset) private view returns (string memory) {
        (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(asset);
        if (found && bytes(info.symbol).length != 0) return info.symbol;
        return LabelLib.symbol(asset, "?");
    }

    //
    // Valuation
    //

    /// @notice One range's six candidate amounts, plus whether it belongs to the instance being queried.
    /// @dev A struct rather than seven returned locals: it keeps {_valuate} and {_fees} able to fill the same
    ///      object in place instead of threading tuples back through the fan-out loop.
    struct Legs {
        bool matched;
        uint256 supplied0;
        uint256 supplied1;
        uint256 staked0;
        uint256 staked1;
        uint256 fees0;
        uint256 fees1;
    }

    /// @notice The identity of one range read, bundled so the valuation helpers stay inside the EVM's
    ///         addressable stack window. A memory struct costs ONE slot however many fields it carries.
    struct RangeCtx {
        address hook;
        address holder;
        bytes32 instance;
        uint256 rangeId;
        int24 tickLower;
        int24 tickUpper;
        uint128 staked;
        uint128 unstaked;
    }

    /// @notice Values ONE range, and only if all three authority checks pass.
    ///
    /// @dev `hook` is the instance's registered hook ({poolHook}), so it is no longer attacker-supplied;
    ///      `rangeId` still is, since the index is permissionless. The three checks below stay as defence in
    ///      depth, and check 2 still does real work: one hook hosts several pools, so a range filed under the
    ///      right hook can belong to a different pool than the instance being read. In this order, and nothing
    ///      past them runs on a failure:
    ///
    ///        1. BALANCE. `hook.balanceOf(holder, rangeId) > 0`. Drops the stale entry a re-centre leaves
    ///           behind, which is the common case, before anything expensive.
    ///        2. POOL. `keccak256(abi.encode(key)) == instance`, where `key` is what the hook returned.
    ///           `instance` is governed, so by collision resistance `key` must be THE PoolKey of that pool.
    ///        3. HOOK. `key.hooks == hook`. This is the check an NFT-based sibling has no analogue for and the
    ///           one that makes 1 and 2 safe. A hostile contract can simply return the real PoolKey, so check
    ///           2 alone proves nothing about WHO answered; check 3 says the key we validated names the very
    ///           contract we called. Together: the instance fixes the key, the key names the hook, and only
    ///           that hook's numbers are ever used. Without it, a forged hook returning a real key and an
    ///           enormous balance would inflate the NAV by an arbitrary amount.
    ///
    ///      The currencies are NOT taken from `key` here, unlike the chain-4663 original: they are the
    ///      registered pair, resolved once per instance by the caller so the registry gate runs once instead
    ///      of once per range. That is not a weakening. Check 2 proves `key` hashes to `instance`, and the
    ///      registered pair was derived from a preimage of the same `instance`, so by collision resistance the
    ///      two PoolKeys are the same key and the two currency pairs are the same pair.
    function _legs(address hook, address holder, bytes32 instance, uint256 rangeId)
        private
        view
        returns (Legs memory legs)
    {
        uint256 balance = IFablesHook(hook).balanceOf(holder, rangeId);
        if (balance == 0) return legs; // check 1

        RangeCtx memory c;
        c.hook = hook;
        c.holder = holder;
        c.instance = instance;
        c.rangeId = rangeId;

        // Scoped: `key` is dead once its three facts have been checked, and nothing below needs it.
        {
            (PoolKey memory key, int24 lower, int24 upper, bool set) = IFablesHook(hook).rangeKey(rangeId);
            if (!set) return legs;
            if (keccak256(abi.encode(key)) != instance) return legs; // check 2
            if (key.hooks != hook) return legs; // check 3
            c.tickLower = lower;
            c.tickUpper = upper;
        }

        FablesUserPosition memory pos = IFablesHook(hook).userPosition(rangeId, holder);
        if (balance < pos.staked) return legs; // unreachable on a conforming hook; never underflow
        c.staked = pos.staked;
        // casting to `uint128` is safe because `balance` is a sum of uint128 liquidity mints, bounded by
        // the pool's max liquidity, and the line above proves it is at least `pos.staked`.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.unstaked = uint128(balance) - pos.staked;

        _valuate(c, pos, legs);
        legs.matched = true;
    }

    /// @dev One `extsload` batch serves both halves: the principal needs the pool price, the fee backlog needs
    ///      the same position's fee-growth pair, and they come back in the same ten words.
    function _valuate(RangeCtx memory c, FablesUserPosition memory pos, Legs memory legs) private view {
        V4StateLibrary.Snapshot memory s =
            POOL_MANAGER.snapshot(c.instance, c.hook, c.tickLower, c.tickUpper, bytes32(0));

        // Principal. The two share classes are valued SEPARATELY rather than split pro rata, so each leg
        // rounds the way the corresponding `withdraw` would.
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(c.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(c.tickUpper);
        (legs.supplied0, legs.supplied1) =
            LiquidityAmounts.getAmountsForLiquidity(s.sqrtPriceX96, sqrtLower, sqrtUpper, c.unstaked);
        if (c.staked != 0) {
            (legs.staked0, legs.staked1) =
                LiquidityAmounts.getAmountsForLiquidity(s.sqrtPriceX96, sqrtLower, sqrtUpper, c.staked);
        }

        (legs.fees0, legs.fees1) = _fees(c, pos, s);
    }

    /// @notice What `holder`'s UNSTAKED shares in this range could claim right now, both currencies.
    ///
    /// @dev Three components, because the hook credits fees in three stages and a valuer that stopped at the
    ///      first would under-report every range between syncs:
    ///
    ///        1. `pos.owed_i` — settled AND checkpointed. Already net of both cuts.
    ///        2. `accFee_i - checkpoint_i` over the holder's unstaked shares — credited to the range but not
    ///           yet pushed into this holder's `owed`. Already net of both cuts, because `_split` applied them
    ///           before raising `accFee`.
    ///        3. The backlog: earned inside Uniswap V4 but not yet swept into `accFee` by any `_syncRange`.
    ///           NOT yet net of anything, so {_backlog} applies both cuts itself.
    ///
    ///      Staked shares contribute to none of the three: their accrual goes to the distributor.
    function _fees(RangeCtx memory c, FablesUserPosition memory pos, V4StateLibrary.Snapshot memory s)
        private
        view
        returns (uint256 fees0, uint256 fees1)
    {
        fees0 = pos.owed0;
        fees1 = pos.owed1;
        if (c.unstaked == 0) return (fees0, fees1);

        FablesRangeState memory st = IFablesHook(c.hook).rangeState(c.rangeId);
        // Wrapping subtraction is the protocol's own convention: fee growth is a monotonically increasing
        // Q128 counter read modulo 2^256.
        unchecked {
            fees0 += _perShare(c.unstaked, st.accFee0X128 - pos.checkpoint0X128);
            fees1 += _perShare(c.unstaked, st.accFee1X128 - pos.checkpoint1X128);
        }

        uint256 unstakedTotal = uint256(st.totalShares) - st.totalStaked;
        if (unstakedTotal == 0) return (fees0, fees1);

        uint16 feeBps = _effectiveClaimFee(c.hook, c.rangeId);
        if (feeBps == type(uint16).max) return (fees0, fees1); // rate unknown: report less, never more

        unchecked {
            fees0 += _backlog(
                _perShare(s.liquidity, s.feeGrowthInside0X128 - s.feeGrowthInside0LastX128),
                st.totalShares,
                st.totalStaked,
                st.stakedResidual0,
                feeBps,
                unstakedTotal,
                c.unstaked
            );
            fees1 += _backlog(
                _perShare(s.liquidity, s.feeGrowthInside1X128 - s.feeGrowthInside1LastX128),
                st.totalShares,
                st.totalStaked,
                st.stakedResidual1,
                feeBps,
                unstakedTotal,
                c.unstaked
            );
        }
    }

    /// @notice One holder's share of fees that Uniswap V4 holds but the hook has not swept yet.
    ///
    /// @dev Mirrors the hook's `LedgerLib._split` term for term, including the residual carry, so this adapter
    ///      and the hook agree to the wei on what the next `_syncRange` would credit:
    ///
    ///        stakedCut = mulDiv(raw, staked, total) + (residual + mulDiv(mulmod(raw, staked, total), Q128,
    ///                    total)) >> 128            — the carry is a FRACTION of one fee unit, so it survives
    ///                                                the share movement every withdraw causes
    ///        net       = raw - stakedCut
    ///        claimCut  = net * feeBps / 10_000     — taken off the UNSTAKED residue, after the staked cut
    ///        perShare  = mulDiv(net - claimCut, Q128, unstakedTotal)
    ///        mine      = mulDiv(unstaked, perShare, Q128)
    ///
    ///      The Q128 round trip is kept rather than simplified to `unstaked * net / unstakedTotal`, because
    ///      the hook truncates at each of those two steps and matching its rounding is the whole point.
    function _backlog(
        uint256 raw,
        uint128 total,
        uint128 staked,
        uint128 residual,
        uint16 feeBps,
        uint256 unstakedTotal,
        uint128 unstaked
    ) private pure returns (uint256) {
        if (raw == 0 || total == 0) return 0;

        uint256 net = raw;
        if (staked != 0) {
            uint256 carried = uint256(residual) + Math.mulDiv(mulmod(raw, staked, total), FixedPoint128.Q128, total);
            uint256 stakedCut = Math.mulDiv(raw, staked, total) + (carried >> 128);
            if (stakedCut >= raw) return 0;
            net = raw - stakedCut;
        }
        if (feeBps != 0) {
            net -= (net * feeBps) / 10_000;
        }
        return _perShare(unstaked, Math.mulDiv(net, FixedPoint128.Q128, unstakedTotal));
    }

    /// @notice `mulDiv(shares, growthX128, Q128)`, declining rather than reverting on an unreal input.
    /// @dev A fee leg must never revert this read: the NAV reads a revert as "no positions", which is a zero
    ///      NAV for the whole account. A growth delta large enough to overflow the multiplication is not
    ///      reachable from real pool state — it would mean fees on the order of 1e38 raw tokens — so declining
    ///      to report such a leg costs nothing real and removes the revert.
    function _perShare(uint256 shares, uint256 growthX128) private pure returns (uint256) {
        if (growthX128 == 0 || shares == 0) return 0;
        if (growthX128 > type(uint256).max / shares) return 0;
        return Math.mulDiv(growthX128, shares, FixedPoint128.Q128);
    }

    /// @notice The claim-fee rate for this range, or `type(uint16).max` if the hook would not say.
    ///
    /// @dev ONLY `effectiveClaimFee(uint256)` is ever called, never `claimFeeBps()` in either of its shapes.
    ///      MEASURED 24 Sep 2026 on chain 4663: the no-arg getter answers on six deployed hooks and REVERTS on
    ///      `0x5eb87f69be00df39981622fd60a8de4b7837e080`, which declares `claimFeeBps(bytes32)` — and that hook
    ///      alone hosts four of the ten candidate pools. A revert there would price all four at zero,
    ///      silently.
    ///
    ///      `claimFeeRecipient() == address(0)` means `_split` takes no claim fee at all regardless of the
    ///      rate, so it is read too and short-circuits to zero. That zero is a MEANINGFUL value the branch
    ///      turns on, which is why the word is rejected rather than masked when its upper bits are dirty:
    ///      manufacturing `address(0)` out of garbage would change the answer, not merely lose it.
    ///
    ///      The sentinel matters. A hook that will not answer leaves the backlog's net rate unknown, and
    ///      guessing zero would over-report by up to the cap. The caller drops the backlog entirely instead:
    ///      under-reporting an unsynced sliver is recoverable, over-reporting a NAV is not. A `bps >= 10_000`
    ///      reading is rejected the same way — a rate that takes everything is not a rate.
    function _effectiveClaimFee(address hook, uint256 rangeId) private view returns (uint16) {
        (, bool hasRecipient, uint256 recipientWord) =
            StaticCallLib.probeWord(hook, abi.encodeCall(IFablesHook.claimFeeRecipient, ()));
        if (!hasRecipient || recipientWord >> 160 != 0) return type(uint16).max;
        // casting to `uint160` is safe because the line above already rejected any word with dirty bits
        // above 160 — this is the REJECT policy, not the mask one, because `address(0)` is meaningful here.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(recipientWord)) == address(0)) return 0;

        (, bool hasBps, uint256 bps) =
            StaticCallLib.probeWord(hook, abi.encodeCall(IFablesHook.effectiveClaimFee, (rangeId)));
        if (!hasBps || bps >= 10_000) return type(uint16).max;
        // casting to `uint16` is safe because the line above bounds `bps` below 10_000.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(bps);
    }

    //
    // Row assembly
    //

    /// @notice The fields every row of one range shares, resolved once per instance.
    struct RowCtx {
        INAVCalculator.Asset asset0;
        INAVCalculator.Asset asset1;
        bool emit0;
        bool emit1;
        bytes positionId;
        bytes32 positionInstanceId;
    }

    /// @dev Appends this range's six candidate legs in a fixed order: unstaked principal, staked principal,
    ///      then fees; currency0 before currency1 within each.
    function _emitLegs(INAVCalculator.PositionBalance[] memory buf, uint256 k, Legs memory legs, RowCtx memory ctx)
        private
        view
        returns (uint256)
    {
        k = _push(buf, k, ctx, true, legs.supplied0, PositionKind.Supplied);
        k = _push(buf, k, ctx, false, legs.supplied1, PositionKind.Supplied);
        k = _push(buf, k, ctx, true, legs.staked0, PositionKind.Staking);
        k = _push(buf, k, ctx, false, legs.staked1, PositionKind.Staking);
        k = _push(buf, k, ctx, true, legs.fees0, PositionKind.Fees);
        k = _push(buf, k, ctx, false, legs.fees1, PositionKind.Fees);
        return k;
    }

    /// @dev Appends one leg, honouring the batch row contract: a zero amount is not a row, and a currency the
    ///      `assetFilter` excluded is not a row either. The base's `_leg` hardcodes `positionInstanceId` to
    ///      `bytes32(0)`; Fables needs the hook's rangeId there, so the struct is built inline — identity
    ///      fields still come from the `_protocol*` hooks.
    function _push(
        INAVCalculator.PositionBalance[] memory buf,
        uint256 k,
        RowCtx memory ctx,
        bool isCurrency0,
        uint256 amount,
        PositionKind kind
    ) private view returns (uint256) {
        if (amount == 0) return k;
        if (!(isCurrency0 ? ctx.emit0 : ctx.emit1)) return k;
        buf[k] = INAVCalculator.PositionBalance({
            balanceAsset: isCurrency0 ? ctx.asset0 : ctx.asset1,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: _protocolBrand(),
            protocolId: _protocolId(),
            protocolSubId: _protocolSubId(),
            positionId: ctx.positionId,
            positionKind: kind,
            // Staked shares cannot be transferred, but they CAN be withdrawn: `withdraw` auto-unstakes and
            // carries no pause check. Nothing here is locked in the sense the NAV means.
            isLocked: false,
            positionInstanceId: ctx.positionInstanceId
        });
        return k + 1;
    }

    /// @dev Stores the NAV-normalised pair under the id derived from the RAW key, so the id stays a genuine
    ///      preimage of the pool id while the stored currencies are what the NAV can price.
    function _record(bytes32 poolId, PoolKey memory key) private {
        if (_poolCurrencies[poolId][1] != address(0)) return;
        address currency0 = _asNavAsset(key.currency0);
        address currency1 = _asNavAsset(key.currency1);
        _poolCurrencies[poolId] = [currency0, currency1];
        _poolHook[poolId] = key.hooks;
        emit PoolKeyRegistered(poolId, currency0, currency1);
    }

    /// @dev Maps a PoolKey currency onto the asset identifier the NAV actually knows. Only `currency0` can
    ///      ever be native: Uniswap V4 requires `currency0 < currency1` and native ether is `Currency` zero,
    ///      so it sorts first in every pool that trades it. Applied to both legs anyway, because the cost is
    ///      one comparison and the alternative is a rule a future edit can forget — and because `currency1`
    ///      never being zero is exactly what lets `_poolCurrencies[poolId][1]` serve as the "no key
    ///      registered" marker.
    function _asNavAsset(address currency) private pure returns (address) {
        return currency == address(0) ? NATIVE_ADDRESS : currency;
    }
}
