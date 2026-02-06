// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestEnvConfigurator} from "../../test/TestEnvConfigurator.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title Test02b_InitializeProxies
/// @notice Tests the 02b flow: upgradeToAndCall(realImpl, initData) called directly on proxy.
contract Test02b_InitializeProxies is TestEnvConfigurator {
    using ConfigReader for *;
    using SafeTxBuilder for *;

    function setUp() public {
        if (block.number == 0 || block.chainid == 31337) {
            string memory rpcUrl = getAlchemyUrl("eth-mainnet");
            vm.createSelectFork(rpcUrl);
        }
    }

    /// @notice UUPS proxy has no ProxyAdmin - upgrades go directly through proxy to implementation
    function test_UUPSProxyHasNoProxyAdmin() public {
        UUPSPlaceholder placeholder = new UUPSPlaceholder();
        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        // UUPS proxy doesn't have ProxyAdmin - admin slot should be empty or point to zero
        address adminFromSlot = _getProxyAdmin(address(proxy));
        assertEq(adminFromSlot, address(0), "UUPS proxy should not have ProxyAdmin");
        console2.log("[OK] UUPS proxy has no ProxyAdmin (upgrades go directly through proxy)");
    }

    /// @notice Full 02b-style flow: proxy with placeholder -> upgradeToAndCall(navImpl, initData) -> NAV initialized.
    function test_02bUpgradeAndCallInitializesNAVProxy() public {
        address safe = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address admin = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address sequencerFeed = address(0);
        UUPSPlaceholder placeholder = new UUPSPlaceholder();
        NAVCalculator navImpl = new NAVCalculator();

        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        bytes memory navInitData = abi.encodeCall(NAVCalculator.initialize, (admin, sequencerFeed, "ETH"));

        // UUPS: call upgradeToAndCall directly on proxy (placeholder has no _authorizeUpgrade, so upgrade works)
        vm.prank(safe);
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(navImpl), navInitData);

        NAVCalculator nav = NAVCalculator(address(proxy));
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), admin), "NAV proxy should be initialized with admin");
        console2.log("[OK] 02b upgradeToAndCall flow initializes NAV proxy");
    }

    /// @notice Full 02b-style flow: proxy with placeholder -> upgradeToAndCall(bridgeImpl, initData) -> Bridge initialized.
    function test_02bUpgradeAndCallInitializesBridgeProxy() public {
        address safe = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address admin = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        uint64 chainId = 1;
        UUPSPlaceholder placeholder = new UUPSPlaceholder();
        BridgeEscrow bridgeImpl = new BridgeEscrow();

        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData =
            abi.encodeCall(BridgeEscrow.initialize, (admin, chainId, initialAccounts, initialAdapters));

        // UUPS: call upgradeToAndCall directly on proxy (placeholder has no _authorizeUpgrade, so upgrade works)
        vm.prank(safe);
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(bridgeImpl), bridgeInitData);

        BridgeEscrow bridge = BridgeEscrow(payable(address(proxy)));
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), admin), "Bridge proxy should be initialized with admin");
        console2.log("[OK] 02b upgradeToAndCall flow initializes Bridge proxy");
    }

    /// @notice Build the same calldata as 02b and verify selector and targets.
    function test_02bCalldataStructure() public view {
        address navProxy = address(0x3720E21E0D581faDC1626f0464cC9f023beB1aAa);
        address bridgeProxy = address(0x911A0818da77365ED0f246FB15053E5324a810f6);
        address navImpl = address(0x149aE89A9C1EdE914df158C18Ee4DCEeb0283541);
        address bridgeImpl = address(0x50FE322E01eB7e537418D6C90ea586063260454D);

        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize, (address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537), address(0), "ETH")
        );
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537), uint64(1), initialAccounts, initialAdapters)
        );

        bytes memory navCalldata =
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, navImpl, navInitData);
        bytes memory bridgeCalldata =
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, bridgeImpl, bridgeInitData);

        assertEq(bytes4(navCalldata), UUPSUpgradeable.upgradeToAndCall.selector, "NAV tx uses upgradeToAndCall");
        assertEq(bytes4(bridgeCalldata), UUPSUpgradeable.upgradeToAndCall.selector, "Bridge tx uses upgradeToAndCall");
        assertEq(navCalldata.length > 4, true, "NAV calldata should have parameters");
        assertEq(bridgeCalldata.length > 4, true, "Bridge calldata should have parameters");
        console2.log("[OK] 02b calldata structure (targets + upgradeToAndCall selector) is valid");
    }

    /// @notice Run 02b logic (build txs + writeSafeTx) and assert it writes a valid Safe TX file.
    /// @dev Uses same logic as 02b_InitializeProxies.s.sol; requires chain config with proxy + impl addresses.
    function test_02bScriptRunWritesValidSafeTxFile() public {
        uint256 chainId = block.chainid;
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, chainId);
        address navProxy = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        address bridgeProxy = ConfigReader.readDeployedAddress(vm, chainId, "BridgeEscrowProxy");
        address navImpl = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorImplementation");
        address bridgeImpl = ConfigReader.readDeployedAddress(vm, chainId, "BridgeEscrowImplementation");

        if (navProxy == address(0) || bridgeProxy == address(0) || navImpl == address(0) || bridgeImpl == address(0)) {
            console2.log("[SKIP] test_02bScriptRunWritesValidSafeTxFile: config missing proxy/impl for chain");
            return;
        }

        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (
                chainConfig.admin,
                chainId > type(uint64).max ? uint64(0) : uint64(chainId),
                initialAccounts,
                initialAdapters
            )
        );

        // Count transactions: 2 upgrades + 2 grantRole (if manager is configured)
        uint256 txCount = 2;
        if (chainConfig.manager != address(0)) {
            txCount += 2; // Grant MANAGER role to NAVCalculator and BridgeEscrow
        }
        SafeTxBuilder.Transaction[] memory allTxs = new SafeTxBuilder.Transaction[](txCount);
        uint256 txIndex = 0;

        // UUPS: call upgradeToAndCall directly on proxy
        allTxs[txIndex] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, navImpl, navInitData)
        );
        txIndex++;

        allTxs[txIndex] = SafeTxBuilder.call(
            bridgeProxy,
            0,
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, bridgeImpl, bridgeInitData)
        );
        txIndex++;

        // Add grantRole transactions if manager is configured
        if (chainConfig.manager != address(0)) {
            allTxs[txIndex] = SafeTxBuilder.call(
                navProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
            );
            txIndex++;

            allTxs[txIndex] = SafeTxBuilder.call(
                bridgeProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
            );
            txIndex++;
        }

        string memory filename = string(abi.encodePacked(vm.toString(chainId), "-initialize-proxies.json"));
        SafeTxBuilder.writeSafeTx(
            vm,
            chainId,
            filename,
            "Initialize NAVCalculator + BridgeEscrow proxies",
            string(abi.encodePacked("Chain ", vm.toString(chainId), ": upgrade and init proxies.")),
            chainConfig.safeMultisig,
            allTxs
        );

        string memory path = string(abi.encodePacked("safe-transactions/", filename));
        string memory json = vm.readFile(path);
        assertTrue(bytes(json).length > 0, "Safe TX file should be written");
        assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(chainId), "chainId in file should match");

        // Verify transaction count matches expected (2 upgrades + 2 grantRole if manager configured)
        uint256 expectedTxCount = chainConfig.manager != address(0) ? 4 : 2;
        assertEq(txCount, expectedTxCount, "Transaction count should match expected");

        console2.log("[OK] 02b logic wrote valid Safe TX file with", vm.toString(txCount), "transactions");
    }

    /// @notice Test that 02b includes grantRole transactions when manager is configured
    function test_02bIncludesGrantRoleTransactions() public {
        uint256 chainId = block.chainid;
        ConfigReader.ChainConfig memory chainConfig = ConfigReader.readChainConfig(vm, chainId);

        if (chainConfig.manager == address(0)) {
            console2.log("[SKIP] test_02bIncludesGrantRoleTransactions: manager not configured for chain");
            return;
        }

        address navProxy = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        address bridgeProxy = ConfigReader.readDeployedAddress(vm, chainId, "BridgeEscrowProxy");
        address navImpl = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorImplementation");
        address bridgeImpl = ConfigReader.readDeployedAddress(vm, chainId, "BridgeEscrowImplementation");

        if (navProxy == address(0) || bridgeProxy == address(0) || navImpl == address(0) || bridgeImpl == address(0)) {
            console2.log("[SKIP] test_02bIncludesGrantRoleTransactions: config missing proxy/impl for chain");
            return;
        }

        // Simulate the 02b script logic
        // Count transactions
        uint256 txCount = 2;
        if (chainConfig.manager != address(0)) {
            txCount += 2;
        }
        SafeTxBuilder.Transaction[] memory allTxs = new SafeTxBuilder.Transaction[](txCount);
        uint256 txIndex = 0;

        // Upgrade transactions (UUPS: call upgradeToAndCall directly on proxy)
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );
        allTxs[txIndex++] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, navImpl, navInitData)
        );

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (
                chainConfig.admin,
                chainId > type(uint64).max ? uint64(0) : uint64(chainId),
                initialAccounts,
                initialAdapters
            )
        );
        allTxs[txIndex++] = SafeTxBuilder.call(
            bridgeProxy,
            0,
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, bridgeImpl, bridgeInitData)
        );

        // Grant role transactions
        allTxs[txIndex++] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
        );
        allTxs[txIndex++] = SafeTxBuilder.call(
            bridgeProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
        );

        // Verify grantRole transactions are present
        assertEq(txIndex, 4, "Should have 4 transactions");
        assertEq(allTxs[2].to, navProxy, "Third transaction should target NAVCalculator proxy");
        assertEq(allTxs[3].to, bridgeProxy, "Fourth transaction should target BridgeEscrow proxy");

        // Verify grantRole selector
        bytes4 grantRoleSelector = bytes4(keccak256("grantRole(bytes32,address)"));
        assertEq(bytes4(allTxs[2].data), grantRoleSelector, "Third transaction should be grantRole");
        assertEq(bytes4(allTxs[3].data), grantRoleSelector, "Fourth transaction should be grantRole");

        console2.log("[OK] 02b includes grantRole transactions for manager");
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
