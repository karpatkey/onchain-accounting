// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {DeploySalts} from "./DeploySalts.sol";

/// @title AtomicProxyDeployer
/// @notice Deploys placeholder + NAV + Bridge proxies and upgrades them in a single transaction.
/// @dev Use this to avoid front-running: all steps happen atomically so no one can insert a tx between deploy and upgrade.
///      Admin is set to this contract (msg.sender during init); roles are handed off to adminToGrant and managerToGrant
///      before this contract renounces its own DEFAULT_ADMIN_ROLE, leaving no orphaned admin.
contract AtomicProxyDeployer {
    address private constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    constructor(
        address navImpl,
        address bridgeImpl,
        address chainlinkSequencerFeed,
        string memory nativeTokenSymbol,
        address adminToGrant,
        address managerToGrant
    ) {
        (address navProxy, address bridgeProxy) = _deployProxies();
        _upgradeNav(navProxy, navImpl, chainlinkSequencerFeed, nativeTokenSymbol);
        _upgradeBridge(bridgeProxy, bridgeImpl);

        // 6. Grant DEFAULT_ADMIN_ROLE to intended admin
        if (adminToGrant != address(0)) {
            IAccessControl(navProxy).grantRole(DEFAULT_ADMIN_ROLE, adminToGrant);
            IAccessControl(bridgeProxy).grantRole(DEFAULT_ADMIN_ROLE, adminToGrant);
        }

        // 7. Grant MANAGER while this contract still holds DEFAULT_ADMIN_ROLE
        if (managerToGrant != address(0)) {
            IAccessControl(navProxy).grantRole(MANAGER, managerToGrant);
            IAccessControl(bridgeProxy).grantRole(MANAGER, managerToGrant);
        }

        // 8. Renounce this contract's own DEFAULT_ADMIN_ROLE — no orphaned admin after construction
        IAccessControl(navProxy).renounceRole(DEFAULT_ADMIN_ROLE, address(this));
        IAccessControl(bridgeProxy).renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    /// @dev Deploys the placeholder, NAV proxy, and Bridge proxy via CREATE2 (idempotent).
    ///      Extracted into a helper to keep the constructor stack depth below the 16-slot EVM limit.
    function _deployProxies() private returns (address navProxy, address bridgeProxy) {
        bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL));
        bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
        address placeholder = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        bytes32 saltNavProxy = keccak256(abi.encodePacked("NAVCalculatorProxy", DeploySalts.NAV_PROXY));
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        navProxy = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = keccak256(abi.encodePacked("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY));
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bridgeProxy = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        // 1. Deploy placeholder if not already deployed
        if (placeholder.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, placeholderBytecode));
            require(ok, "AtomicProxyDeployer: placeholder deploy failed");
        }

        // 2. Deploy NAV proxy if not already deployed
        if (navProxy.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltNavProxy, navProxyBytecode));
            require(ok, "AtomicProxyDeployer: NAV proxy deploy failed");
        }

        // 3. Deploy Bridge proxy if not already deployed
        if (bridgeProxy.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeProxy, bridgeProxyBytecode));
            require(ok, "AtomicProxyDeployer: Bridge proxy deploy failed");
        }
    }

    /// @dev Upgrades the NAV proxy and initializes it with this contract as temporary admin.
    function _upgradeNav(
        address navProxy,
        address navImpl,
        address chainlinkSequencerFeed,
        string memory nativeTokenSymbol
    ) private {
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize, (address(this), chainlinkSequencerFeed, nativeTokenSymbol)
        );
        UUPSUpgradeable(navProxy).upgradeToAndCall(navImpl, navInitData);
    }

    /// @dev Upgrades the Bridge proxy and initializes it with this contract as temporary admin.
    function _upgradeBridge(address bridgeProxy, address bridgeImpl) private {
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize, (address(this), uint64(block.chainid), initialAccounts, initialAdapters)
        );
        UUPSUpgradeable(bridgeProxy).upgradeToAndCall(bridgeImpl, bridgeInitData);
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes memory creationCode) private pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
            );
    }
}
