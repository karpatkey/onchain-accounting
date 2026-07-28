// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice A mock's own revert, so a test can tell "this instance answered: nothing" from "this instance never
///         answered". The two are indistinguishable to `catch`, which is the whole point.
error MockInstanceUnavailable();

/// @notice The sub-contract an instance read reaches into, which never returns.
/// @dev Nesting is the realistic shape and the one that matters: an instance loses its gas inside the protocol it
///      reads, not in its own frame, so the reserve EIP-150 leaves behind means the fan-out never observes the
///      full stipend consumed.
contract Mock_InstanceSink {
    function burn() external pure {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice A meta-adapter whose governed instances each behave differently, keyed by the coordinate itself.
/// @dev Coordinate 1 reports a DEBT leg, 2 starves inside a sub-call, 3 reverts cheaply. Debt on purpose: a
///      dropped debt leg RAISES the reported NAV, which is what makes a swallowed instance an over-report rather
///      than a cosmetic omission.
contract Mock_FanOutMetaAdapter is MetaBalanceAdapter {
    bytes32 internal constant HEALTHY = bytes32(uint256(1));
    bytes32 internal constant STARVING = bytes32(uint256(2));
    bytes32 internal constant REVERTING = bytes32(uint256(3));

    Mock_InstanceSink private immutable SINK;
    address private immutable ASSET;

    constructor(address nav, address asset) MetaBalanceAdapter(nav) {
        SINK = new Mock_InstanceSink();
        ASSET = asset;
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        return new string[](0);
    }

    function _instancePositions(address, bytes32 instance, address)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (instance == STARVING) SINK.burn();
        if (instance == REVERTING) revert MockInstanceUnavailable();

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0].balanceAsset = INAVCalculator.Asset({asset: ASSET, symbol: "USDC", decimals: 6});
        positions[0].balanceAdapter = address(this);
        positions[0].amount = 1000e6;
        positions[0].isDebt = true;
        positions[0].positionId = abi.encode(_toAddress(instance));
        positions[0].positionKind = PositionKind.Borrowed;
    }

    function _instanceAssets(bytes32) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = ASSET;
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO_VAULTS;
    }
}

/// @notice Runs a fan-out under an explicit gas budget from a fresh frame, reporting which way it ended.
/// @dev A starved instance takes 63/64 of whatever the fan-out holds, so measuring against a forge test frame's
///      ~1e9 gas is both meaningless and slow. `try` also turns the revert into an observation rather than a
///      failed test with no detail.
contract FanOutHarness {
    /// @return status 0 = returned normally, 1 = reverted `InstanceGasExhausted`, 2 = reverted some other way.
    /// @return legs Positions returned when `status == 0`.
    function run(address adapter, address account, uint256 budget) external view returns (uint8 status, uint256 legs) {
        try Mock_FanOutMetaAdapter(adapter).getAdapterPositions{gas: budget}(account, address(0)) returns (
            INAVCalculator.PositionBalance[] memory p
        ) {
            return (0, p.length);
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == INAVCalculator.InstanceGasExhausted.selector) return (1, 0);
            return (2, 0);
        }
    }
}

