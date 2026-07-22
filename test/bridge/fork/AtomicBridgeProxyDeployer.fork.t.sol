// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {UUPSProxy} from "src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "src/utils/UUPSPlaceholder.sol";
import {AtomicBridgeProxyDeployer} from "script/deploy/AtomicBridgeProxyDeployer.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";
import {BridgeTestBase} from "./BridgeTestBase.fork.sol";

/// @title AtomicBridgeProxyDeployer (Fork)
/// @notice Proves the front-run-safety invariants of {AtomicBridgeProxyDeployer}, the clean-redeploy path for the
///         BridgeEscrow proxy. The first mainnet bridge deploy was front-run in the legacy deploy→initialize window;
///         this deployer closes that window by doing deploy + upgradeToAndCall(initialize) + role handoff +
///         self-admin-renounce in ONE constructor tx. The tests assert the resulting proxy has EXACTLY one admin (the
///         intended one), the deployer keeps NO role (no orphaned admin), initialize cannot be re-run, and the proxy
///         lands at the deterministic CREATE2 address for `DeploySalts.BRIDGE_PROXY`.
/// @dev Runs on the mainnet fork so the canonical CREATE2 factory (0x4e59…) is present, exactly as in production. The
///      `chainId_` passed to the deployer is a distinct fixture value (not the fork's chainid) purely so re-runs at a
///      different salt don't collide with a previously-deployed proxy within the same test process.
contract AtomicBridgeProxyDeployerForkTest is BridgeTestBase {
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    address internal adminToGrant = makeAddr("bridgeAdmin");
    address internal managerToGrant = makeAddr("bridgeManager");

    /// @notice Recomputes the deterministic BridgeEscrow proxy address the deployer targets, so tests can assert the
    ///         proxy landed exactly there (the same computation `02`/`05`/`06` use to find the escrow post-deploy).
    function _predictedBridgeProxy() internal pure returns (address) {
        bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL));
        address placeholder = _create2(saltPlaceholder, type(UUPSPlaceholder).creationCode);

        bytes32 saltBridgeProxy = keccak256(abi.encodePacked("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY));
        bytes memory proxyCode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        return _create2(saltBridgeProxy, proxyCode);
    }

    function _create2(bytes32 salt, bytes memory creationCode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(creationCode)))
                )
            )
        );
    }

    /// @notice The happy path: one atomic tx yields a fully-initialized, correctly-owned escrow with no rogue admin.
    function test_atomicDeploy_grantsIntendedRoles_andRenouncesDeployerAdmin() public {
        address predicted = _predictedBridgeProxy();
        assertEq(predicted.code.length, 0, "fresh salt must resolve to an empty address before deploy");

        address bridgeImpl = address(new BridgeEscrow());
        AtomicBridgeProxyDeployer deployer = new AtomicBridgeProxyDeployer(
            bridgeImpl, MAINNET_CHAIN_ID, new address[](0), new address[](0), adminToGrant, managerToGrant
        );

        // Proxy landed at the deterministic address, with code.
        assertGt(predicted.code.length, 0, "proxy must have code at the predicted CREATE2 address");
        IAccessControl escrow = IAccessControl(predicted);

        // Exactly the intended admin holds DEFAULT_ADMIN_ROLE; the deployer renounced its own — no orphan.
        assertTrue(escrow.hasRole(DEFAULT_ADMIN_ROLE, adminToGrant), "intended admin must hold DEFAULT_ADMIN_ROLE");
        assertFalse(
            escrow.hasRole(DEFAULT_ADMIN_ROLE, address(deployer)),
            "deployer must NOT retain DEFAULT_ADMIN_ROLE (front-run-safety: no orphaned admin)"
        );
        // The manager grant happened while the deployer still held admin.
        assertTrue(escrow.hasRole(MANAGER, managerToGrant), "intended manager must hold MANAGER");

        // Escrow is fully initialized: chainId pinned, re-initialize reverts.
        assertEq(BridgeEscrow(payable(predicted)).chainId(), MAINNET_CHAIN_ID, "chainId must be pinned by initialize");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        BridgeEscrow(payable(predicted)).initialize(adminToGrant, MAINNET_CHAIN_ID, new address[](0), new address[](0));
    }

    /// @notice Front-run-safety is structural, not secrecy-based: the deployer address is irrelevant to the outcome.
    ///         A squatter that pre-deploys the placeholder at its CREATE2 address cannot change who ends up admin —
    ///         the deployer reuses the existing placeholder and still hands admin to the intended account alone.
    function test_atomicDeploy_isSafeEvenIfPlaceholderPreDeployed() public {
        bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL));
        address predictedPlaceholder = _create2(saltPlaceholder, type(UUPSPlaceholder).creationCode);

        // A third party front-runs the placeholder deploy (identical bytecode, same CREATE2 address).
        if (predictedPlaceholder.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, type(UUPSPlaceholder).creationCode));
            assertTrue(ok, "placeholder front-run deploy should succeed");
        }
        assertGt(predictedPlaceholder.code.length, 0, "placeholder is pre-deployed by the squatter");

        address bridgeImpl = address(new BridgeEscrow());
        AtomicBridgeProxyDeployer deployer = new AtomicBridgeProxyDeployer(
            bridgeImpl, MAINNET_CHAIN_ID, new address[](0), new address[](0), adminToGrant, managerToGrant
        );

        IAccessControl escrow = IAccessControl(_predictedBridgeProxy());
        assertTrue(escrow.hasRole(DEFAULT_ADMIN_ROLE, adminToGrant), "intended admin still sole admin");
        assertFalse(escrow.hasRole(DEFAULT_ADMIN_ROLE, address(deployer)), "deployer holds no admin");
    }
}
