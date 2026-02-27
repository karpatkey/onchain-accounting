// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title AtomicProxyDeployer
/// @notice Deploys placeholder + NAV + Bridge proxies and upgrades them in a single transaction.
/// @dev Use this to avoid front-running: all steps happen atomically so no one can insert a tx between deploy and upgrade.
///      Admin is set to this contract (msg.sender during init); we then grant DEFAULT_ADMIN_ROLE to adminToGrant so the intended admin can manage roles.
contract AtomicProxyDeployer {
    address private constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    constructor(
        address navImpl,
        address bridgeImpl,
        address chainlinkSequencerFeed,
        string memory nativeTokenSymbol,
        address adminToGrant
    ) {
        (address placeholder, address navProxy, address bridgeProxy) = _computeAddresses();

        _deployIfNeeded(placeholder, navProxy, bridgeProxy);
        _upgradeNav(navProxy, navImpl, chainlinkSequencerFeed, nativeTokenSymbol);
        _upgradeBridge(bridgeProxy, bridgeImpl);
        _grantDefaultAdmin(navProxy, bridgeProxy, adminToGrant);
    }

    function _computeAddresses() private pure returns (address placeholder, address navProxy, address bridgeProxy) {
        bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", uint256(2)));
        bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
        placeholder = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        bytes32 saltNavProxy = keccak256(abi.encodePacked("NAVCalculatorProxy", uint256(2)));
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        navProxy = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = keccak256(abi.encodePacked("BridgeEscrowProxy", uint256(2)));
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bridgeProxy = _computeCreate2(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);
    }

    function _deployIfNeeded(address placeholder, address navProxy, address bridgeProxy) private {
        // 1. Deploy placeholder if not already deployed
        if (placeholder.code.length == 0) {
            bytes32 saltPlaceholder = keccak256(abi.encodePacked("ProxyPlaceholderImpl", uint256(2)));
            bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, placeholderBytecode));
            require(ok, "AtomicProxyDeployer: placeholder deploy failed");
        }

        // 2. Deploy NAV proxy if not already deployed
        if (navProxy.code.length == 0) {
            bytes32 saltNavProxy = keccak256(abi.encodePacked("NAVCalculatorProxy", uint256(2)));
            bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltNavProxy, navProxyBytecode));
            require(ok, "AtomicProxyDeployer: NAV proxy deploy failed");
        }

        // 3. Deploy Bridge proxy if not already deployed
        if (bridgeProxy.code.length == 0) {
            bytes32 saltBridgeProxy = keccak256(abi.encodePacked("BridgeEscrowProxy", uint256(2)));
            bytes memory bridgeProxyBytecode =
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeProxy, bridgeProxyBytecode));
            require(ok, "AtomicProxyDeployer: Bridge proxy deploy failed");
        }
    }

    function _upgradeNav(
        address navProxy,
        address navImpl,
        address chainlinkSequencerFeed,
        string memory nativeTokenSymbol
    ) private {
        // Upgrade NAV proxy (admin = this contract)
        bytes memory navInitData =
            abi.encodeCall(NAVCalculator.initialize, (address(this), chainlinkSequencerFeed, nativeTokenSymbol));
        UUPSUpgradeable(navProxy).upgradeToAndCall(navImpl, navInitData);
    }

    function _upgradeBridge(address bridgeProxy, address bridgeImpl) private {
        // Upgrade Bridge proxy (admin = this contract, chainId = block.chainid)
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize, (address(this), uint64(block.chainid), initialAccounts, initialAdapters)
        );
        UUPSUpgradeable(bridgeProxy).upgradeToAndCall(bridgeImpl, bridgeInitData);
    }

    function _grantDefaultAdmin(address navProxy, address bridgeProxy, address adminToGrant) private {
        // Grant DEFAULT_ADMIN_ROLE to intended admin so they can manage roles (e.g. grant MANAGER)
        if (adminToGrant == address(0)) {
            return;
        }

        IAccessControl(navProxy).grantRole(DEFAULT_ADMIN_ROLE, adminToGrant);
        IAccessControl(bridgeProxy).grantRole(DEFAULT_ADMIN_ROLE, adminToGrant);
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes memory creationCode) private pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
            );
    }
}
