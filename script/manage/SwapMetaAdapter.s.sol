// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

interface INavAdmin {
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function removeBalanceAdapters(address[] calldata adapters) external;
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function isAdapterRegistered(address adapter) external view returns (bool);
}

interface IHasProtocolName {
    function protocolName() external view returns (string memory);
}

/// @title SwapMetaAdapter
/// @author kpk
/// @notice Replaces an already-registered META balance adapter with its redeployed successor, carrying the
///         instance set across, in the one order that is safe.
/// @dev **Why this exists.** A meta-adapter is immutable, so any change to its code — including something as small
///      as the display string `protocolName()` returns, which resolves through the inlined `ProtocolNames` library —
///      means deploying a new contract and swapping it in. `06_Configure` cannot do it: its deregistration pass
///      reads the `navBalanceAdapters` namespace and so covers PLAIN adapters only, and it has no notion of
///      superseding a meta adapter at all. Doing it by hand is where the danger is.
///
///      **The order is the whole point: REMOVE, then ADD.** Both adapters registered at once means both report the
///      same positions, and NAV double-counts them. That is a silent over-report — the read succeeds, every leg
///      looks well-formed, and the only symptom is a number that is too large. Adding first and removing second
///      leaves that window open for as long as the two transactions are apart; removing first leaves the opposite
///      window, where the position is briefly missing, which is an under-report and the direction this repo
///      prefers everywhere else.
///
///      **The instance set is read BEFORE the removal**, because `removeBalanceAdapters` wipes it. The script then
///      asserts the count round-trips onto the successor, so a swap that silently dropped instances fails loudly
///      instead of leaving a registered adapter that reports nothing.
///
///      Usage — both addresses are passed explicitly rather than derived, because during a swap the deployment
///      record names exactly one of them and which one depends on whether `04` has already run:
///
///      ```
///      OLD_ADAPTER=0x... NEW_ADAPTER=0x... \
///        FOUNDRY_PROFILE=slow forge script script/manage/SwapMetaAdapter.s.sol \
///          --rpc-url $RPC --broadcast --account my-deployer --password-file $PW --slow
///      ```
///
///      MANAGER-gated on the NAV, like every other registration path.
contract SwapMetaAdapter is BaseDeployScript {
    /// @notice Thrown when either address argument is missing.
    error AdapterNotProvided();

    /// @notice Thrown when the outgoing adapter is not actually registered — nothing to swap, and proceeding
    ///         would register the successor alongside whatever else is live.
    error PredecessorNotRegistered(address old);

    /// @notice Thrown when the successor has no code at the given address.
    error SuccessorHasNoCode(address newAdapter);

    /// @notice Thrown when the instance set did not survive the swap.
    error InstanceSetLost(address newAdapter, uint256 expected, uint256 got);

    function run() public override {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        INavAdmin navAdmin = INavAdmin(nav);

        address old = vm.envOr("OLD_ADAPTER", address(0));
        address newAdapter = vm.envOr("NEW_ADAPTER", address(0));
        if (old == address(0) || newAdapter == address(0)) revert AdapterNotProvided();
        if (newAdapter.code.length == 0) revert SuccessorHasNoCode(newAdapter);
        if (!navAdmin.isAdapterRegistered(old)) revert PredecessorNotRegistered(old);

        // Read the instance set BEFORE the removal wipes it.
        bytes32[] memory instances = navAdmin.getMetaInstances(old);

        console2.log("NAV:", nav);
        console2.log("  outgoing:", old, IHasProtocolName(old).protocolName());
        console2.log("  incoming:", newAdapter, IHasProtocolName(newAdapter).protocolName());
        console2.log("  instances carried:", instances.length);

        vm.startBroadcast();

        address[] memory one = new address[](1);
        one[0] = old;
        navAdmin.removeBalanceAdapters(one);

        navAdmin.addMetaBalanceAdapter(newAdapter, instances);

        vm.stopBroadcast();

        uint256 got = navAdmin.getMetaInstances(newAdapter).length;
        if (got != instances.length) revert InstanceSetLost(newAdapter, instances.length, got);
        if (navAdmin.isAdapterRegistered(old)) revert PredecessorNotRegistered(old);

        console2.log("[OK] swapped; instance count round-tripped:", got);
    }
}
