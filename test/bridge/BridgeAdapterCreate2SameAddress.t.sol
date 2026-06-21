// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {CcipBridgeAdapter} from "src/bridge/adapters/CcipBridgeAdapter.sol";
import {AcrossBridgeAdapter} from "src/bridge/adapters/AcrossBridgeAdapter.sol";
import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {GnosisBridgeAdapter} from "src/bridge/adapters/GnosisBridgeAdapter.sol";
import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {SuperchainBridgeAdapter} from "src/bridge/adapters/SuperchainBridgeAdapter.sol";

/// @title BridgeAdapterCreate2SameAddressTest
/// @notice Locks the ADR 0012 D7 "same address on every chain" guarantee that `trustedRemoteAdapter` (D2), the CCTP
///         `mintRecipient`/`destinationCaller`, and the Superchain `receiver` all rely on.
/// @dev 05_DeployBridgeAdapters deploys each adapter via the canonical CREATE2 deployer using
///      `generateSalt(name, DeploySalts.<X>_ADAPTER)` and the adapter's raw `type(X).creationCode`. The deterministic
///      address is `keccak256(0xff ++ deployer ++ salt ++ keccak256(creationCode))[12:]` — it depends ONLY on the
///      deployer, the salt, and the creation bytecode. None of those carry per-chain data BECAUSE the adapters take
///      their args via `initialize(...)` rather than the constructor (so `creationCode` has no appended args). This
///      test asserts those preconditions hold, so a future change that (a) adds a constructor arg, (b) collides two
///      salts, or (c) desyncs the salt derivation will fail here instead of silently breaking the same-address
///      guarantee at deploy time. It is intentionally chain-agnostic (no fork / no RPC).
contract BridgeAdapterCreate2SameAddressTest is Test {
    /// @notice Canonical CREATE2 deployer (same on every chain) — must match 05_DeployBridgeAdapters.
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The seven target chains the same-address guarantee must hold across (ADR 0012 D7 / DeploySalts).
    function _targetChainIds() internal pure returns (uint256[7] memory) {
        return [uint256(1), 10, 100, 137, 42161, 56, 8453];
    }

    struct Spec {
        string name;
        uint256 version;
        bytes creationCode;
    }

    function _specs() internal pure returns (Spec[6] memory specs) {
        specs[0] = Spec("CcipBridgeAdapter", DeploySalts.CCIP_ADAPTER, type(CcipBridgeAdapter).creationCode);
        specs[1] = Spec("AcrossBridgeAdapter", DeploySalts.ACROSS_ADAPTER, type(AcrossBridgeAdapter).creationCode);
        specs[2] = Spec("StargateBridgeAdapter", DeploySalts.STARGATE_ADAPTER, type(StargateBridgeAdapter).creationCode);
        specs[3] = Spec("GnosisBridgeAdapter", DeploySalts.GNOSIS_ADAPTER, type(GnosisBridgeAdapter).creationCode);
        specs[4] = Spec("CctpBridgeAdapter", DeploySalts.CCTP_ADAPTER, type(CctpBridgeAdapter).creationCode);
        specs[5] =
            Spec("SuperchainBridgeAdapter", DeploySalts.SUPERCHAIN_ADAPTER, type(SuperchainBridgeAdapter).creationCode);
    }

    /// @dev Mirrors `BaseDeployScript.computeCreate2Address` (Arachnid 0xff format) exactly.
    function _predict(string memory name, uint256 version, bytes memory creationCode) internal pure returns (address) {
        bytes32 salt = ConfigReader.computeSalt(name, version);
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(creationCode)))
                )
            )
        );
    }

    /// @notice The predicted CREATE2 address depends on no chain-specific input, so it is identical on all 7 chains.
    function test_adapterAddresses_areIdenticalAcrossAllSevenChains() public {
        Spec[6] memory specs = _specs();
        uint256[7] memory chains = _targetChainIds();

        for (uint256 s = 0; s < specs.length; s++) {
            // Baseline prediction (chain-agnostic formula).
            address baseline = _predict(specs[s].name, specs[s].version, specs[s].creationCode);
            assertTrue(baseline != address(0), "predicted adapter address is zero");

            // Re-derive under every target chain id; the address must not move.
            for (uint256 c = 0; c < chains.length; c++) {
                vm.chainId(chains[c]);
                address onChain = _predict(specs[s].name, specs[s].version, specs[s].creationCode);
                assertEq(onChain, baseline, string(abi.encodePacked(specs[s].name, ": address differs across chains")));
            }
        }
    }

    /// @notice No two adapters share a deterministic address (no salt/bytecode collision).
    function test_adapterAddresses_areDistinct() public pure {
        Spec[6] memory specs = _specs();
        address[6] memory addrs;
        for (uint256 i = 0; i < specs.length; i++) {
            addrs[i] = _predict(specs[i].name, specs[i].version, specs[i].creationCode);
        }
        for (uint256 i = 0; i < addrs.length; i++) {
            for (uint256 j = i + 1; j < addrs.length; j++) {
                assertTrue(addrs[i] != addrs[j], "two bridge adapters resolve to the same CREATE2 address");
            }
        }
    }

    /// @notice The adapters have arg-less constructors, so `type(X).creationCode` is the complete init code with no
    ///         per-chain args appended — the precondition for the same-address guarantee. If any adapter gained a
    ///         constructor parameter, `new X()` would fail to compile and this test would break, flagging that 05's
    ///         `type(X).creationCode` deploy (and thus D7) is no longer valid.
    function test_adapterConstructors_areArgless() public {
        assertTrue(address(new CcipBridgeAdapter()).code.length > 0, "Ccip ctor not argless");
        assertTrue(address(new AcrossBridgeAdapter()).code.length > 0, "Across ctor not argless");
        assertTrue(address(new StargateBridgeAdapter()).code.length > 0, "Stargate ctor not argless");
        assertTrue(address(new GnosisBridgeAdapter()).code.length > 0, "Gnosis ctor not argless");
        assertTrue(address(new CctpBridgeAdapter()).code.length > 0, "Cctp ctor not argless");
        assertTrue(address(new SuperchainBridgeAdapter()).code.length > 0, "Superchain ctor not argless");
    }

    /// @notice The `trustedRemoteAdapter` value 06_Configure wires for a same-address sibling is
    ///         `bytes32(uint256(uint160(adapter)))`, and the adapters decode it back via `_toBytes32`/`uint160`. Lock
    ///         that the widen→narrow round-trip is lossless for each adapter's deterministic address.
    function test_trustedRemoteEncoding_roundTrips() public pure {
        Spec[6] memory specs = _specs();
        for (uint256 i = 0; i < specs.length; i++) {
            address adapter = _predict(specs[i].name, specs[i].version, specs[i].creationCode);
            bytes32 encoded = bytes32(uint256(uint160(adapter)));
            assertEq(address(uint160(uint256(encoded))), adapter, "trustedRemoteAdapter encoding is not lossless");
        }
    }
}
