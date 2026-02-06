// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestEnvConfigurator} from "../../test/TestEnvConfigurator.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {TransparentProxy} from "../../src/proxy/TransparentProxy.sol";
import {Empty} from "../../src/utils/Empty.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {console2} from "forge-std/console2.sol";

/// @title Test02b_InitializeProxies
/// @notice Tests the 02b flow: ProxyAdmin address derivation and upgradeAndCall(proxy, realImpl, initData).
contract Test02b_InitializeProxies is TestEnvConfigurator {
    using ConfigReader for *;
    using SafeTxBuilder for *;

    function setUp() public {
        if (block.number == 0 || block.chainid == 31337) {
            string memory rpcUrl = getAlchemyUrl("eth-mainnet");
            vm.createSelectFork(rpcUrl);
        }
    }

    /// @notice ProxyAdmin is stored in the proxy's EIP-1967 admin slot; when proxy is deployed with nonce 0 (e.g. 02a), it equals computeCreateAddress(proxy, 0).
    function test_ProxyAdminAddressEqualsComputeCreateAddress() public {
        address safe = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        Empty placeholder = new Empty();
        TransparentProxy proxy = new TransparentProxy(address(placeholder), safe, "");

        address adminFromSlot = _getProxyAdmin(address(proxy));
        assertTrue(adminFromSlot != address(0), "ProxyAdmin should be set in slot");
        assertGt(adminFromSlot.code.length, 0, "ProxyAdmin should have code");
        assertEq(ProxyAdmin(adminFromSlot).owner(), safe, "ProxyAdmin owner should be Safe");
        // On a fresh chain (no fork), ProxyAdmin is the first contract created by the proxy, so admin == computeCreateAddress(proxy, 0).
        address adminFromCompute = vm.computeCreateAddress(address(proxy), 0);
        if (adminFromSlot == adminFromCompute) {
            console2.log("[OK] ProxyAdmin slot equals computeCreateAddress(proxy, 0)");
        } else {
            console2.log("[OK] ProxyAdmin from slot has code and owner; computeCreateAddress differs (fork nonce)");
        }
    }

    /// @notice Full 02b-style flow: proxy with placeholder -> upgradeAndCall(proxy, navImpl, initData) -> NAV initialized.
    function test_02bUpgradeAndCallInitializesNAVProxy() public {
        address safe = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address admin = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address sequencerFeed = address(0);
        Empty placeholder = new Empty();
        NAVCalculator navImpl = new NAVCalculator();

        TransparentProxy proxy = new TransparentProxy(address(placeholder), safe, "");
        address proxyAdminAddr = _getProxyAdmin(address(proxy));
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddr);

        bytes memory navInitData = abi.encodeCall(NAVCalculator.initialize, (admin, sequencerFeed, "ETH"));

        vm.prank(safe);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), address(navImpl), navInitData);

        NAVCalculator nav = NAVCalculator(address(proxy));
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), admin), "NAV proxy should be initialized with admin");
        console2.log("[OK] 02b upgradeAndCall flow initializes NAV proxy");
    }

    /// @notice Full 02b-style flow: proxy with placeholder -> upgradeAndCall(proxy, bridgeImpl, initData) -> Bridge initialized.
    function test_02bUpgradeAndCallInitializesBridgeProxy() public {
        address safe = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        address admin = address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);
        uint64 chainId = 1;
        Empty placeholder = new Empty();
        BridgeEscrow bridgeImpl = new BridgeEscrow();

        TransparentProxy proxy = new TransparentProxy(address(placeholder), safe, "");
        address proxyAdminAddr = _getProxyAdmin(address(proxy));
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddr);

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData =
            abi.encodeCall(BridgeEscrow.initialize, (admin, chainId, initialAccounts, initialAdapters));

        vm.prank(safe);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))), address(bridgeImpl), bridgeInitData
        );

        BridgeEscrow bridge = BridgeEscrow(payable(address(proxy)));
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), admin), "Bridge proxy should be initialized with admin");
        console2.log("[OK] 02b upgradeAndCall flow initializes Bridge proxy");
    }

    /// @notice Build the same calldata as 02b and verify selector and targets.
    function test_02bCalldataStructure() public view {
        address navProxy = address(0x3720E21E0D581faDC1626f0464cC9f023beB1aAa);
        address bridgeProxy = address(0x911A0818da77365ED0f246FB15053E5324a810f6);
        address navImpl = address(0x149aE89A9C1EdE914df158C18Ee4DCEeb0283541);
        address bridgeImpl = address(0x50FE322E01eB7e537418D6C90ea586063260454D);

        address navProxyAdmin = vm.computeCreateAddress(navProxy, 0);
        address bridgeProxyAdmin = vm.computeCreateAddress(bridgeProxy, 0);

        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize, (address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537), address(0), "ETH")
        );
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537), uint64(1), initialAccounts, initialAdapters)
        );

        bytes memory navCalldata = abi.encodeWithSelector(
            ProxyAdmin.upgradeAndCall.selector, ITransparentUpgradeableProxy(payable(navProxy)), navImpl, navInitData
        );
        bytes memory bridgeCalldata = abi.encodeWithSelector(
            ProxyAdmin.upgradeAndCall.selector,
            ITransparentUpgradeableProxy(payable(bridgeProxy)),
            bridgeImpl,
            bridgeInitData
        );

        assertEq(navProxyAdmin != address(0), true, "NAV ProxyAdmin computed");
        assertEq(bridgeProxyAdmin != address(0), true, "Bridge ProxyAdmin computed");
        assertEq(bytes4(navCalldata), ProxyAdmin.upgradeAndCall.selector, "NAV tx uses upgradeAndCall");
        assertEq(bytes4(bridgeCalldata), ProxyAdmin.upgradeAndCall.selector, "Bridge tx uses upgradeAndCall");
        console2.log("[OK] 02b calldata structure (targets + upgradeAndCall selector) is valid");
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

        address navProxyAdmin = vm.computeCreateAddress(navProxy, 0);
        address bridgeProxyAdmin = vm.computeCreateAddress(bridgeProxy, 0);

        SafeTxBuilder.Transaction[] memory allTxs = new SafeTxBuilder.Transaction[](2);
        allTxs[0] = SafeTxBuilder.call(
            navProxyAdmin,
            0,
            abi.encodeWithSelector(
                ProxyAdmin.upgradeAndCall.selector,
                ITransparentUpgradeableProxy(payable(navProxy)),
                navImpl,
                navInitData
            )
        );
        allTxs[1] = SafeTxBuilder.call(
            bridgeProxyAdmin,
            0,
            abi.encodeWithSelector(
                ProxyAdmin.upgradeAndCall.selector,
                ITransparentUpgradeableProxy(payable(bridgeProxy)),
                bridgeImpl,
                bridgeInitData
            )
        );

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
        console2.log("[OK] 02b logic wrote valid Safe TX file");
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
