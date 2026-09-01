// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {DeploySalts} from "./DeploySalts.sol";

/// @title AtomicBridgeProxyDeployer
/// @notice Deploys placeholder + BridgeEscrow proxy and upgrades+initializes it in a SINGLE transaction.
/// @dev Front-run-safe, bridge-only counterpart to {AtomicNAVProxyDeployer}. Deploy → `upgradeToAndCall`
///      (initialize) → role handoff all happen in this constructor, so no tx can be inserted between the
///      proxy deploy and its initialize — the exact window a squatter used to hijack `DEFAULT_ADMIN_ROLE`
///      on the first mainnet bridge deploy (which had to fall back to the legacy two-tx path).
///
///      Unlike {AtomicProxyDeployer} — which also deploys + upgrades the NAV proxy and therefore REVERTS on
///      chains where NAV is already live (the proxy is already initialized) — this touches ONLY the bridge
///      proxy, so it is safe to run on the live-NAV mainnets for a clean bridge redeploy.
///
///      Admin is set to this contract during `initialize`; roles are then granted to `adminToGrant` /
///      `managerToGrant` and this contract renounces its own `DEFAULT_ADMIN_ROLE`, leaving no orphaned admin.
///
///      NOTE: the bridge proxy address is `CREATE2(canonical, keccak256("BridgeEscrowProxy", BRIDGE_PROXY), …)`.
///      To deploy a FRESH escrow (not the abandoned one), bump `DeploySalts.BRIDGE_PROXY` before running —
///      otherwise CREATE2 resolves to the existing proxy and the `upgradeToAndCall` reverts (already initialized).
/// @author KPK
contract AtomicBridgeProxyDeployer {
    address private constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    constructor(
        address bridgeImpl,
        uint64 chainId_,
        address[] memory initialAccounts,
        address[] memory initialAdapters,
        address adminToGrant,
        address managerToGrant
    ) {
        // The final step renounces this contract's own DEFAULT_ADMIN_ROLE, so a zero admin here would leave the
        // escrow proxy with no admin (irrecoverable). This contract exists to hand off admin atomically — require it.
        require(adminToGrant != address(0), "AtomicBridgeProxyDeployer: zero admin");

        bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL));
        bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
        address placeholder = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        bytes32 saltBridgeProxy = keccak256(abi.encodePacked("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY));
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address bridgeProxy = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        // 1. Deploy placeholder if not already deployed (shared with the NAV deployer; may already exist).
        if (placeholder.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, placeholderBytecode));
            require(ok, "AtomicBridgeProxyDeployer: placeholder deploy failed");
        }

        // 2. Deploy bridge proxy if not already deployed.
        if (bridgeProxy.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeProxy, bridgeProxyBytecode));
            require(ok, "AtomicBridgeProxyDeployer: bridge proxy deploy failed");
        }

        // 3. Upgrade the proxy to the BridgeEscrow impl and initialize (admin = this contract) — same tx.
        bytes memory initData =
            abi.encodeCall(BridgeEscrow.initialize, (address(this), chainId_, initialAccounts, initialAdapters));
        UUPSUpgradeable(bridgeProxy).upgradeToAndCall(bridgeImpl, initData);

        // 4. Grant DEFAULT_ADMIN_ROLE to the intended admin (guaranteed non-zero by the constructor guard).
        IAccessControl(bridgeProxy).grantRole(DEFAULT_ADMIN_ROLE, adminToGrant);

        // 5. Grant MANAGER while this contract still holds DEFAULT_ADMIN_ROLE.
        if (managerToGrant != address(0)) {
            IAccessControl(bridgeProxy).grantRole(MANAGER, managerToGrant);
        }

        // 6. Renounce this contract's own DEFAULT_ADMIN_ROLE — no orphaned admin after construction.
        IAccessControl(bridgeProxy).renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes memory creationCode) private pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
            );
    }
}
