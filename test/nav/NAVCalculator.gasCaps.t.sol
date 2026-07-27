// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @notice A mock's own revert, so a test can tell "the adapter answered: nothing" from "the adapter never
///         answered". Named rather than a bare `revert()` because the two are indistinguishable to `catch`
///         otherwise, and the whole point of these tests is that the reader distinguishes them by cost.
error MockAdapterUnavailable();

/// @notice How a mock misbehaves on one specific read.
enum Misbehaviour {
    Honest,
    // Revert immediately and cheaply — an adapter that HAS answered, and the case fail-open exists for.
    Revert,
    // Loop forever: consumes every unit of gas forwarded, and 63/64 of the caller's if uncapped.
    BurnGas,
    // Burn about HALF of whatever gas it is given, then revert normally. An adapter that did real work and then
    // hit a genuine error — the case that must still fail OPEN, and the one that pins how low the exhaustion
    // threshold may sit.
    BurnHalfThenRevert,
    // Reply SUCCESSFULLY with a large raw blob. The success path is the only way to exercise a reader's
    // returndata-copy cost — a revert bomb of the same size out-of-gasses inside the callee once a stipend is in
    // place, leaving `returndatasize() == 0` and nothing for the caller to copy. See test/mocks/RawReplier.sol.
    BigReturn
}