/// @title MetaBalanceAdapter per-instance gas exhaustion
/// @author KPK
/// @notice Pins the one failure the per-instance `try`/`catch` must NOT absorb.
/// @dev The fan-out isolates each governed instance so a single faulty one cannot zero out the batch, and that
///      isolation is deliberate — an instance whose protocol read reverts has answered, and the account should
///      still get the other instances' legs. Gas exhaustion is categorically different: the instance did not
///      answer, and recording it as an empty leg list drops its legs while the meta-adapter still returns
///      SUCCESSFULLY, so nothing downstream can tell the answer was partial. A dropped debt leg raises the
///      reported NAV.
///
///      Both halves are pinned here, because a fix for one that breaks the other is worse than neither.
contract MetaBalanceAdapterGasExhaustionTest is Test {
    Mock_NAVCalculator internal nav;
    Mock_FanOutMetaAdapter internal adapter;
    FanOutHarness internal harness;
    Mock_ERC20 internal token;

    address internal account = makeAddr("account");

    bytes32 internal constant HEALTHY = bytes32(uint256(1));
    bytes32 internal constant STARVING = bytes32(uint256(2));
    bytes32 internal constant REVERTING = bytes32(uint256(3));

    function setUp() public {
        nav = new Mock_NAVCalculator();
        token = new Mock_ERC20("USDC", 6);
        nav.registerAssetFromERC20(address(token));
        adapter = new Mock_FanOutMetaAdapter(address(nav), address(token));
        harness = new FanOutHarness();
    }

    function _govern(bytes32[] memory instances) private {
        nav.setMetaInstances(address(adapter), instances);
    }

    function _set(bytes32 a, bytes32 b) private returns (bytes32[] memory out) {
        out = new bytes32[](2);
        out[0] = a;
        out[1] = b;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Exhaustion must not be absorbed
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A starved instance must fail the fan-out, not disappear from it.
    /// @dev The load-bearing test. Remove the `InstanceGasExhausted` branch in `_positionsForInstances` and this
    ///      returns status 0 with ONE leg instead of two — a successful-looking answer missing a debt leg, which
    ///      is the silent over-report. Driven across budgets because the shortfall the classifier reasons about
    ///      is a fixed fraction, not a fixed number of gas.
    function test_starvedInstance_failsTheFanOut() public {
        _govern(_set(HEALTHY, STARVING));

        uint256[4] memory budgets = [uint256(5_000_000), 30_000_000, 60_000_000, 250_000_000];
        for (uint256 i = 0; i < budgets.length; i++) {
            (uint8 status,) = harness.run(address(adapter), account, budgets[i]);
            assertEq(status, 1, "a starved instance must surface as InstanceGasExhausted, never as an empty leg set");
        }
    }

    /// @notice The error carries the coordinate of the instance that starved — asserted, not assumed.
    /// @dev Checking only the selector would leave the one thing this error exists for unpinned: a refactor
    ///      passing the wrong coordinate (a stale loop variable, `bytes32(0)`, the adapter widened into the
    ///      instance slot) keeps a selector-only test green while the operator can no longer locate the market.
    function test_starvedInstance_errorNamesTheInstance() public {
        _govern(_set(HEALTHY, STARVING));

        (bool ok, bytes memory err) = address(adapter).staticcall{gas: 30_000_000}(
            abi.encodeCall(adapter.getAdapterPositions, (account, address(0)))
        );
        assertFalse(ok, "a starved instance must fail the fan-out");
        assertEq(err.length, 4 + 32 * 4, "the error must arrive at its full declared width");

        bytes4 sel;
        assembly {
            sel := mload(add(err, 0x20))
        }
        assertEq(sel, INAVCalculator.InstanceGasExhausted.selector, "selector");

        bytes memory args = new bytes(err.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = err[i + 4];
        }
        (address reportedAdapter, bytes32 reportedInstance, uint256 stipend, uint256 consumed) =
            abi.decode(args, (address, bytes32, uint256, uint256));
        assertEq(reportedAdapter, address(adapter), "the adapter field must name this adapter");
        assertEq(reportedInstance, STARVING, "the instance field must name the coordinate that starved");
        assertGt(stipend, 0, "the stipend actually forwarded must be reported");
        assertGe(consumed, stipend - stipend / 8, "and consumed must be what tripped the predicate");
    }

    /// @notice Order must not matter: a starved instance FIRST is caught just as one starved last is.
    /// @dev Worth its own case because the fan-out's remaining gas shrinks as it goes, so the two positions
    ///      exercise different points of the stipend curve.
    function test_starvedInstance_caughtInEitherOrder() public {
        _govern(_set(STARVING, HEALTHY));
        (uint8 first,) = harness.run(address(adapter), account, 30_000_000);
        assertEq(first, 1, "starved first must still fail the fan-out");

        _govern(_set(HEALTHY, STARVING));
        (uint8 last,) = harness.run(address(adapter), account, 30_000_000);
        assertEq(last, 1, "starved last must still fail the fan-out");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Isolation must survive
    // ---------------------------------------------------------------------------------------------------------

    /// @notice An instance that REVERTS is still isolated, and the healthy instances still report.
    /// @dev The counterweight. Treat every `catch` as exhaustion and this fails: one misconfigured market would
    ///      cost the account every other market on the same adapter, which is exactly what the isolation exists
    ///      to prevent and a far more common situation than starvation.
    function test_revertingInstance_isStillIsolated() public {
        _govern(_set(HEALTHY, REVERTING));

        (uint8 status, uint256 legs) = harness.run(address(adapter), account, 30_000_000);
        assertEq(status, 0, "a reverting instance must not fail the fan-out");
        assertEq(legs, 1, "the healthy instance must still report its leg");
    }

    /// @notice Control: with every instance healthy, every leg is reported.
    function test_healthyInstances_allReported() public {
        _govern(_set(HEALTHY, HEALTHY));

        (uint8 status, uint256 legs) = harness.run(address(adapter), account, 30_000_000);
        assertEq(status, 0, "a healthy fan-out must not revert");
        assertEq(legs, 2, "every instance must report its leg");
    }
}
