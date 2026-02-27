// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
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
        string[9] memory names = [
            "AaveV3_USDC",
            "AaveV3_WETH",
            "CompoundV3_USDC",
            "CompoundV3_WETH",
            "SparkLend_USDC",
            "MorphoBlue_USDC",
            "DaiDsr",
            "SkySavingsUsds",
            "ERC20Default"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            address a = _readAdapterDeployed("balanceAdapters", names[i]);
            if (a == address(0)) continue;
            (string memory path, bytes memory args) = _balanceAdapterPathAndArgs(names[i], nav);
            if (bytes(path).length == 0) continue; // skip unsupported or missing config
            _emitVerify(string(abi.encodePacked("balanceAdapters.", names[i])), a, path, _toHex(args));
        }
    }

    /// @dev Returns (contractPath, ABI-encoded constructor args). path empty if adapter type unknown or config missing.
    function _balanceAdapterPathAndArgs(string memory name, address navCalculator)
        internal
        view
        returns (string memory path, bytes memory args)
    {
        if (_startsWith(name, "AaveV3_")) {
            path = "src/balances/protocols/AaveV3Instance.sol:AaveV3InstanceBalanceOracle";
            address dataProvider = _parseAddr("balanceAdapters", name, "dataProvider", address(0));
            address rewardsDistributor = _parseAddr("balanceAdapters", name, "rewardsDistributor", address(0));
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            address nav = _navOrDefault(navCalculator, name);
            if (dataProvider == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(dataProvider, rewardsDistributor, protocol, nav);
            return (path, args);
        }
        if (_startsWith(name, "CompoundV3_")) {
            path = "src/balances/protocols/CompoundV3Comet.sol:CompoundV3Comet";
            address compoundRewards = _parseAddr("balanceAdapters", name, "compoundRewards", address(0));
            address comet = _parseAddr("balanceAdapters", name, "comet", address(0));
            address rewardToken = _parseAddr("balanceAdapters", name, "rewardToken", address(0));
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            address nav = _navOrDefault(navCalculator, name);
            if (compoundRewards == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(compoundRewards, comet, rewardToken, protocol, nav);
            return (path, args);
        }
        if (_startsWith(name, "SparkLend_")) {
            path = "src/balances/protocols/SparkLend.sol:SparkLendBalanceOracle";
            address dataProvider = _parseAddr("balanceAdapters", name, "dataProvider", address(0));
            address rewardsDistributor = _parseAddr("balanceAdapters", name, "rewardsDistributor", address(0));
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            address nav = _navOrDefault(navCalculator, name);
            if (dataProvider == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(dataProvider, rewardsDistributor, protocol, nav);
            return (path, args);
        }
        if (_startsWith(name, "MorphoBlue_")) {
            path = "src/balances/protocols/MorphoMarket.sol:MorphoMarketBalanceOracle";
            address morpho = _parseAddr("balanceAdapters", name, "morpho", address(0));
            string memory marketIdStr = _readParam("balanceAdapters", name, "marketId");
            bytes32 marketId = bytes(marketIdStr).length == 0 ? bytes32(0) : vm.parseBytes32(marketIdStr);
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            address nav = _navOrDefault(navCalculator, name);
            if (morpho == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(morpho, marketId, protocol, nav);
            return (path, args);
        }
        if (_equals(name, "DaiDsr")) {
            path = "src/balances/protocols/DaiDsr.sol:DaiDsrBalanceOracle";
            address dai = _parseAddr("balanceAdapters", name, "dai", address(0));
            address dsrManager = _parseAddr("balanceAdapters", name, "dsrManager", address(0));
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            string memory positionDetail = _readParam("balanceAdapters", name, "positionDetail");
            address nav = _navOrDefault(navCalculator, name);
            if (dai == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(dai, dsrManager, protocol, positionDetail, nav);
            return (path, args);
        }
        if (_equals(name, "SkySavingsUsds")) {
            path = "src/balances/protocols/SkySavingsUsds.sol:SkySavingsUsdsBalanceOracle";
            address savingsUsds = _parseAddr("balanceAdapters", name, "savingsUsds", address(0));
            string memory protocol = _readParam("balanceAdapters", name, "protocol");
            string memory positionDetail = _readParam("balanceAdapters", name, "positionDetail");
            address nav = _navOrDefault(navCalculator, name);
            if (savingsUsds == address(0) || nav == address(0)) return ("", "");
            args = abi.encode(savingsUsds, protocol, positionDetail, nav);
            return (path, args);
        }
        if (_equals(name, "ERC20Default") || _startsWith(name, "ERC20Default_")) {
            path = "src/balances/protocols/ERC20DefaultOracle.sol:ERC20DefaultOracle";
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
        string memory s = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, "deployed");
        if (bytes(s).length == 0) return address(0);
        address a = vm.parseAddress(s);
        return a;
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
        bytes32 salt = keccak256(abi.encodePacked("ProxyPlaceholderImpl", uint256(2)));
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
