// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IMetaBalanceAdapter} from "./IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "./IPositionDescribable.sol";
import {IPositionEnumerable} from "./IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {LabelLib} from "./LabelLib.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";

/// @title MetaBalanceAdapter
/// @author KPK
/// @notice Abstract base for meta balance adapters — one immutable adapter serving every instance of a
///         protocol. Concrete adapters implement the per-instance hooks (`_instancePositions`, `_instanceAssets`),
///         the identity hooks (`_protocolBrand`, `_protocolId`, `_protocolSubId`), and `positionLabels`; this base
///         provides the ERC165 wiring, the empty no-op `IBalanceAdapter` methods, the per-instance fan-out
///         with revert isolation, the shared `_leg` builder, and shared NAVCalculator registry helpers.
/// @dev The instance set lives on NAVCalculator (ADR 0010). The adapter reads its own set via
///      `NAV_CALCULATOR.getMetaInstances(address(this))` and holds no instance state or admin functions of its
///      own — it stays immutable. `getAdapterPositionsForInstances` is also exposed for explicit/off-chain queries.
abstract contract MetaBalanceAdapter is IMetaBalanceAdapter, IPositionDescribable, IPositionEnumerable {
    //
    // State
    //

    /// @notice NAVCalculator reference, used for the registered-asset registry.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Gas ceiling for deriving ONE `positionLabels` leaf, applied at the self-call each adapter already
    ///         routes its leaf through.
    /// @dev A leaf reads the chain — pool tokens, gauge LP tokens, ERC20 symbols — through addresses that come
    ///      from a governed coordinate. Without a ceiling the `try this.<leaf>()` boundary forwards 63/64 of the
    ///      frame, so one coordinate whose reads loop consumes nearly the whole budget of whatever called in.
    ///      That is display-only work; it must not be able to spend a caller's read.
    ///
    ///      **This is a fixed ceiling, deliberately, and NOT {GasStipendLib}.** That library answers a different
    ///      question — "did this call run out of gas, or did it answer?" — and its `stipendFrom` is 63/64 of what
    ///      remains, which is what the EVM forwards anyway and therefore bounds nothing. Here there is nothing to
    ///      classify: a leaf that does not fit is simply dropped, and the caller wants a number it can reason
    ///      about. Same idiom as `LabelLib.METADATA_READ_GAS` and `StaticCallLib.PROBE_GAS`.
    ///
    ///      **The value is boxed in from both sides, and the box is narrow.** The floor is the widest leaf a
    ///      governed coordinate can legitimately produce; the hard ceiling is 63/64 of `NAVCalculator`'s
    ///      per-position `_LABEL_READ_GAS` (984,375 at 1,000,000), at or above which the outer cap binds first
    ///      and this constant stops bounding anything on the verbose path. Raising the OUTER budget is not the
    ///      escape hatch it looks like: it is charged per position, so N positions pay N times it.
    ///
    ///      Measured COLD in `test/balances/MetaLabelGasBounds.t.sol`, against ERC-1967 tokens that each have
    ///      their OWN implementation — both properties matter and both understate if dropped. A fixture built in
    ///      a test body is read warm and costs under half; a fixture sharing one implementation across n proxies
    ///      pays EIP-2929's cold 2,600 once and the warm 100 for the rest, understating an n=50 leaf by 122,500.
    ///
    ///      - **Balancer V2 gauges at the protocol maximum of 50 tokens: 912,434 — the binding case.** Strictly
    ///        the widest site: `gaugeTokenSymbols` does everything the pools leaf does (889,581) and reaches it
    ///        through two further cold hops. A ManagedPool's token list is mutable after the instance is
    ///        governed, so registration cannot screen the wide case out.
    ///      - **Fluid vaults: 488,249 at 43 registered assets, rising 9,657 per further asset.**
    ///        `vaultPairSymbols` pulls the whole registered-asset array over to resolve two symbols, so this
    ///        leaf's cost tracks how many assets are registered protocol-wide rather than anything about Fluid.
    ///        Its headroom is therefore denominated in future `registerAsset` calls — about 48 of them; the leaf
    ///        renders at 90 registered assets and is dropped at 93.
    ///      - The widest Curve pool, often assumed to be the worst case, is 138,033 — under a sixth of this.
    ///
    ///      That leaves ~4% over the floor and ~3.5% under the hard ceiling. The margin is thin because the box
    ///      is ~72k wide, not because the value is badly chosen; a materially larger margin needs per-site
    ///      ceilings (the narrow sites — Curve, Convex, Uniswap V2, all capped at 8 tokens — would take ~300k)
    ///      rather than a different single number. Re-measure before changing this: it is a compile-time
    ///      constant on immutable adapters, so a value that turns out too low needs a redeploy to correct.
    uint256 internal constant LABEL_LEAF_GAS = 950_000;

    //
    // Constructor
    //

    /// @notice The NAVCalculator behind `navCalculator_` cannot serve `getRegisteredAsset`, so it predates the
    ///         O(1) registry lookup this adapter family depends on.
    /// @dev Deployment-time, not read-time, and that is the whole point — see the constructor.
    /// @param navCalculator The proxy that failed the probe.
    error NAVCalculatorTooOld(address navCalculator);

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    /// @dev No `protocolName_`: the display name is derived from `_protocolId()` (see `protocolName()`), so there is
    ///      no deployment-time string to supply, mis-spell, or let drift between two adapters of one protocol.
    ///
    ///      Pins the NAVCalculator and **refuses to deploy against one that cannot answer
    ///      `getRegisteredAsset(address)`**.
    ///
    ///      This guard exists because the alternative failure is silent and raises NAV. Meta-adapters are
    ///      IMMUTABLE with this proxy pinned here; NAVCalculator is UUPS-UPGRADEABLE. An adapter built on this base
    ///      and pointed at a proxy running an implementation from before that getter existed would hit a missing
    ///      selector on every `_eligible` call. The proxy reverts cheaply with empty returndata, that revert lands
    ///      in the per-instance `catch` in {_positionsForInstances}, and because `consumed` is small
    ///      `GasStipendLib.exhausted` reads false — so it is NOT re-raised as {InstanceGasExhausted}. The instance
    ///      is recorded as an empty leg list and `getAdapterPositions` **returns successfully**.
    ///
    ///      Dropped legs that included a DEBT leg raise reported NAV, and nothing downstream can tell the answer
    ///      was partial: `underlyingAssetsSupported()` and `positionIds()` both keep answering correctly, because
    ///      neither passes through `_eligible`. That is precisely the failure the per-instance `try`/`catch` is
    ///      documented as never being allowed to absorb, reached by a route the gas classifier is structurally
    ///      blind to — the cause is a missing selector, not exhaustion, so there is no gas signature to detect.
    ///
    ///      **Reachable, and one route is on record as having happened.** `script/deploy/REDEPLOY_RUNBOOK.md` §3
    ///      records `01_2` (the NAV implementation) reverting while `04` (adapters) proceeded: *"RegisterAssets, 04
    ///      and 06 all reported success having done nothing."* The others are a partial rollout across chains where
    ///      one chain's implementation was not upgraded, and an implementation rollback after adapters are
    ///      deployed. `verify_step.py` steps 1.6/1.7 check adapter counts, names, code presence and registration —
    ///      none of which is a functional read, so none of which would notice.
    ///
    ///      A `staticcall` rather than a typed call so a missing selector is a `false` return instead of a revert
    ///      inside the constructor. `address(0)` is a deliberately inert probe argument: on a NAVCalculator that
    ///      has the getter it resolves to `(zeroed, false)` without reverting, so a healthy deploy always passes.
    ///
    ///      **WHAT THIS GUARD DOES NOT COVER.** It runs once, at construction, so it establishes the pairing was
    ///      sound *at deploy time* and nothing more. Three limits, stated because the routes above are easy to
    ///      read as all being closed by it:
    ///
    ///      1. **A post-construction rollback is not detectable here.** Meta-adapters are immutable and
    ///         NAVCalculator is UUPS-upgradeable, so downgrading the implementation after adapters exist leaves
    ///         this guard long since passed and every later `getAdapterPositions` silently returning zero legs.
    ///         Of the three routes above, this one **survives the guard**; the other two do not. Catching it would
    ///         need a read-time probe on the hot path, which is not affordable — the fan-out already runs under a
    ///         per-instance gas stipend.
    ///      2. **Already-deployed adapters are never re-probed.** `04_DeployBalanceAdapters._deployIfEnabled` is
    ///         skip-if-deployed and `06_Configure` re-registers straight from the deployments JSON without any
    ///         version check, so re-running the deploy scripts over an existing fleet does not exercise this
    ///         constructor at all. It binds the *next* adapter deployed, not the ones already out there. (The
    ///         24-chain redeploy clears the records at runbook step 1.1, so every adapter there IS freshly
    ///         constructed and does pass through this guard.)
    ///      3. **Pointing at the NAVCalculator implementation instead of its proxy passes.** The implementation
    ///         genuinely serves the selector; it simply has empty storage, so every lookup returns
    ///         `found == false` and the adapter reports zero legs just as silently. The probe cannot tell the two
    ///         apart, and requiring a non-zero EIP-1967 slot would reject the plain (non-proxy) NAVCalculators
    ///         that unit tests construct against. `verify_step.py 1.3` comparing the recorded implementation
    ///         against the proxy's EIP-1967 slot is the check that catches this one.
    ///
    ///      Costs zero NAVCalculator bytecode — the budget under pressure is that contract's (181 bytes under
    ///      EIP-170), not the adapters', which carry 14-19 KB of margin each.
    constructor(address navCalculator_) {
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");
        (bool ok, bytes memory ret) =
            navCalculator_.staticcall(abi.encodeWithSelector(INAVCalculator.getRegisteredAsset.selector, address(0)));
        // Success alone proves NOTHING, and an earlier version of this guard checked only that. A staticcall
        // returning success with EMPTY returndata satisfies `ok` — so a NAV-shaped contract with a bare
        // `fallback() external {}` passed the probe and was pinned, after which every `_getAssetInfo` failed on
        // return-data decode inside the per-instance catch, `consumed` stayed tiny so it was not re-raised as
        // exhaustion, and the adapter silently reported zero legs. That is precisely the over-report this guard
        // exists to prevent, reinstated by the guard's own weakness (proven by executed PoC in review).
        //
        // A capable NAVCalculator returns `(Asset memory, bool)`: a 32-byte head offset for the struct plus a
        // 32-byte bool, so 64 bytes is the floor. Checking the length is what turns "it did not revert" into
        // "it answered". Note a staticcall to a CODELESS account also returns success with no data, which is why
        // `requireContract` above is load-bearing rather than merely tidy.
        if (!ok || ret.length < 64) revert NAVCalculatorTooOld(navCalculator_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    /// @dev `public` rather than `external` so an adapter advertising a further interface can override and
    ///      `super`-chain — Solidity cannot reach an `external` function through `super`, which would force the
    ///      override to re-declare this whole list and silently drift from it. Matches the same fix on
    ///      {BalanceAdapterBase} and the {AssistedCoordCache} precedent. {IPositionEnumerable} is in the list
    ///      because this base implements it for every meta-adapter (see `positionIds`).
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IMetaBalanceAdapter).interfaceId || interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IPositionEnumerable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IPositionEnumerable
    //

    /// @inheritdoc IPositionEnumerable
    /// @dev Implemented once here for the whole meta family: the shape set of a meta-adapter *is* its governed
    ///      instance set, which lives on the NAVCalculator (ADR 0010), so this reads
    ///      `getMetaInstances(address(this))` and maps each coordinate through {_instancePositionId}.
    ///      Adding or removing an instance is a MANAGER config TX, so this tracks configuration with no adapter
    ///      state and no admin surface — the adapter stays immutable.
    ///
    ///      **This is what makes {_instancePositionId} load-bearing.** {IPositionEnumerable} requires each
    ///      returned id to be byte-identical to the `PositionBalance.positionId` the adapter actually emits, so
    ///      every concrete adapter MUST ensure this hook agrees with what its `_instancePositions` passes to
    ///      {_leg}. An adapter that derives its positionId from something other than the raw coordinate — Aave
    ///      V3, whose coordinate is a ProtocolDataProvider but whose positionId is the Pool resolved from it —
    ///      must override the hook. See the hook's own docs.
    ///
    ///      Returns the ids in `getMetaInstances` order, but no ordering is promised and consumers must not rely
    ///      on it: this is not index-aligned with `getAdapterPositions`, which omits instances an account has no
    ///      position in and may emit several legs sharing one id. Join on the bytes.
    ///
    ///      A listed shape means the instance is configured, NOT that the account holds anything in it, nor that
    ///      the instance's assets are registered for pricing.
    ///
    ///      **Per-instance revert isolation, like every other fan-out on this base.** {IPositionEnumerable}
    ///      requires this function not to revert, and deriving a positionId is not inherently safe: the default
    ///      hook reverts on a malformed coordinate, and Aave V3's override reads the chain to resolve its Pool.
    ///      Without isolation one bad coordinate — which `addMetaInstances` does not prevent, since it never
    ///      checks the coordinate is a contract — would drop the enumeration for every OTHER instance too, and do
    ///      it silently: an adapter that reverts here is indistinguishable, through the consumer's fail-open
    ///      staticcall, from one with nothing configured. That is the exact ambiguity this interface exists to
    ///      remove. A failing instance is therefore dropped and the rest still enumerate — under-report, never
    ///      over-report, the same direction the position fan-out degrades in.
    ///
    ///      Declared `public`, not `external`, for the same reason `supportsInterface` above is: a fork adapter
    ///      that needs to extend or narrow the enumeration can then `super.positionIds()` instead of copying this
    ///      body — a copy would silently keep the old behaviour if this one changes (as it just did, gaining the
    ///      isolation), which is exactly the drift this interface exists to prevent.
    function positionIds() public view virtual override returns (bytes[] memory ids) {
        bytes32[] memory instances = NAV_CALCULATOR.getMetaInstances(address(this));
        bytes[] memory buf = new bytes[](instances.length);
        uint256 n;
        for (uint256 i; i < instances.length; ++i) {
            try this.instancePositionId(instances[i]) returns (bytes memory id) {
                buf[n++] = id;
            } catch {
                // Coordinate could not be resolved — drop this shape, keep the others.
            }
        }
        ids = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = buf[i];
        }
    }

    //
    // IPositionDescribable
    //

    /// @inheritdoc IPositionDescribable
    /// @dev Derived from the adapter's own `_protocolId()`, so "same protocolId ⇒ same protocolName" holds **by
    ///      construction** for every meta adapter: the name is a pure function of the typed identity the adapter
    ///      already declares, not a separate constructor argument that could disagree with it. This is what a
    ///      display name being a *product* name (the Aave Umbrella bug) is now structurally unable to be.
    function protocolName() external pure virtual override returns (string memory) {
        return ProtocolNames.forProtocolId(_protocolId());
    }

    /// @inheritdoc IPositionDescribable
    /// @dev Abstract — each concrete meta-adapter derives the breadcrumb from `positionId` (decode the instance
    ///      coordinate, read its on-chain name/symbol) and returns `_labels("Category", leaf)`. Display only; the
    ///      ephemeral per-item id (if any) is the typed `PositionBalance.positionInstanceId`, not a label.
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory);

    //
    // IBalanceAdapter
    //
    // NAVCalculator calls getAdapterPositions(account, assetFilter) on every adapter uniformly. A meta-adapter
    // services it by reading its NAV-configured instance set and fanning out — no special routing in NAV.
    // getAdapterBalances / getAdapterBalanceForAsset are not used by the NAV path and return empty.
    //

    /// @inheritdoc IBalanceAdapter
    /// @dev Reads the NAV-configured instance set for this adapter and fans out over it (ADR 0010).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _positionsForInstances(account, NAV_CALCULATOR.getMetaInstances(address(this)), assetFilter);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address)
        external
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address, address) external view virtual override returns (uint256, bool) {
        return (0, false);
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view virtual override returns (address[] memory) {
        return _assetsForInstances(NAV_CALCULATOR.getMetaInstances(address(this)));
    }

    //
    // IMetaBalanceAdapter
    //

    /// @inheritdoc IMetaBalanceAdapter
    function getAdapterPositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _positionsForInstances(account, instances, assetFilter);
    }

    /// @inheritdoc IMetaBalanceAdapter
    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        view
        override
        returns (address[] memory)
    {
        return _assetsForInstances(instances);
    }

    //
    // Internal fan-out
    //

    /// @notice Aggregates positions across `instances`, isolating a faulty instance so it cannot zero out the
    ///         batch — but NOT isolating one that ran out of gas.
    /// @dev The isolation is deliberate and stays: an instance whose protocol read reverts has answered, and one
    ///      bad instance must not cost the account the other instances' legs. Gas exhaustion is not that. It
    ///      means the instance did not answer, and recording it as an empty leg list drops whatever it held —
    ///      a dropped *debt* leg RAISES the reported NAV — while this function still returns SUCCESSFULLY, so
    ///      nothing downstream can tell the answer was partial. That is the one failure the per-instance
    ///      `try`/`catch` must not absorb, so it reverts {InstanceGasExhausted} instead.
    ///
    ///      The classification is {GasStipendLib}'s, shared with the adapter-level guard in
    ///      `PriceFeedLib._getAdapterPositions` rather than restated here, because these two are the same
    ///      question asked one frame apart and a threshold that drifts between them re-opens the hole.
    ///
    ///      Note what this deliberately does NOT do: unlike the adapter-level guard, it does not honour an
    ///      {InstanceGasExhausted} selector arriving in the revert data. That guard can afford to, because the
    ///      thing it is listening to is a meta-adapter it has ERC165-checked. Here the revert data comes from a
    ///      protocol this adapter merely reads, so treating a selector in it as a trusted signal would let a
    ///      third-party contract decide that a NAV read must fail. Gas consumed is the only evidence available
    ///      at this boundary that the callee cannot choose.
    ///
    ///      It also cannot see an instance that swallows its OWN out-of-gas — a `_instancePositions`
    ///      implementation whose protocol read is itself wrapped in `try`/`catch` returns normally with a leg
    ///      missing, and nothing here fires. See {GasStipendLib}.
    ///
    ///      **The cost of raising, taken knowingly.** Several protocols let anyone grow a per-account list — a
    ///      withdrawal request names its own owner — so a third party can push one instance's read past what the
    ///      fan-out can hand it and make that account's NAV read FAIL, where before it returned a number that was
    ///      quietly missing a leg. That is the intended direction: a read that cannot see everything must not
    ///      answer as though it did. It is also recoverable in a way the silent version never was, because the
    ///      stipend is a share of the caller's own budget rather than a fixed ceiling — more gas, up to whatever
    ///      the node's `eth_call` cap allows, gets the read through. Past that cap the remedy is the MANAGER's:
    ///      remove the instance.
    function _positionsForInstances(address account, bytes32[] memory instances, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        INAVCalculator.PositionBalance[][] memory perInstance = new INAVCalculator.PositionBalance[][](instances.length);
        uint256 total = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
            uint256 available = gasleft();
            uint256 stipend = GasStipendLib.stipendFrom(available);
            try this.instancePositions{gas: stipend}(account, instances[i], assetFilter) returns (
                INAVCalculator.PositionBalance[] memory p
            ) {
                perInstance[i] = p;
                total += p.length;
            } catch {
                uint256 consumed = available - gasleft();
                if (GasStipendLib.exhausted(stipend, consumed)) {
                    revert INAVCalculator.InstanceGasExhausted(address(this), instances[i], stipend, consumed);
                }
                perInstance[i] = new INAVCalculator.PositionBalance[](0);
            }
        }

        positions = new INAVCalculator.PositionBalance[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            for (uint256 j = 0; j < perInstance[i].length; j++) {
                positions[k++] = perInstance[i][j];
            }
        }
    }

    /// @notice Aggregates the underlying assets across `instances`.
    function _assetsForInstances(bytes32[] memory instances) internal view returns (address[] memory assets) {
        address[][] memory perInstance = new address[][](instances.length);
        uint256 total = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            try this.instanceAssets(instances[i]) returns (address[] memory a) {
                perInstance[i] = a;
                total += a.length;
            } catch {
                perInstance[i] = new address[](0);
            }
        }

        assets = new address[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            for (uint256 j = 0; j < perInstance[i].length; j++) {
                assets[k++] = perInstance[i][j];
            }
        }
    }

    //
    // External wrappers (enable per-instance revert isolation via `this.` staticcall)
    //

    /// @notice External wrapper around the concrete per-instance position logic.
    /// @dev Called via `this.` inside `_positionsForInstances` so a single bad instance is isolated.
    function instancePositions(address account, bytes32 instance, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _instancePositions(account, instance, assetFilter);
    }

    /// @notice External wrapper around the concrete per-instance asset enumeration.
    function instanceAssets(bytes32 instance) external view returns (address[] memory) {
        return _instanceAssets(instance);
    }

    /// @notice External wrapper around the concrete per-instance positionId derivation.
    /// @dev Called via `this.` inside `positionIds` so a single bad coordinate is isolated, exactly as
    ///      `instancePositions` isolates the position fan-out. {_instancePositionId} is not inherently safe to call
    ///      in a loop: the base default reverts via `_toAddress` on a coordinate with dirty high bits, and an
    ///      override may read the chain — Aave V3's resolves the Pool through two external calls, so a codeless,
    ///      reverting or undecodable coordinate reverts here too (none of which `try`/`catch` would catch if it
    ///      were called inline).
    function instancePositionId(bytes32 instance) external view returns (bytes memory) {
        return _instancePositionId(instance);
    }

    //
    // Hooks implemented by concrete adapters
    //

    /// @notice Computes the positions for a single instance. Implementations should return an EMPTY array (not
    ///         revert) for instances whose asset is unregistered or whose balance is zero.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);

    /// @notice Returns the underlying asset(s) for a single instance.
    function _instanceAssets(bytes32 instance) internal view virtual returns (address[] memory);

    //
    // Identity hooks (overridden per adapter)
    //

    /// @notice The adapter's `protocolBrand` — the version-stripped brand roll-up (e.g. `aave`). See ProtocolIds.
    function _protocolBrand() internal pure virtual returns (bytes32);

    /// @notice The adapter's `protocolId` — the ecosystem/version roll-up (e.g. `aave-v3`). See ProtocolIds.
    function _protocolId() internal pure virtual returns (bytes32);

    /// @notice The adapter's `protocolSubId` — the per-product slug; the protocol component of the stable
    ///         reconciliation key (e.g. `aave-v3-lending`). See ProtocolIds.
    function _protocolSubId() internal pure virtual returns (bytes32);

    //
    // Shared helpers
    //

    /// @notice Assembles a single `PositionBalance` with this adapter's identity (the `_protocol*` hooks +
    ///         `balanceAdapter = address(this)`), `isLocked = false`, and `positionInstanceId = bytes32(0)`.
    /// @dev The shared leg builder for every meta-adapter — each instance read calls this instead of inlining a
    ///      9-field struct literal (which also keeps per-adapter frames under the via_ir stack limit). Meta-adapter
    ///      positions are never locked and carry no ephemeral per-item id (the instance coordinate lives in
    ///      `positionId`), so those two fields are fixed here.
    function _leg(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bool isDebt,
        bytes memory positionId,
        PositionKind kind
    ) internal view returns (INAVCalculator.PositionBalance memory leg) {
        leg.balanceAsset = asset;
        leg.balanceAdapter = address(this);
        leg.amount = amount;
        leg.isDebt = isDebt;
        leg.protocolBrand = _protocolBrand();
        leg.protocolId = _protocolId();
        leg.protocolSubId = _protocolSubId();
        leg.positionId = positionId;
        leg.positionKind = kind;
        // isLocked defaults false; positionInstanceId defaults bytes32(0).
    }

    /// @notice Assembles the `[category, leaf]` label pair returned by each meta-adapter's `positionLabels`, applying
    ///         the fail-open empty-leaf convention in one place (IPositionDescribable): a leaf that could not be derived
    ///         (empty string, e.g. a reverting `name()`/`symbol()` read) is dropped so consumers never render
    ///         a blank trailing breadcrumb segment, while the known `category` is preserved. If both are empty,
    ///         returns an empty array. Mirrors `ERC20DefaultBalanceAdapter`'s single-segment collapse, generalised to
    ///         the category+leaf shape every meta-adapter uses.
    /// @dev Centralising this here keeps the convention identical across all meta-adapters instead of being
    ///      re-decided per adapter; concrete adapters derive `leaf` then `return _labels("Category", leaf);`.
    ///
    ///      Deriving that leaf is what {LABEL_LEAF_GAS} bounds — see its docs for why a label read needs a
    ///      ceiling of its own even though the leaf itself is display-only.
    function _labels(string memory category, string memory leaf) internal pure returns (string[] memory) {
        if (bytes(leaf).length == 0) {
            if (bytes(category).length == 0) return new string[](0);
            string[] memory only = new string[](1);
            only[0] = category;
            return only;
        }
        string[] memory out = new string[](2);
        out[0] = category;
        out[1] = leaf;
        return out;
    }

    /// @notice Decodes an address-keyed bytes32 instance coordinate into an address (vault / pool / DataProvider).
    /// @dev Reverts if the high 96 bits are non-zero rather than silently truncating, so a malformed coordinate
    ///      surfaces as an error (isolated per-instance by the fan-out) instead of querying a different address.
    ///      Adapters whose coordinate is a raw bytes32 (e.g. Morpho market ids) do not use this helper.
    function _toAddress(bytes32 instance) internal pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidArgumentsWithContext("instance: not an address");
        return address(uint160(uint256(instance)));
    }

    /// @notice Returns the positionId bytes for a given instance coordinate.
    /// @dev Default: encodes the instance as an address (address-keyed protocols).
    ///      Override when the coordinate is a raw bytes32 (e.g. Morpho market IDs, Balancer V2 poolIds).
    ///
    ///      **This hook must agree with what the adapter emits — it is not merely a convenience.** {positionIds}
    ///      maps the governed instance set through it to satisfy {IPositionEnumerable}'s byte-identity
    ///      guarantee, so `_instancePositionId(instance)` MUST equal the `positionId` that `_instancePositions`
    ///      passes to {_leg} for that instance. Computing the positionId inline while leaving this hook on its
    ///      default is a silent break: the enumeration would advertise ids no position ever carries and the
    ///      configuration-view join would return nothing, with every test still green.
    ///
    ///      An adapter whose positionId is derived from the coordinate rather than being it — Aave V3, whose
    ///      coordinate is a ProtocolDataProvider but whose positionId is the Pool resolved from it — therefore
    ///      overrides this hook and calls it from `_instancePositions` instead of re-deriving inline. (One
    ///      positionId per instance; reserves are distinguished by balanceAsset + positionKind.)
    function _instancePositionId(bytes32 instance) internal view virtual returns (bytes memory) {
        return abi.encode(_toAddress(instance));
    }

    /// @notice Joins the ERC20 symbols of `tokens` with "/" — e.g. `[USDC, WETH]` → `"USDC/WETH"`,
    ///         `[USDC, USDT, DAI]` → `"USDC/USDT/DAI"`.
    /// @dev Fail-open (runs in the lazy, verbose-only `positionLabels` path): a token with no code or whose
    ///      `symbol()` reverts yields `"?"` rather than reverting the whole labels read. Mirrors
    ///      `CurvePoolLib.coinSymbols`; used by the AMM-pool meta-adapters whose label leaf is the underlying
    ///      token set (Balancer V2/V3). Returns "" for an empty `tokens` array.
    function _joinTokenSymbols(address[] memory tokens) internal view returns (string memory result) {
        for (uint256 i; i < tokens.length; ++i) {
            string memory sym = LabelLib.symbol(tokens[i], "?");
            result = i == 0 ? sym : string.concat(result, "/", sym);
        }
    }

    /// @notice Looks up an asset's registry metadata. O(1).
    /// @return asset The Asset struct (zeroed if not found).
    /// @return found True if the asset is registered in NAVCalculator.
    /// @dev One `getRegisteredAsset` call — a mapping load plus one array read, flat in the size of the asset
    ///      registry. `_eligible` runs this before every emitted leg, so its cost is paid `tokens × instances`
    ///      times per read and is the single hottest lookup in this family.
    ///
    ///      **It used to fetch the WHOLE registry per call** (`RegisteredAssetLib.find(NAV_CALCULATOR
    ///      .getRegisteredAssets(), asset)`), which measured **6,274,562 gas for one 50-token Balancer instance at
    ///      43 registered assets** and 18.4M at 100 — super-linear, because each call allocated an N-element array
    ///      that is never freed, so memory expansion grew with the square of the token count. Past a point that
    ///      exhausts the per-adapter stipend and the NAV read REVERTS. So this was an availability defect, not an
    ///      optimisation.
    ///
    ///      **That distinction is why `BALANCE_ADAPTERS.md` §6.4 does not forbid this change, despite reading as
    ///      if it might.** §6.4 rejected a genuinely different design — threading a pre-fetched registry snapshot
    ///      down from `PriceFeedLib`/`NAVCalculator` through a 3-arg `getAdapterPositions` — on two grounds: the
    ///      gas had no payer (ADR 0017: NAV is consumed off-chain), and eagerly fetching the registry for every
    ///      adapter call regressed the EMPTY-ACCOUNT path from <100k to ~166k, because adapters that early-return
    ///      never fetched at all. Neither ground reaches this change: the call sites and call COUNT are unchanged,
    ///      nothing is fetched eagerly, so an adapter that early-returns still fetches nothing — and the first
    ///      ground is superseded by evidence, since a read that reverts is not a cost question.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory, bool found) {
        return NAV_CALCULATOR.getRegisteredAsset(asset);
    }

    /// @notice The filter-then-registry gate every per-instance read applies before emitting a leg: a token is
    ///         eligible when it matches `assetFilter` (or no filter is set) AND is registered in NAVCalculator.
    /// @dev Combines the `assetFilter` short-circuit with `_getAssetInfo` so concrete adapters write one call instead
    ///      of re-deciding the order each time. Returns a zeroed `assetInfo` when ineligible.
    function _eligible(address token, address assetFilter)
        internal
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
    }

    /// @notice Decodes an address-keyed `positionId`, accepting ONLY exactly one clean address word.
    /// @dev The single entry point every address-keyed `positionLabels` in this family must use, because the obvious
    ///      spelling — `if (pid.length < 32) …; abi.decode(pid, (address))` — is wrong in two ways at once, and
    ///      `positionLabels` is a display-only view reachable from a configuration tool that probes with whatever
    ///      word it has:
    ///
    ///      1. **It reverts.** Solidity's ABI decoder validates an `address`, so a 32-byte word whose upper 96 bits
    ///         are dirty (a `bytes32` market/pool id copied from a sibling adapter is the ordinary source) reverts
    ///         instead of degrading. Hence the raw-word decode and an explicit range check.
    ///      2. **It over-claims.** `abi.decode` silently ignores trailing bytes, so a `< 32` guard lets a foreign
    ///         MULTI-word coordinate through and labels it from its first word — a confident, wrong breadcrumb for a
    ///         position the adapter never emitted. Every address-keyed positionId in this family is exactly
    ///         `abi.encode(address)`, so the accept window is `== 32`, not `>= 32`.
    ///
    ///      A dirty word is rejected rather than masked down to its low 160 bits: those bits can name a real
    ///      instance by coincidence, and a wrong label is worse than an absent one.
    /// @return addr The decoded address; `address(0)` when `!ok`.
    /// @return ok True only for a positionId that is exactly one word with clear upper 96 bits.
    function _pidAddress(bytes calldata pid) internal pure returns (address addr, bool ok) {
        if (pid.length != 32) return (address(0), false);
        uint256 raw = abi.decode(pid, (uint256));
        if (raw >> 160 != 0) return (address(0), false);
        return (address(uint160(raw)), true);
    }

    /// @notice Decodes a `bytes32`-keyed `positionId` (Morpho marketIds, Balancer V2 poolIds), accepting ONLY
    ///         exactly one word.
    /// @dev The {_pidAddress} sibling for the raw-`bytes32` coordinate. There is no range check to make — every
    ///      256-bit value is a valid `bytes32`, and `abi.decode(_, (bytes32))` cannot revert on a full word — so
    ///      this exists purely for reason 2 above: `< 32` would label a foreign multi-word coordinate from its
    ///      first word. Kept as a named helper rather than an inline `!= 32` so the two coordinate shapes stay
    ///      visibly symmetric and a reader does not have to re-derive why one has a range check and the other
    ///      does not.
    /// @return word The decoded word; `bytes32(0)` when `!ok`.
    /// @return ok True only for a positionId that is exactly one word.
    function _pidWord(bytes calldata pid) internal pure returns (bytes32 word, bool ok) {
        if (pid.length != 32) return (bytes32(0), false);
        return (abi.decode(pid, (bytes32)), true);
    }

    /// @notice Builds the `positionLabels` `[category, leaf]` for an address-keyed `positionId`, reading the
    ///         instance's on-chain `name()` (or `symbol()` when `useSymbol`) live and fail-open to "" — the
    ///         single-address label shape shared by the vault/market/lending meta-adapters (Morpho, Euler, Fluid,
    ///         Gearbox markets, Compound comets). Returns an empty array for a malformed positionId (see
    ///         {_pidAddress}); the empty-leaf collapse is handled by {_labels}.
    function _addressLabels(bytes calldata pid, string memory category, bool useSymbol)
        internal
        view
        returns (string[] memory)
    {
        (address addr, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        string memory leaf = useSymbol ? LabelLib.symbol(addr, "") : LabelLib.name(addr, "");
        return _labels(category, leaf);
    }
}
