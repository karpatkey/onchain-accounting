// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
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

        console2.log("");
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
        bytes32 salt = keccak256(abi.encodePacked("ProxyPlaceholderImpl", uint256(1)));
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