/// @notice Shared misbehaviour primitives, so each mock states only WHICH read it breaks.
abstract contract Misbehaving {
    /// @notice Size of a {Misbehaviour.BigReturn} reply. ~200 KB costs the callee ~95k of memory expansion, so it
    ///         fits inside any of the stipends under test — the point being that a stipend alone does not stop it.
    uint256 internal constant BIG_REPLY_BYTES = 200_000;

    /// @dev Reverts, burns or replies big, per `m`; returns normally when honest so the caller continues.
    function _misbehave(Misbehaviour m) internal view {
        if (m == Misbehaviour.Revert) revert MockAdapterUnavailable();
        if (m == Misbehaviour.BurnGas) {
            assembly {
                // Hash the same word forever: no memory growth, so this burns the stipend steadily rather than
                // out-of-gassing early on memory expansion.
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        if (m == Misbehaviour.BigReturn) {
            uint256 size = BIG_REPLY_BYTES;
            assembly {
                return(0, size)
            }
        }
        if (m == Misbehaviour.BurnHalfThenRevert) {
            uint256 floor_ = gasleft() / 2;
            assembly {
                for {} gt(gas(), floor_) {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
            revert MockAdapterUnavailable();
        }
    }
}

/// @title Mock_BurningBalanceAdapter
/// @notice A registered adapter whose `getAdapterPositions` never returns.
/// @dev Stands in for the realistic case, which is a BROKEN adapter rather than a hostile one: an unbounded loop
///      over a griefed list, a runaway per-instance fan-out, a dependency that regressed. The NAV read cannot tell
///      those apart from malice, and does not need to.
contract Mock_BurningBalanceAdapter is IBalanceAdapter, Misbehaving {
    Misbehaviour public mode = Misbehaviour.BurnGas;

    function setMode(Misbehaviour m) external {
        mode = m;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        _misbehave(mode);
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        _misbehave(mode);
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external view override returns (uint256, bool) {
        _misbehave(mode);
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Mock_NestedBurner
/// @notice The sub-contract a realistic adapter reads its protocol through, which never returns.
contract Mock_NestedBurner {
    function burn() external pure {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @title Mock_NestedBurningBalanceAdapter
/// @notice An adapter that loses its gas one call level DOWN, not in its own frame.
/// @dev The realistic shape, and the one a naive exhaustion test misses. Every adapter reads its protocol through
///      external calls, so when the gas runs out it runs out inside the callee: the sub-call takes 63/64 of the
///      adapter's stipend, out-of-gasses, and Solidity bubbles the empty revert — leaving the adapter's own 1/64
///      EIP-150 reserve unspent and returned to the caller. The read therefore observes strictly LESS than the
///      full stipend consumed, and a threshold set at the full stipend classifies a starved adapter as a benign
///      revert. Each further level of nesting leaves another reserve behind.
contract Mock_NestedBurningBalanceAdapter is IBalanceAdapter {
    Mock_NestedBurner private immutable BURNER;
    bool public burning = true;

    constructor() {
        BURNER = new Mock_NestedBurner();
    }

    function setBurning(bool b) external {
        burning = b;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (burning) BURNER.burn();
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        if (burning) BURNER.burn();
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external view override returns (uint256, bool) {
        if (burning) BURNER.burn();
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Mock_InstanceExhaustedAdapter
/// @notice An adapter that raises {InstanceGasExhausted} CHEAPLY — the signal a meta-adapter sends when one of
///         its governed instances ran out of gas, at a cost nowhere near its own stipend.
/// @dev The shape the adapter-level gas heuristic cannot see. A meta-adapter that stops on its FIRST starved
///      instance has barely spent anything by the time it raises, so scoring the failure by gas consumed reads a
///      deliberate exhaustion signal as a benign revert and fails open — dropping the whole meta-adapter instead
///      of surfacing the one instance. Hence the explicit selector check upstream, which this mock exists to pin.
contract Mock_InstanceExhaustedAdapter is IBalanceAdapter {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        revert InstanceGasExhausted(address(this), bytes32(uint256(7)), 1_000_000, 999_999);
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        revert InstanceGasExhausted(address(this), bytes32(uint256(7)), 1_000_000, 999_999);
    }

    function getAdapterBalanceForAsset(address, address) external view override returns (uint256, bool) {
        revert InstanceGasExhausted(address(this), bytes32(uint256(7)), 1_000_000, 999_999);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Mock_DebtLegAdapter
/// @notice An honest adapter reporting `legCount` DEBT legs in one asset.
/// @dev Debt on purpose. A dropped debt leg RAISES the reported NAV, which is what makes adapter starvation an
///      over-report rather than a cosmetic omission — so the assertions downstream are about a leg whose absence
///      moves the number in the dangerous direction.
contract Mock_DebtLegAdapter is IBalanceAdapter {
    address private immutable ASSET;
    string private assetSymbol;
    uint8 private immutable ASSET_DECIMALS;
    uint256 public legCount = 1;
    uint256 public amountPerLeg;

    constructor(address asset_, string memory symbol_, uint8 decimals_, uint256 amountPerLeg_) {
        ASSET = asset_;
        assetSymbol = symbol_;
        ASSET_DECIMALS = decimals_;
        amountPerLeg = amountPerLeg_;
    }

    function setLegCount(uint256 n) external {
        legCount = n;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != ASSET) return new INAVCalculator.PositionBalance[](0);
        positions = new INAVCalculator.PositionBalance[](legCount);
        for (uint256 i = 0; i < legCount; i++) {
            positions[i].balanceAsset =
                INAVCalculator.Asset({asset: ASSET, symbol: assetSymbol, decimals: ASSET_DECIMALS});
            positions[i].balanceAdapter = address(this);
            positions[i].amount = amountPerLeg;
            positions[i].isDebt = true;
            positions[i].positionId = abi.encode(address(this));
            positions[i].positionKind = PositionKind.Borrowed;
        }
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory debts)
    {
        assets = new address[](1);
        amounts = new uint256[](1);
        debts = new bool[](1);
        assets[0] = ASSET;
        amounts[0] = amountPerLeg * legCount;
        debts[0] = true;
    }

    function getAdapterBalanceForAsset(address, address asset) external view override returns (uint256, bool) {
        if (asset != ASSET) return (0, false);
        return (amountPerLeg * legCount, true);
    }

    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = ASSET;
    }
}

/// @title Mock_HostileLabelsAdapter
/// @notice An adapter whose POSITIONS are honest and whose `IPositionDescribable` reads are not.
/// @dev The verbose read is the only caller of `protocolName()` / `positionLabels()`, and it makes one
///      `positionLabels` call per position in a single frame. That repetition is where an unbounded
///      returndata copy actually hurts — the caller's memory grows monotonically across the frame, so the cost is
///      quadratic in the total rather than per read. `legCount` is what lets a test reproduce that shape instead
///      of a single read whose cost is lost in the noise.
contract Mock_HostileLabelsAdapter is IBalanceAdapter, IPositionDescribable, Misbehaving {
    address private immutable ASSET;
    string private assetSymbol;
    uint8 private immutable ASSET_DECIMALS;
    uint256 public legCount = 1;
    uint256 public amountPerLeg;

    Misbehaviour public nameMode = Misbehaviour.Honest;
    Misbehaviour public labelMode = Misbehaviour.Honest;

    constructor(address asset_, string memory symbol_, uint8 decimals_, uint256 amountPerLeg_) {
        ASSET = asset_;
        assetSymbol = symbol_;
        ASSET_DECIMALS = decimals_;
        amountPerLeg = amountPerLeg_;
    }

    function setLegCount(uint256 n) external {
        legCount = n;
    }

    function setNameMode(Misbehaviour m) external {
        nameMode = m;
    }

    function setLabelMode(Misbehaviour m) external {
        labelMode = m;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId;
    }

    function protocolName() external view override returns (string memory) {
        _misbehave(nameMode);
        return "Hostile Mock";
    }

    function positionLabels(bytes calldata) external view override returns (string[] memory labels) {
        _misbehave(labelMode);
        labels = new string[](2);
        labels[0] = "Category";
        labels[1] = "Leaf";
    }

    function getAdapterPositions(address, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != ASSET) return new INAVCalculator.PositionBalance[](0);
        positions = new INAVCalculator.PositionBalance[](legCount);
        for (uint256 i = 0; i < legCount; i++) {
            positions[i].balanceAsset =
                INAVCalculator.Asset({asset: ASSET, symbol: assetSymbol, decimals: ASSET_DECIMALS});
            positions[i].balanceAdapter = address(this);
            positions[i].amount = amountPerLeg;
            positions[i].positionId = abi.encode(address(this));
            positions[i].positionKind = PositionKind.Supplied;
        }
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory debts)
    {
        assets = new address[](1);
        amounts = new uint256[](1);
        debts = new bool[](1);
        assets[0] = ASSET;
        amounts[0] = amountPerLeg * legCount;
    }

    function getAdapterBalanceForAsset(address, address asset) external view override returns (uint256, bool) {
        if (asset != ASSET) return (0, false);
        return (amountPerLeg * legCount, false);
    }

    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = ASSET;
    }
}

/// @title NavReadHarness
/// @notice Runs a NAV read under an EXPLICIT gas budget from a fresh external frame.
/// @dev Two reasons this is not done inline in the test. First, an uncapped burner takes 63/64 of whatever the
///      calling frame holds, and a forge test frame holds ~1e9 gas — measuring against that is both meaningless
///      and slow. Second, `try` needs a call boundary to turn the starved read's revert into an observation
///      (`ok == false`) rather than a failed test with no detail. Mirrors StaticCallHarness in
///      test/utils/StaticCallLib.t.sol.
contract NavReadHarness {
    INAVCalculator private immutable NAV;

    constructor(address nav_) {
        NAV = INAVCalculator(nav_);
    }

    /// @notice One `getAccountPositions` under `budget`.
    /// @return ok Whether the read completed at all.
    /// @return legs How many returned positions came from `adapter`.
    /// @return used Gas this frame spent on the whole thing.
    function positionsWithBudget(address account, uint256 budget, address adapter)
        external
        view
        returns (bool ok, uint256 legs, uint256 used)
    {
        uint256 before = gasleft();
        try NAV.getAccountPositions{gas: budget}(account, address(0)) returns (INAVCalculator.Position[] memory p) {
            ok = true;
            for (uint256 i = 0; i < p.length; i++) {
                if (p[i].balanceAdapter == adapter) ++legs;
            }
        } catch {
            ok = false;
        }
        used = before - gasleft();
    }

    /// @notice How a `getAccountPositions` under `budget` ended, distinguishing the three outcomes that matter.
    /// @return status 0 = completed (the read returned a NAV), 1 = reverted with `AdapterGasExhausted`,
    ///         2 = reverted some other way (typically the read itself running out of gas).
    function positionsOutcome(address account, uint256 budget) external view returns (uint8 status) {
        try NAV.getAccountPositions{gas: budget}(account, address(0)) returns (INAVCalculator.Position[] memory) {
            return 0;
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == AdapterGasExhausted.selector) return 1;
            return 2;
        }
    }

    /// @notice One `getAccountNav` under `budget`.
    /// @return ok Whether the read completed at all.
    /// @return value The reported NAV.
    /// @return used Gas this frame spent on the whole thing.
    function navWithBudget(address account, uint256 budget)
        external
        view
        returns (bool ok, int256 value, uint256 used)
    {
        uint256 before = gasleft();
        try NAV.getAccountNav{gas: budget}(account, address(0)) returns (INAVCalculator.NAV memory n) {
            ok = true;
            value = n.value;
        } catch {
            ok = false;
        }
        used = before - gasleft();
    }

    /// @notice One `getAccountPositionsVerbose` under `budget`.
    /// @return ok Whether the read completed at all.
    /// @return legs How many returned positions came from `adapter`.
    /// @return labelled How many of those carried a non-empty label array.
    /// @return named How many of those carried a non-empty protocolName.
    /// @return used Gas this frame spent on the whole thing.
    function verboseWithBudget(address account, uint256 budget, address adapter)
        external
        view
        returns (bool ok, uint256 legs, uint256 labelled, uint256 named, uint256 used)
    {
        uint256 before = gasleft();
        try NAV.getAccountPositionsVerbose{gas: budget}(account, address(0)) returns (
            INAVCalculator.VerbosePosition[] memory p
        ) {
            ok = true;
            for (uint256 i = 0; i < p.length; i++) {
                if (p[i].position.balanceAdapter != adapter) continue;
                ++legs;
                if (p[i].labels.length != 0) ++labelled;
                if (bytes(p[i].protocolName).length != 0) ++named;
            }
        } catch {
            ok = false;
        }
        used = before - gasleft();
    }
}

/// @title NAVCalculatorGasCapTest
/// @notice Pins how the two read paths behave when an adapter spends without answering: the NAV path refuses to
///         report a read it could not complete, and the verbose path bounds what a label read may cost it.
/// @dev Every bound here is load-bearing — remove it from the source and the matching test fails. The ceilings sit
///      far below what the unbounded shape costs and far above what the bounded one spends, so they discriminate
///      without being flaky.
///
///      The distinction the whole file turns on: a `try`/`catch` makes a REVERTING adapter harmless and says
///      nothing about a CONSUMING one. An adapter that runs out of the gas forwarded to it out-of-gasses inside
///      its own frame, and `catch` cannot tell that from "I have no positions" — so on the NAV path the answer is
///      not to fail open at all, and on the display path (labels, protocol names) failing open is right but the
///      cost must be capped in both directions.
contract NAVCalculatorGasCapTest is SuperTest {
    NavReadHarness internal harness;

    /// @dev Gas a read is given when the point is that it must NOT run out. Well above any read in this setup.
    uint256 internal constant GENEROUS_BUDGET = 60_000_000;

    /// @dev Ceiling on a whole VERBOSE read against misbehaving label reads. Unbounded, the burn reaches ~58M
    ///      (63/64 of {GENEROUS_BUDGET}) and eight 200 KB replies reach ~8.9M. Bounded, both land near the cost
    ///      of the read itself.
    uint256 internal constant VERBOSE_READ_CEILING = 3_000_000;

    /// @dev Enough sequential reads in one frame for the caller-side memory growth to dominate — the shape an
    ///      output window flattens and a gas stipend alone does not.
    uint256 internal constant LABEL_LEGS = 8;

    uint256 internal constant DEBT_AMOUNT = 1000e6; // USDC, 6 decimals

    /// @dev Registered-asset count the cost canary holds `ERC20DefaultBalanceAdapter` to — roughly twice the
    ///      largest live registry, since every registered asset is one more iteration of that adapter's loop.
    uint256 internal constant CALIBRATION_ASSETS = 100;

    /// @dev Ceiling for that canary. Not a protocol limit — nothing in the contracts caps a single adapter any
    ///      more — but a tripwire on the one adapter whose cost grows with configuration, so a change that makes
    ///      it dramatically more expensive is caught here rather than by a NAV read that needs more gas than a
    ///      node will give it.
    uint256 internal constant ERC20_DEFAULT_COST_CANARY = 100_000_000;

    function setUp() public {
        setupAll();
        harness = new NavReadHarness(address(nav));
    }

    // -------------------------------------------------------------------------------------------------------
    // The NAV path: exhaustion is not an answer
    // -------------------------------------------------------------------------------------------------------

    /// @notice An adapter that spends its whole stipend without answering must fail the read, not vanish from it.
    /// @dev The load-bearing test for this file. Delete the `AdapterGasExhausted` branch and the read SUCCEEDS,
    ///      returning a NAV whose debt leg is missing — silently too high, produced by the read itself rather
    ///      than by any adapter. Registration order is the point: the burner is queried BEFORE the adapter whose
    ///      legs would be lost.
    function test_burningAdapter_revertsRatherThanDroppingLegs() public {
        Mock_DebtLegAdapter debtor = new Mock_DebtLegAdapter(address(usdc), "USDC", usdc.decimals(), DEBT_AMOUNT);
        Mock_BurningBalanceAdapter burner = new Mock_BurningBalanceAdapter();

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(burner)));
        nav.addBalanceAdapters(aa(address(debtor)));
        vm.stopPrank();

        // Control: with the burner behaving, the debt leg is reported and drags the NAV negative.
        burner.setMode(Misbehaviour.Honest);
        (bool baseOk, int256 expected, uint256 baseline) = harness.navWithBudget(safe, GENEROUS_BUDGET);
        assertTrue(baseOk, "control: the read must succeed with a well-behaved adapter");
        assertLt(expected, 0, "control: the debt leg drags the NAV negative");
        assertLt(baseline, GENEROUS_BUDGET, "control: the read must fit in the budget with room to spare");

        burner.setMode(Misbehaviour.BurnGas);
        vm.expectPartialRevert(AdapterGasExhausted.selector);
        nav.getAccountNav{gas: GENEROUS_BUDGET}(safe, address(0));
    }

    /// @notice Every read path that aggregates adapters inherits the same refusal.
    function test_burningAdapter_revertsOnEveryAggregatingRead() public {
        Mock_BurningBalanceAdapter burner = new Mock_BurningBalanceAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(burner)));

        vm.expectPartialRevert(AdapterGasExhausted.selector);
        nav.getAccountPositions{gas: GENEROUS_BUDGET}(safe, address(0));

        vm.expectPartialRevert(AdapterGasExhausted.selector);
        nav.getAccountNavVerbose{gas: GENEROUS_BUDGET}(safe, address(0));

        vm.expectPartialRevert(AdapterGasExhausted.selector);
        nav.hasPositions{gas: GENEROUS_BUDGET}(safe);
    }

    /// @notice A revert is still an answer: the long-standing fail-open behaviour is untouched.
    /// @dev The other half of the distinction. Collapse the two cases — treat every `catch` as exhaustion — and
    ///      this fails: one misconfigured adapter would take down every NAV read on the deployment.
    function test_revertingAdapter_stillFailsOpen() public {
        Mock_DebtLegAdapter debtor = new Mock_DebtLegAdapter(address(usdc), "USDC", usdc.decimals(), DEBT_AMOUNT);
        Mock_BurningBalanceAdapter reverter = new Mock_BurningBalanceAdapter();
        reverter.setMode(Misbehaviour.Revert);

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(reverter)));
        nav.addBalanceAdapters(aa(address(debtor)));
        vm.stopPrank();

        (bool ok, uint256 legs,) = harness.positionsWithBudget(safe, GENEROUS_BUDGET, address(debtor));
        assertTrue(ok, "a reverting adapter must not take the read down");
        assertEq(legs, 1, "the adapters after it are still reported");
    }

    /// @notice Exhaustion is detected at every budget scale, and the read never quietly completes without the
    ///         burner's adapter.
    /// @dev Guards the margin the detection rests on. `stipend` is derived from the same `available` it is later
    ///      compared against, so the slack — the caller-side overhead the callee never sees — is a constant
    ///      handful of gas whatever the budget, and always has the same sign. Sampling `available` closer to the
    ///      call is an inviting simplification and would break exactly this: the stipend would then be computed
    ///      from a LARGER reading than the one compared against it, and a genuine out-of-gas would slip under the
    ///      threshold and be reported as "no positions" — status 0 below, the silent over-report. Parameterised
    ///      over budgets spanning two orders of magnitude because a margin that holds only at one scale is not a
    ///      margin.
    function test_burningAdapter_exhaustionDetectedAtEveryBudget() public {
        Mock_BurningBalanceAdapter burner = new Mock_BurningBalanceAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(burner)));

        uint256[6] memory budgets = [uint256(2_000_000), 5_000_000, 12_000_000, 30_000_000, 60_000_000, 250_000_000];
        for (uint256 i = 0; i < budgets.length; i++) {
            uint8 status = harness.positionsOutcome(safe, budgets[i]);
            assertEq(status, 1, "a starved adapter must be reported as exhausted at every budget, never as empty");
        }
    }

    /// @notice A meta-adapter's own exhaustion signal must be honoured even when it costs almost nothing to
    ///         raise — the heuristic cannot see it, so the selector must.
    /// @dev The hazard the selector check exists for, and it is a REGRESSION guard, not a nicety: without it this
    ///      cheap revert scores as benign, the read fails open, and the entire meta-adapter's legs vanish — worse
    ///      than the per-instance hole the meta-side fix closes. Delete the `sig == InstanceGasExhausted.selector`
    ///      branch in `PriceFeedLib._getAdapterPositions` and this returns status 0 with the adapter dropped.
    function test_instanceExhaustedSignal_isHonouredRegardlessOfGas() public {
        Mock_InstanceExhaustedAdapter signalling = new Mock_InstanceExhaustedAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(signalling)));

        uint8 status = harness.positionsOutcome(safe, GENEROUS_BUDGET);
        assertEq(status, 2, "a cheap InstanceGasExhausted must still take the read down, not be scored benign");

        vm.expectPartialRevert(InstanceGasExhausted.selector);
        nav.getAccountPositions{gas: GENEROUS_BUDGET}(safe, address(0));
    }

    /// @notice And the specific error survives: the failing instance stays named rather than being collapsed
    ///         into the generic adapter-level error.
    function test_instanceExhaustedSignal_preservesTheInstance() public {
        Mock_InstanceExhaustedAdapter signalling = new Mock_InstanceExhaustedAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(signalling)));

        vm.expectRevert(
            abi.encodeWithSelector(
                InstanceGasExhausted.selector,
                address(signalling),
                bytes32(uint256(7)),
                uint256(1_000_000),
                uint256(999_999)
            )
        );
        nav.getAccountPositions{gas: GENEROUS_BUDGET}(safe, address(0));
    }

    /// @notice An adapter that does real work and THEN reverts must still fail open, and the adapters after it
    ///         must still be reported.
    /// @dev The lower bound on the exhaustion threshold, and the counterweight to
    ///      {test_nestedBurningAdapter_isStillDetected}: one test says the threshold cannot sit at the full
    ///      stipend, this one says how far down it may go. Together they bracket it. Drop the threshold to half
    ///      the stipend and this flips to a revert — every adapter that spends half its budget before failing
    ///      would take the whole read down with it.
    function test_partialBurnThenRevert_stillFailsOpen() public {
        Mock_DebtLegAdapter debtor = new Mock_DebtLegAdapter(address(usdc), "USDC", usdc.decimals(), DEBT_AMOUNT);
        Mock_BurningBalanceAdapter halfBurner = new Mock_BurningBalanceAdapter();
        halfBurner.setMode(Misbehaviour.BurnHalfThenRevert);

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(halfBurner)));
        nav.addBalanceAdapters(aa(address(debtor)));
        vm.stopPrank();

        (bool ok, uint256 legs,) = harness.positionsWithBudget(safe, GENEROUS_BUDGET, address(debtor));
        assertTrue(ok, "an adapter that reverts after real work has ANSWERED - the read must continue");
        assertEq(legs, 1, "and the adapters queried after it must still be reported");
    }

    /// @notice An adapter starved one call level DOWN must be caught too — the realistic shape.
    /// @dev The threshold, not just the presence of the check, is what this pins. A starved adapter never spends
    ///      quite all of its stipend: the sub-call takes 63/64, out-of-gasses, and the adapter's own EIP-150
    ///      reserve comes back unspent, so a threshold at the FULL stipend reads the shortfall as a benign revert
    ///      and fails open. Set the threshold back to `>= stipend` and this test returns status 0 — a NAV that
    ///      silently omits the adapter — while every other test in this file still passes.
    function test_nestedBurningAdapter_isStillDetected() public {
        Mock_NestedBurningBalanceAdapter nested = new Mock_NestedBurningBalanceAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(nested)));

        uint256[4] memory budgets = [uint256(5_000_000), 30_000_000, 60_000_000, 250_000_000];
        for (uint256 i = 0; i < budgets.length; i++) {
            uint8 status = harness.positionsOutcome(safe, budgets[i]);
            assertEq(status, 1, "an adapter starved inside a sub-call must be reported as exhausted, not as empty");
        }
    }

    // -------------------------------------------------------------------------------------------------------
    // Calibration — the stipend must sit above what real adapters cost, not merely above a mock
    // -------------------------------------------------------------------------------------------------------

    /// @notice Cost canary on `ERC20DefaultBalanceAdapter` — the one adapter present on every deployment, and the
    ///         one whose cost grows with the asset registry rather than with the account.
    /// @dev Nothing in the contracts caps a single adapter any more, so this pins no protocol limit; it exists
    ///      because this adapter's cost is a function of CONFIGURATION. A NAV read has to be given more gas than
    ///      the sum of its adapters, and this is the term that grows quietly as assets are registered, so a change
    ///      that makes it dramatically more expensive should fail here rather than in a read that no node will
    ///      fund. Driven at roughly twice the largest live registry.
    function test_erc20DefaultAdapter_costCanary() public {
        address account = makeAddr("calibrationAccount");
        _registerAssets(CALIBRATION_ASSETS, account);

        address adapter = nav.erc20DefaultBalanceAdapter();
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory positions =
            IBalanceAdapter(adapter).getAdapterPositions(account, address(0));
        uint256 used = before - gasleft();

        emit log_named_uint("assets registered", nav.getAssetCount());
        emit log_named_uint("ERC20Default getAdapterPositions gas", used);
        assertGe(positions.length, CALIBRATION_ASSETS, "control: every funded asset must be reported");
        assertLt(used, ERC20_DEFAULT_COST_CANARY, "the registry-scaled adapter must stay within the canary");
    }

    // -------------------------------------------------------------------------------------------------------
    // The verbose path: display reads fail open, but bounded in both directions
    // -------------------------------------------------------------------------------------------------------

    /// @notice Control: honest labels and protocolName still come back intact through the bounded reader.
    /// @dev The bounds are only worth anything if the happy path is untouched — a reader that dropped every
    ///      label would pass every ceiling below.
    function test_verbose_honestAdapter_labelsAndNameSurvive() public {
        Mock_HostileLabelsAdapter mock = _registerLabelMock(LABEL_LEGS);

        INAVCalculator.VerbosePosition[] memory p = nav.getAccountPositionsVerbose(safe, address(0));
        uint256 seen;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].position.balanceAdapter != address(mock)) continue;
            ++seen;
            assertEq(p[i].protocolName, "Hostile Mock", "an honest protocolName must decode");
            assertEq(p[i].labels.length, 2, "an honest label array must decode");
            assertEq(p[i].labels[0], "Category", "label 0");
            assertEq(p[i].labels[1], "Leaf", "label 1");
        }
        assertEq(seen, LABEL_LEGS, "control: every leg must be present");
    }

    /// @notice A `positionLabels` that never returns costs its stipend, not the verbose read.
    /// @dev Drop `{gas: _LABEL_READ_GAS}` from `_safeStringArray` and this fails: `_LABEL_DECODE_GAS` caps the
    ///      DECODE shim only, and here the call that would produce the data to decode never returns. One leg is
    ///      enough — the stipend is per read, so the cost this pins is one stipend, not eight.
    function test_verbose_burningLabels_isGasCapped() public {
        Mock_HostileLabelsAdapter mock = _registerLabelMock(1);
        mock.setLabelMode(Misbehaviour.BurnGas);

        (bool ok, uint256 legs, uint256 labelled,, uint256 used) =
            harness.verboseWithBudget(safe, GENEROUS_BUDGET, address(mock));
        assertTrue(ok, "the verbose read must survive a burning positionLabels");
        assertEq(legs, 1, "positions themselves are unaffected - only their labels are lost");
        assertEq(labelled, 0, "a burning positionLabels yields no labels");
        assertLt(used, VERBOSE_READ_CEILING, "label reads must not spend the whole verbose read's budget");
    }

    /// @notice A `positionLabels` replying with a 200 KB blob must not be copied into the verbose read's memory.
    /// @dev The case a gas stipend alone does NOT cover, and the reason `_boundedRead` passes an explicit output
    ///      size: the callee affords ~200 KB for ~95k of its own memory expansion — inside any stipend here —
    ///      while the caller pays `returndatacopy` plus its own monotonically growing memory, charged outside the
    ///      stipend and quadratic in the frame's total. Staged on the SUCCESS path deliberately (a revert bomb of
    ///      this size OOGs inside the callee under the stipend, leaving nothing to copy) and across {LABEL_LEGS}
    ///      sequential reads in one frame, where that quadratic total reaches ~8.9M gas unbounded.
    function test_verbose_hugeLabelReply_isNotCopied() public {
        Mock_HostileLabelsAdapter mock = _registerLabelMock(LABEL_LEGS);
        mock.setLabelMode(Misbehaviour.BigReturn);

        (bool ok, uint256 legs, uint256 labelled,, uint256 used) =
            harness.verboseWithBudget(safe, GENEROUS_BUDGET, address(mock));
        assertTrue(ok, "the verbose read must survive a huge label reply");
        assertEq(legs, LABEL_LEGS, "positions themselves are unaffected");
        assertEq(labelled, 0, "an undecodable label reply yields no labels");
        assertLt(used, VERBOSE_READ_CEILING, "reply size must not reach the verbose read's memory");
    }

    /// @notice The same two bounds on `protocolName()`, which `_toVerbose` reads once per distinct adapter.
    /// @dev Hence {LABEL_LEGS} separate adapters rather than one adapter with {LABEL_LEGS} positions: the name is
    ///      cached per adapter, so a single hostile adapter would only ever be read once and neither bound would
    ///      show up against the cost of the read itself.
    function test_verbose_misbehavingProtocolName_isBounded() public {
        Mock_HostileLabelsAdapter[] memory mocks = new Mock_HostileLabelsAdapter[](LABEL_LEGS);
        for (uint256 i = 0; i < LABEL_LEGS; i++) {
            mocks[i] = _registerLabelMock(1);
            mocks[i].setNameMode(Misbehaviour.BurnGas);
        }

        (bool burnOk, uint256 burnLegs,, uint256 burnNamed, uint256 burnUsed) =
            harness.verboseWithBudget(safe, GENEROUS_BUDGET, address(mocks[0]));
        assertTrue(burnOk, "the verbose read must survive a burning protocolName");
        assertEq(burnLegs, 1, "positions themselves are unaffected");
        assertEq(burnNamed, 0, "a burning protocolName yields no name");
        assertLt(burnUsed, VERBOSE_READ_CEILING, "name reads must not spend the whole verbose read's budget");

        for (uint256 i = 0; i < LABEL_LEGS; i++) {
            mocks[i].setNameMode(Misbehaviour.BigReturn);
        }
        (bool bigOk, uint256 bigLegs,, uint256 bigNamed, uint256 bigUsed) =
            harness.verboseWithBudget(safe, GENEROUS_BUDGET, address(mocks[0]));
        assertTrue(bigOk, "the verbose read must survive a huge protocolName reply");
        assertEq(bigLegs, 1, "positions themselves are unaffected");
        assertEq(bigNamed, 0, "an undecodable protocolName reply yields no name");
        assertLt(bigUsed, VERBOSE_READ_CEILING, "reply size must not reach the verbose read's memory");
    }

    /// @notice A misbehaving label read must not cost the NAV numbers anything — only the display strings.
    function test_verbose_burningLabels_leavesPositionValuesIntact() public {
        Mock_HostileLabelsAdapter mock = _registerLabelMock(LABEL_LEGS);
        mock.setLabelMode(Misbehaviour.BurnGas);

        INAVCalculator.Position[] memory plain = nav.getAccountPositions(safe, address(0));
        INAVCalculator.VerbosePosition[] memory verbose = nav.getAccountPositionsVerbose(safe, address(0));
        assertEq(verbose.length, plain.length, "verbose must report the same positions as the plain read");
        for (uint256 i = 0; i < plain.length; i++) {
            assertEq(verbose[i].position.value, plain[i].value, "position value must not depend on its labels");
        }
    }

    function _registerLabelMock(uint256 legs) private returns (Mock_HostileLabelsAdapter mock) {
        mock = new Mock_HostileLabelsAdapter(address(usdc), "USDC", usdc.decimals(), 1e6);
        mock.setLegCount(legs);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(mock)));
    }

    /// @dev Registers `count` fresh 18-decimal tokens with a custom feed and funds `account` with each.
    function _registerAssets(uint256 count, address account) private {
        vm.startPrank(navCalculatorManager);
        for (uint256 i = 0; i < count; i++) {
            string memory name = string(abi.encodePacked("TKN", vm.toString(i)));
            Mock_ERC20 token = new Mock_ERC20(name, 18);
            Mock_CustomPriceFeed feed = new Mock_CustomPriceFeed(name, address(token), 1e8, 8);
            nav.registerAsset(address(token), address(feed), IPrices.PriceType.Custom, type(uint256).max);
            token.mint(account, 1000e18);
        }
        vm.stopPrank();
    }
}
