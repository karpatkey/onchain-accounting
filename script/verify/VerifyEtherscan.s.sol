// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {DeploySalts} from "../deploy/DeploySalts.sol";
import {console2} from "forge-std/console2.sol";

/// @title VerifyEtherscan
/// @notice Verifies deployed contracts on block explorers (Etherscan, Arbiscan, etc.)
/// @dev Run per chain; use script/verify/verify-all.sh to check and submit for all chains.
contract VerifyEtherscan is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();

        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeImpl = readDeployedAddress("BridgeEscrowImplementation");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");

        // Proxy constructor at deploy (02a) is (placeholder, ""). Same on all chains (UUPS pattern, no owner needed).
        address placeholder = _placeholderAddress();
        bytes memory proxyConstructorArgs = abi.encode(placeholder, "");

        console2.log("\n=== Verification (chain %s) ===", vm.toString(currentChainId));

        _emitVerify("NAVCalculatorImplementation", navImpl, "src/nav/NAVCalculator.sol:NAVCalculator", "");
        _emitVerify(
            "NAVCalculatorProxy", navProxy, "src/proxy/UUPSProxy.sol:UUPSProxy", vm.toString(proxyConstructorArgs)
        );
        _emitVerify("BridgeEscrowImplementation", bridgeImpl, "src/bridge/BridgeEscrow.sol:BridgeEscrow", "");
        _emitVerify(
            "BridgeEscrowProxy", bridgeProxy, "src/proxy/UUPSProxy.sol:UUPSProxy", vm.toString(proxyConstructorArgs)
        );

        _emitVerifyBridgeAdapters();
        _emitVerifyBalanceAdapters();

        console2.log("");
    }

    function _emitVerifyBridgeAdapters() internal view {
        string[5] memory names = ["CCIP", "Across", "Stargate", "CCTP", "Superchain"];
        string[5] memory paths = [
            "src/bridge/adapters/CcipBridgeAdapter.sol:CcipBridgeAdapter",
            "src/bridge/adapters/AcrossBridgeAdapter.sol:AcrossBridgeAdapter",
            "src/bridge/adapters/StargateBridgeAdapter.sol:StargateBridgeAdapter",
            "src/bridge/adapters/CctpBridgeAdapter.sol:CctpBridgeAdapter",
            "src/bridge/adapters/SuperchainBridgeAdapter.sol:SuperchainBridgeAdapter"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            address a = _readAdapterDeployed("bridgeAdapters", names[i]);
            if (a != address(0)) {
                _emitVerify(string(abi.encodePacked("bridgeAdapters.", names[i])), a, paths[i], "0x");
            }
        }
    }

    function _emitVerifyBalanceAdapters() internal view {
        address nav = readDeployedAddress("NAVCalculatorProxy");
        // Drive the list from the deploy config (whatever 04 actually deploys) rather than a hardcoded list that
        // drifts as adapters change. `_balanceAdapterPathAndArgs` still only knows how to build constructor args for
        // the adapter types it has been taught; for any deployed adapter it can't (e.g. meta-adapters), emit a loud
        // notice with the address so the operator verifies it manually instead of it being silently omitted.
        string[] memory names = ConfigReader.getEnabledAdapters(vm, currentChainId, "deployBalanceAdapters");
        for (uint256 i = 0; i < names.length; i++) {
            address a = _readAdapterDeployed("balanceAdapters", names[i]);
            if (a == address(0)) continue; // not deployed (yet)
            (string memory path, bytes memory args) = _balanceAdapterPathAndArgs(names[i], nav);
            if (bytes(path).length == 0) {
                console2.log("[verify] no constructor-args mapping; verify manually:", names[i], a);
                continue;
            }
            _emitVerify(string(abi.encodePacked("balanceAdapters.", names[i])), a, path, _toHex(args));
        }
    }

    /// @dev Returns (contractPath, ABI-encoded constructor args). path empty if adapter type unknown or config missing.
    function _balanceAdapterPathAndArgs(string memory name, address navCalculator)
        internal
        view
        returns (string memory path, bytes memory args)
    {
        // AaveV3, CompoundV3 and Morpho are meta-adapters (AaveV3InstancesMeta / CompoundV3CometsMeta /
        // MorphoMarketsMeta). Their per-instance keys (AaveV3_*, CompoundV3_*, MorphoBlue_*) are NAV instance
        // coordinates, not standalone deployments, and the metas deploy under their own names — so they
        // intentionally fall through to the "verify manually" notice (§8.1) rather than being built here. Only
        // adapters with a 1:1 deploy-to-constructor mapping get an args builder below.
        if (_equals(name, "SparkLend") || _startsWith(name, "SparkLend_")) {
            path = "src/balances/protocols/SparkLendBalanceAdapter.sol:SparkLendBalanceAdapter";
            address dataProvider = _parseAddr("balanceAdapters", name, "dataProvider", address(0));
            address nav = _navOrDefault(navCalculator, name);
            if (dataProvider == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(dataProvider, nav); // SparkLendBalanceAdapter(dataProvider, navCalculator)
            return (path, args);
        }
        if (_equals(name, "ERC20Default") || _startsWith(name, "ERC20Default_")) {
            path = "src/balances/protocols/ERC20DefaultBalanceAdapter.sol:ERC20DefaultBalanceAdapter";
            address nav = _navOrDefault(navCalculator, name);
            if (nav == address(0)) return ("", "");
            address[] memory initialAssets = new address[](0);
            args = abi.encode(nav, initialAssets);
            return (path, args);
        }
        return ("", "");
    }

    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, adapterType, adapterName);
    }

    function _parseAddr(
        string memory adapterType,
        string memory adapterName,
        string memory paramName,
        address fallback_
    ) internal view returns (address) {
        string memory s = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, paramName);
        if (bytes(s).length == 0) return fallback_;
        return vm.parseAddress(s);
    }

    function _readParam(string memory adapterType, string memory adapterName, string memory paramName)
        internal
        view
        returns (string memory)
    {
        return ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, paramName);
    }

    function _readParamDefault(
        string memory adapterType,
        string memory adapterName,
        string memory paramName,
        string memory defaultVal
    ) internal view returns (string memory) {
        string memory s = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, paramName);
        return bytes(s).length == 0 ? defaultVal : s;
    }

    function _navOrDefault(address navCalculator, string memory) internal view returns (address) {
        if (navCalculator != address(0)) return navCalculator;
        return readDeployedAddress("NAVCalculatorProxy");
    }

    function _toHex(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "0x";
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            out[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            out[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > strBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev One line per contract for verify-all.sh: chainId | name | address | contractPath | constructorArgsHex
    function _emitVerify(string memory name, address addr, string memory contractPath, string memory constructorArgsHex)
        internal
        view
    {
        if (addr == address(0)) return;
        string memory args = bytes(constructorArgsHex).length > 0 ? constructorArgsHex : "0x";
        console2.log(
            string(
                abi.encodePacked(
                    "VERIFY|",
                    vm.toString(currentChainId),
                    "|",
                    name,
                    "|",
                    vm.toString(addr),
                    "|",
                    contractPath,
                    "|",
                    args
                )
            )
        );
    }

    function _placeholderAddress() internal pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL));
        bytes memory creationCode = type(UUPSPlaceholder).creationCode;
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(creationCode)))
                )
            )
        );
    }
}
