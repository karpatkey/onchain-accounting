// SPDX-License-Identifier: BUSL-1.1
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
///      deployer, the salt, and the creation bytecode. Adapters take their per-chain config via `initialize(...)`;
///      the constructor takes a single `expectedInitializer` arg that 05 appends to `creationCode` with a value
///      (the deployer EOA) that is byte-identical on every chain, so `creationCode` still carries no per-chain data.
///      This test asserts those preconditions hold, so a future change that (a) adds a per-chain constructor arg,
///      (b) collides two salts, or (c) desyncs the salt derivation will fail here instead of silently breaking the
///      same-address guarantee at deploy time. It is intentionally chain-agnostic (no fork / no RPC).
contract BridgeAdapterCreate2SameAddressTest is Test {
    /// @notice Canonical CREATE2 deployer (same on every chain) — must match 05_DeployBridgeAdapters.
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice A fixed placeholder for the `expectedInitializer` constructor arg that 05 appends to each
    ///         adapter's creationCode. Its SPECIFIC value is irrelevant to what this test proves: same-address
    ///         holds because the arg is byte-identical across the loop (so creationCode is chain-independent),
    ///         and distinctness holds for any value. The test asserts those two invariants — NOT that the
    ///         address equals a specific on-chain deploy. At deploy time 05 bakes `chainConfig.admin` (the
    ///         deployer EOA, which varies per deployment), so this constant need only be a fixed, non-zero
    ///         address used identically across the loop — it does not need to equal what 05 bakes.
    address internal constant PINNED_INITIALIZER = 0xd8A2FEc270d6D68B9fA5DBFe5CbEDDE7CefCd7D4;

    /// @notice The seven target chains the same-address guarantee must hold across (ADR 0012 D7 / DeploySalts).
    function _targetChainIds() internal pure returns (uint256[7] memory) {
        return [uint256(1), 10, 100, 137, 42161, 56, 8453];
    }

    struct Spec {
        string name;
        uint256 version;
        bytes creationCode;
    }

    /// @dev creationCode mirrors 05 exactly: raw type(X).creationCode with the single `expectedInitializer`
    ///      constructor arg appended (abi.encode). The arg is identical on every chain, so the address stays
    ///      chain-independent.
    function _initCode(bytes memory creationCode) internal pure returns (bytes memory) {
        return abi.encodePacked(creationCode, abi.encode(PINNED_INITIALIZER));
    }

    function _specs() internal pure returns (Spec[6] memory specs) {
        specs[0] = Spec("CcipBridgeAdapter", DeploySalts.CCIP_ADAPTER, _initCode(type(CcipBridgeAdapter).creationCode));
        specs[1] =
            Spec("AcrossBridgeAdapter", DeploySalts.ACROSS_ADAPTER, _initCode(type(AcrossBridgeAdapter).creationCode));
        specs[2] = Spec(
            "StargateBridgeAdapter", DeploySalts.STARGATE_ADAPTER, _initCode(type(StargateBridgeAdapter).creationCode)
        );
        specs[3] =
            Spec("GnosisBridgeAdapter", DeploySalts.GNOSIS_ADAPTER, _initCode(type(GnosisBridgeAdapter).creationCode));
        specs[4] = Spec("CctpBridgeAdapter", DeploySalts.CCTP_ADAPTER, _initCode(type(CctpBridgeAdapter).creationCode));
        specs[5] = Spec(
            "SuperchainBridgeAdapter",
            DeploySalts.SUPERCHAIN_ADAPTER,
            _initCode(type(SuperchainBridgeAdapter).creationCode)
        );
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

    /// @notice The adapters take exactly one constructor arg — the `expectedInitializer` — which 05 appends to
    ///         `creationCode` with a chain-identical value, so the same-address guarantee holds. If any adapter
    ///         gained an additional (or a per-chain) constructor parameter, `new X(address)` would fail to compile
    ///         (or `_specs` would need per-chain data) and this test would break, flagging that 05's creationCode
    ///         composition (and thus D7) is no longer valid.
    function test_adapterConstructors_takeSingleInitializerArg() public {
        assertTrue(address(new CcipBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Ccip ctor arity changed");
        assertTrue(address(new AcrossBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Across ctor arity changed");
        assertTrue(
            address(new StargateBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Stargate ctor arity changed"
        );
        assertTrue(address(new GnosisBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Gnosis ctor arity changed");
        assertTrue(address(new CctpBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Cctp ctor arity changed");
        assertTrue(
            address(new SuperchainBridgeAdapter(PINNED_INITIALIZER)).code.length > 0, "Superchain ctor arity changed"
        );
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
