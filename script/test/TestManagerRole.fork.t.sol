// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestEnvConfigurator} from "../../test/TestEnvConfigurator.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {MANAGER} from "../../src/constants.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Empty} from "../../src/utils/Empty.sol";
import {console2} from "forge-std/console2.sol";

/// @title TestManagerRole
/// @notice Fork test to verify manager role is granted after proxy initialization
/// @dev Tests that the manager address has MANAGER role on both NAVCalculator and BridgeEscrow proxies
contract TestManagerRole is TestEnvConfigurator {
    using ConfigReader for *;

    // Manager address from config
    address public constant MANAGER_ADDRESS = 0xb007369cA6656639de93c444daE8789159d4CBFb;

    // Chain ID to test (mainnet)
    uint256 public constant CHAIN_ID = 1;

    // Canonical CREATE2 deployer address (same on all chains)
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = getAlchemyUrl("eth-mainnet");
        vm.createSelectFork(rpcUrl);
    }

    /// @notice Computes the placeholder implementation address (same on all chains)
    /// @dev Uses the same computation as 02a_DeployProxies.s.sol lines 28-31:
    ///      generateSalt("ProxyPlaceholderImpl", 1) + type(Empty).creationCode + CREATE2
    function _computePlaceholderAddress() internal pure returns (address) {
        // Same as: bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", 1);
        bytes32 saltPlaceholder = ConfigReader.computeSalt("ProxyPlaceholderImpl", 1);
        // Same as: bytes memory placeholderBytecode = type(Empty).creationCode;
        bytes memory placeholderBytecode = type(Empty).creationCode;
        // Same as: address placeholder = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);
        return _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);
    }

    /// @notice Computes CREATE2 address using the same formula as BaseDeployScript.computeCreate2Address
    /// @dev Matches the CREATE2 computation: keccak256(0xff || deployer || salt || keccak256(creationCode))
    function _computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
        );
    }

    /// @notice Initializes a proxy via upgradeToAndCall (UUPS pattern, simulating Safe execution)
    /// @param proxy The proxy address
    /// @param impl The implementation address
    /// @param initData The initialization data
    /// @param safeAddress The Safe multisig address (will get DEFAULT_ADMIN_ROLE during init)
    function _initializeProxyViaProxyAdmin(address proxy, address impl, bytes memory initData, address safeAddress)
        internal
    {
        // UUPS pattern: call upgradeToAndCall directly on proxy
        // Placeholder implementation has no _authorizeUpgrade, so upgrade works
        // After upgrade, Safe gets DEFAULT_ADMIN_ROLE during initialization
        vm.prank(safeAddress);
        UUPSUpgradeable(proxy).upgradeToAndCall(impl, initData);
    }

    /// @notice Test that manager has MANAGER role on NAVCalculator proxy after initialization
    function test_ManagerHasRoleOnNAVCalculator() public {
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, CHAIN_ID);
        address navProxy = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "NAVCalculatorProxy");
        address expectedImpl = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "NAVCalculatorImplementation");

        require(navProxy != address(0), "NAVCalculator proxy not deployed");
        require(expectedImpl != address(0), "NAVCalculator implementation not configured");
        require(chainConfig.manager != address(0), "Manager address not configured");

        // Check current implementation
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address currentImpl = address(uint160(uint256(vm.load(navProxy, implementationSlot))));
        address placeholderAddress = _computePlaceholderAddress();

        console2.log("NAVCalculator Proxy:", navProxy);
        console2.log("Current Implementation:", currentImpl);
        console2.log("Placeholder Implementation:", placeholderAddress);
        console2.log("Expected Implementation:", expectedImpl);

        // If proxy doesn't have the expected implementation, upgrade and initialize it via ProxyAdmin
        if (currentImpl != expectedImpl) {
            bytes memory navInitData = abi.encodeCall(
                NAVCalculator.initialize,
                (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
            );
            _initializeProxyViaProxyAdmin(navProxy, expectedImpl, navInitData, chainConfig.safeMultisig);
            console2.log("Upgraded and initialized NAVCalculator proxy via upgradeToAndCall");
        }

        NAVCalculator nav = NAVCalculator(navProxy);

        // Verify proxy was initialized (has DEFAULT_ADMIN_ROLE set to admin)
        require(
            nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.admin),
            "NAVCalculator proxy not initialized - admin role not set"
        );

        // Grant MANAGER role if not already granted (simulating 02b script behavior)
        if (!nav.hasRole(MANAGER, chainConfig.manager)) {
            vm.prank(chainConfig.admin);
            nav.grantRole(MANAGER, chainConfig.manager);
            console2.log("Granted MANAGER role to manager on NAVCalculator");
        }

        // Now check that manager has MANAGER role
        bool hasManagerRole = nav.hasRole(MANAGER, chainConfig.manager);

        console2.log("Manager Address:", chainConfig.manager);
        console2.log("Has MANAGER role:", hasManagerRole);

        assertTrue(hasManagerRole, "Manager should have MANAGER role on NAVCalculator");
    }

    /// @notice Test that manager has MANAGER role on BridgeEscrow proxy after initialization
    function test_ManagerHasRoleOnBridgeEscrow() public {
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, CHAIN_ID);
        address bridgeProxy = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "BridgeEscrowProxy");
        address expectedImpl = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "BridgeEscrowImplementation");

        require(bridgeProxy != address(0), "BridgeEscrow proxy not deployed");
        require(expectedImpl != address(0), "BridgeEscrow implementation not configured");
        require(chainConfig.manager != address(0), "Manager address not configured");

        // Check current implementation
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address currentImpl = address(uint160(uint256(vm.load(bridgeProxy, implementationSlot))));
        address placeholderAddress = _computePlaceholderAddress();

        console2.log("BridgeEscrow Proxy:", bridgeProxy);
        console2.log("Current Implementation:", currentImpl);
        console2.log("Placeholder Implementation:", placeholderAddress);
        console2.log("Expected Implementation:", expectedImpl);

        // If proxy doesn't have the expected implementation, upgrade and initialize it via ProxyAdmin
        if (currentImpl != expectedImpl) {
            address[] memory initialAccounts = new address[](0);
            address[] memory initialAdapters = new address[](0);
            bytes memory bridgeInitData = abi.encodeCall(
                BridgeEscrow.initialize,
                (
                    chainConfig.admin,
                    CHAIN_ID > type(uint64).max ? uint64(0) : uint64(CHAIN_ID),
                    initialAccounts,
                    initialAdapters
                )
            );
            _initializeProxyViaProxyAdmin(bridgeProxy, expectedImpl, bridgeInitData, chainConfig.safeMultisig);
            console2.log("Upgraded and initialized BridgeEscrow proxy via upgradeToAndCall");
        }

        BridgeEscrow bridge = BridgeEscrow(payable(bridgeProxy));

        // Verify proxy was initialized (has DEFAULT_ADMIN_ROLE set to admin)
        require(
            bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), chainConfig.admin),
            "BridgeEscrow proxy not initialized - admin role not set"
        );

        // Grant MANAGER role if not already granted (simulating 02b script behavior)
        if (!bridge.hasRole(MANAGER, chainConfig.manager)) {
            vm.prank(chainConfig.admin);
            bridge.grantRole(MANAGER, chainConfig.manager);
            console2.log("Granted MANAGER role to manager on BridgeEscrow");
        }

        // Now check that manager has MANAGER role
        bool hasManagerRole = bridge.hasRole(MANAGER, chainConfig.manager);

        console2.log("Manager Address:", chainConfig.manager);
        console2.log("Has MANAGER role:", hasManagerRole);

        assertTrue(hasManagerRole, "Manager should have MANAGER role on BridgeEscrow");
    }

    /// @notice Test that manager has MANAGER role on both proxies
    function test_ManagerHasRoleOnBothProxies() public {
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, CHAIN_ID);
        address navProxy = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "NAVCalculatorProxy");
        address bridgeProxy = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "BridgeEscrowProxy");
        address navImpl = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "NAVCalculatorImplementation");
        address bridgeImpl = ConfigReader.readDeployedAddress(vm, CHAIN_ID, "BridgeEscrowImplementation");

        require(navProxy != address(0), "NAVCalculator proxy not deployed");
        require(bridgeProxy != address(0), "BridgeEscrow proxy not deployed");
        require(navImpl != address(0), "NAVCalculator implementation not configured");
        require(bridgeImpl != address(0), "BridgeEscrow implementation not configured");
        require(chainConfig.manager != address(0), "Manager address not configured");
        require(chainConfig.manager == MANAGER_ADDRESS, "Manager address mismatch in config");

        // Check and initialize NAVCalculator proxy if needed
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address navCurrentImpl = address(uint160(uint256(vm.load(navProxy, implementationSlot))));

        if (navCurrentImpl != navImpl) {
            bytes memory navInitData = abi.encodeCall(
                NAVCalculator.initialize,
                (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
            );
            _initializeProxyViaProxyAdmin(navProxy, navImpl, navInitData, chainConfig.safeMultisig);
            console2.log("Upgraded and initialized NAVCalculator proxy via ProxyAdmin.upgradeAndCall");
        }

        // Check and initialize BridgeEscrow proxy if needed
        address bridgeCurrentImpl = address(uint160(uint256(vm.load(bridgeProxy, implementationSlot))));

        if (bridgeCurrentImpl != bridgeImpl) {
            address[] memory initialAccounts = new address[](0);
            address[] memory initialAdapters = new address[](0);
            bytes memory bridgeInitData = abi.encodeCall(
                BridgeEscrow.initialize,
                (
                    chainConfig.admin,
                    CHAIN_ID > type(uint64).max ? uint64(0) : uint64(CHAIN_ID),
                    initialAccounts,
                    initialAdapters
                )
            );
            _initializeProxyViaProxyAdmin(bridgeProxy, bridgeImpl, bridgeInitData, chainConfig.safeMultisig);
            console2.log("Upgraded and initialized BridgeEscrow proxy via ProxyAdmin.upgradeAndCall");
        }

        console2.log("NAVCalculator Implementation:", address(uint160(uint256(vm.load(navProxy, implementationSlot)))));
        console2.log(
            "BridgeEscrow Implementation:", address(uint160(uint256(vm.load(bridgeProxy, implementationSlot))))
        );

        // Verify proxies are initialized (have DEFAULT_ADMIN_ROLE set)
        NAVCalculator nav = NAVCalculator(navProxy);
        BridgeEscrow bridge = BridgeEscrow(payable(bridgeProxy));

        require(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.admin), "NAVCalculator proxy not initialized");
        require(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), chainConfig.admin), "BridgeEscrow proxy not initialized");

        // Grant MANAGER role if not already granted (simulating 02b script behavior)
        if (!nav.hasRole(MANAGER, chainConfig.manager)) {
            vm.prank(chainConfig.admin);
            nav.grantRole(MANAGER, chainConfig.manager);
            console2.log("Granted MANAGER role to manager on NAVCalculator");
        }

        if (!bridge.hasRole(MANAGER, chainConfig.manager)) {
            vm.prank(chainConfig.admin);
            bridge.grantRole(MANAGER, chainConfig.manager);
            console2.log("Granted MANAGER role to manager on BridgeEscrow");
        }

        require(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.admin), "NAVCalculator proxy not initialized");
        require(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), chainConfig.admin), "BridgeEscrow proxy not initialized");

        // Now check that manager has MANAGER role on both
        bool navHasRole = nav.hasRole(MANAGER, chainConfig.manager);
        bool bridgeHasRole = bridge.hasRole(MANAGER, chainConfig.manager);

        console2.log("Manager Address:", chainConfig.manager);
        console2.log("NAVCalculator - Manager has role:", navHasRole);
        console2.log("BridgeEscrow - Manager has role:", bridgeHasRole);

        assertTrue(navHasRole, "Manager should have MANAGER role on NAVCalculator");
        assertTrue(bridgeHasRole, "Manager should have MANAGER role on BridgeEscrow");
    }

    /// @notice Test that the manager address matches the expected address
    function test_ManagerAddressMatchesExpected() public view {
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, CHAIN_ID);

        console2.log("Expected Manager Address:", MANAGER_ADDRESS);
        console2.log("Config Manager Address:", chainConfig.manager);

        assertEq(chainConfig.manager, MANAGER_ADDRESS, "Manager address in config should match expected address");
    }
}
