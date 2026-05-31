// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "../../src/prices/PriceFeedLib.sol";
import {NavRegistryLib} from "../../src/nav/NavRegistryLib.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployNAVImplementation
/// @notice Deploys PriceFeedLib (external library) then NAVCalculator implementation. Safe JSON and/or EOA broadcast.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run without --broadcast: generates safe-transactions/{chainId}-deploy-nav-implementation.json.
///      Run with --broadcast --account $DEPLOYER_NAME: deploys via EOA (skips if already deployed), then saves address.
///      Same implementation address on all chains — run once, then run 02_2_DeployNAVProxy.s.sol per chain.
///      PriceFeedLib must be deployed before NAVCalculator because NAVCalculator's bytecode references it
///      via DELEGATECALL. Both transactions are included in the Safe batch so the batch is self-contained.
contract DeployNAVImplementation is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct ImplPlan {
        address priceFeedLib;
        bytes priceFeedLibBytecode;
        bytes32 saltPriceFeedLib;
        address navRegistryLib;
        bytes navRegistryLibBytecode;
        bytes32 saltNavRegistryLib;
        address navImpl;
        bytes navImplBytecode;
        bytes32 saltNavImpl;
    }

    function run() public override {
        setUp();
        validateAddresses();

        ImplPlan memory plan = _computeImplPlan();

        SafeTxBuilder.Transaction[] memory txs = new SafeTxBuilder.Transaction[](3);
        txs[0] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltPriceFeedLib, plan.priceFeedLibBytecode)
        );
        txs[1] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltNavRegistryLib, plan.navRegistryLibBytecode)
        );
        txs[2] =
            SafeTxBuilder.call(CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));

        string memory filename =
            string(abi.encodePacked(vm.toString(currentChainId), "-deploy-nav-implementation.json"));
        writeSafeTx(
            filename,
            "Deploy PriceFeedLib + NavRegistryLib + NAVCalculator implementation (CREATE2)",
            "Deploy the PriceFeedLib and NavRegistryLib external libraries then the NAVCalculator implementation via the canonical CREATE2 deployer. All at the same address on all chains. Run once, then run 02_2_DeployNAVProxy.s.sol per chain.",
            txs
        );

        vm.startBroadcast();
        _deployIfNeeded(plan);
        vm.stopBroadcast();

        _saveAndLog(plan, filename);
    }

    function _computeImplPlan() internal pure returns (ImplPlan memory plan) {
        plan.saltPriceFeedLib = generateSalt("PriceFeedLib", 1);
        plan.priceFeedLibBytecode = type(PriceFeedLib).creationCode;
        plan.priceFeedLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltPriceFeedLib, plan.priceFeedLibBytecode);

        // NOTE: NavRegistryLib is DELEGATECALL'd by NAVCalculator during initialize() (registerAsset), so the
        // address NAVCalculator is linked against (the foundry.toml `libraries` pin) MUST equal the CREATE2 address
        // computed here, or NAV init reverts on-chain. Same requirement as PriceFeedLib. Before signing the Safe
        // batch, confirm `plan.navRegistryLib` (logged below) matches the foundry.toml pin; if they diverge (e.g.
        // after a library source change shifts the bytecode), update the pin and rebuild so the link is consistent.
        plan.saltNavRegistryLib = generateSalt("NavRegistryLib", 1);
        plan.navRegistryLibBytecode = type(NavRegistryLib).creationCode;
        plan.navRegistryLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavRegistryLib, plan.navRegistryLibBytecode);

        plan.saltNavImpl = generateSalt("NAVCalculatorImplementation", 2);
        plan.navImplBytecode = type(NAVCalculator).creationCode;
        plan.navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavImpl, plan.navImplBytecode);
    }

    function _deployIfNeeded(ImplPlan memory plan) internal {
        if (plan.priceFeedLib.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltPriceFeedLib, plan.priceFeedLibBytecode));
            require(ok, "PriceFeedLib deploy failed");
            console2.log("[OK] PriceFeedLib deployed at:", plan.priceFeedLib);
        } else {
            console2.log("[SKIP] PriceFeedLib already at:", plan.priceFeedLib);
        }

        if (plan.navRegistryLib.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavRegistryLib, plan.navRegistryLibBytecode));
            require(ok, "NavRegistryLib deploy failed");
            console2.log("[OK] NavRegistryLib deployed at:", plan.navRegistryLib);
        } else {
            console2.log("[SKIP] NavRegistryLib already at:", plan.navRegistryLib);
        }

        if (plan.navImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));
            require(ok, "NAV impl deploy failed");
            console2.log("[OK] NAV implementation deployed at:", plan.navImpl);
        } else {
            console2.log("[SKIP] NAV implementation already at:", plan.navImpl);
        }
    }

    function _saveAndLog(ImplPlan memory plan, string memory filename) internal {
        saveDeployedAddress("PriceFeedLib", plan.priceFeedLib);
        saveDeployedAddress("NavRegistryLib", plan.navRegistryLib);
        saveDeployedAddress("NAVCalculatorImplementation", plan.navImpl);

        console2.log("\n=== NAV Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Generated:", filename);
        console2.log("  PriceFeedLib:", plan.priceFeedLib);
        console2.log("  NavRegistryLib:", plan.navRegistryLib);
        console2.log("  NAV Implementation:", plan.navImpl);
        console2.log("Addresses saved to config. Run 02_2_DeployNAVProxy.s.sol per chain.");
    }
}
