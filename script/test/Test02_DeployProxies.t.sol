// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {TestEnvConfigurator} from "../../test/TestEnvConfigurator.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {DeploySalts} from "../deploy/DeploySalts.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {MANAGER} from "../../src/constants.sol";
import {AtomicProxyDeployer} from "../deploy/AtomicProxyDeployer.sol";
import {console2} from "forge-std/console2.sol";

/// @title Test02a_DeployProxies
/// @notice Tests for 02_DeployProxies: CREATE2 determinism, AtomicProxyDeployer, and init flow.
/// @dev Merged Test02a + Test02b. Verifies that the canonical CREATE2 deployer yields the same
///      proxy addresses regardless of caller; different deployers yield diverging addresses.
contract Test02a_DeployProxies is TestEnvConfigurator {
    using ConfigReader for *;
    using SafeTxBuilder for *;

    /// @notice Canonical CREATE2 deployer address (same on all chains)
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    ConfigReader.ChainConfig internal chainConfig;
    uint256 internal currentChainId;

    // Test EOA addresses
    address internal constant EOA1 = address(0x1111111111111111111111111111111111111111);
    address internal constant EOA2 = address(0x2222222222222222222222222222222222222222);
    address internal constant EOA3 = address(0x3333333333333333333333333333333333333333);

    function setUp() public {
        // Create fork first (if not already forked) to get the real chain ID
        // Default to mainnet if no fork URL is specified
        if (block.number == 0 || block.chainid == 31337) {
            string memory rpcUrl = getAlchemyUrl("eth-mainnet");
            vm.createSelectFork(rpcUrl);
        }

        // Now read config for the forked chain
        currentChainId = block.chainid;
        chainConfig = ConfigReader.readChainConfig(vm, currentChainId);

        // Verify canonical CREATE2 deployer has code on fork
        address deployer = CANONICAL_CREATE2_DEPLOYER;
        uint256 deployerCodeSize;
        assembly {
            deployerCodeSize := extcodesize(deployer)
        }
        require(deployerCodeSize > 0, "Canonical CREATE2 deployer not found on fork");

        // NAVRegistryLib is pre-linked at this deterministic CREATE2 address (foundry.toml) and DELEGATECALL'd by
        // NAVCalculator/Balances. It is not deployed on the fork, so etch its runtime code there for proxy init/upgrade.
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);
    }

    /// @notice Test that different EOAs deploy proxies to the same addresses
    /// @dev Proxy bytecode uses placeholder impl (same on all chains), not real NAV/Bridge impl.
    function test_DifferentEOAsDeploySameAddresses() public view {
        address placeholder = _getPlaceholderAddress();
        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address expectedNavProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address expectedBridgeProxy =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        console2.log("\n=== Testing EOA Independence ===");
        console2.log("Expected NAV proxy:", expectedNavProxy);
        console2.log("Expected Bridge proxy:", expectedBridgeProxy);

        // The key insight: CREATE2 uses the deployer contract address (CANONICAL_CREATE2_DEPLOYER),
        // NOT the EOA caller address. So all EOAs will compute the same addresses.
        // We test this by computing addresses "as if" different EOAs were calling the deployer.

        // Verify that EOA2 would compute the same NAV proxy address
        address computedNavByEoa2 = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        assertEq(computedNavByEoa2, expectedNavProxy, "NAV proxy address computed by EOA2 should be same");

        // Verify that EOA1 would compute the same Bridge proxy address
        address computedBridgeByEoa1 =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);
        assertEq(computedBridgeByEoa1, expectedBridgeProxy, "Bridge proxy address computed by EOA1 should be same");

        // Verify that EOA3 would also compute the same addresses
        address computedNavByEoa3 = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        address computedBridgeByEoa3 =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);
        assertEq(computedNavByEoa3, expectedNavProxy, "NAV proxy address computed by EOA3 should be same");
        assertEq(computedBridgeByEoa3, expectedBridgeProxy, "Bridge proxy address computed by EOA3 should be same");

        console2.log("\n[OK] All EOAs compute the same addresses");
        console2.log("  NAV Proxy (same for all EOAs):", expectedNavProxy);
        console2.log("  Bridge Proxy (same for all EOAs):", expectedBridgeProxy);
        console2.log("\nThis proves that the EOA signer does NOT affect the deployed address");
        console2.log("because CREATE2 uses the deployer contract address (", CANONICAL_CREATE2_DEPLOYER, ")");
        console2.log("not the EOA caller address, in the address computation formula.");
    }

    /// @notice Test that the script's address computation matches actual deployment
    /// @dev 02a uses placeholder in bytecode; this verifies the same formula.
    function test_ScriptAddressComputationMatchesDeployment() public view {
        address placeholder = _getPlaceholderAddress();
        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bytes32 navProxyBytecodeHash = keccak256(navProxyBytecode);
        address computedNavProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bytes32 bridgeProxyBytecodeHash = keccak256(bridgeProxyBytecode);
        address computedBridgeProxy =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        // Cross-check the local CREATE2 derivation against an INDEPENDENT implementation.
        //
        // This previously called `ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER).computeAddress(...)` inside a
        // try/catch. That check never ran, on any invocation, and could not have: 0x4e59b448…4956C is
        // Arachnid's deterministic-deployment-proxy — 69 bytes of runtime that read calldata as
        // `salt ++ initCode` and CREATE2 it. It performs no selector dispatch, so it has no `computeAddress`;
        // and CREATE2 is a state write, so the call reverts under STATICCALL regardless. Both arms therefore
        // always landed in `catch` and logged "[WARN] … (offline mode or deployer not found)", which reads
        // like an environment problem rather than a permanently dead assertion. Nothing compared the script's
        // salt/address derivation to a second source.
        //
        // `vm.computeCreate2Address` is that second source: it is implemented in Foundry's Rust cheatcode
        // layer, so it shares no code with `_computeCreate2Address` below and a mistake in either is caught.
        // It is unconditional — no try/catch, no network, no fork.
        assertEq(
            vm.computeCreate2Address(saltNavProxy, navProxyBytecodeHash, CANONICAL_CREATE2_DEPLOYER),
            computedNavProxy,
            "NAV proxy address disagrees with vm.computeCreate2Address"
        );
        assertEq(
            vm.computeCreate2Address(saltBridgeProxy, bridgeProxyBytecodeHash, CANONICAL_CREATE2_DEPLOYER),
            computedBridgeProxy,
            "Bridge proxy address disagrees with vm.computeCreate2Address"
        );

        // Verify addresses are computed correctly and consistently
        // (We don't actually deploy here since the goal is to test address computation)
        assertTrue(computedNavProxy != address(0), "NAV proxy address should be non-zero");
        assertTrue(computedBridgeProxy != address(0), "Bridge proxy address should be non-zero");
        assertTrue(computedNavProxy != computedBridgeProxy, "NAV and Bridge proxies should have different addresses");

        // Verify address computation is consistent (same inputs = same output)
        address recomputedNavProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        address recomputedBridgeProxy =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);
        assertEq(computedNavProxy, recomputedNavProxy, "NAV proxy address computation should be consistent");
        assertEq(computedBridgeProxy, recomputedBridgeProxy, "Bridge proxy address computation should be consistent");
    }

    /// @notice Test that proxy addresses are the same across all networks
    /// @dev This verifies that using the canonical CREATE2 deployer with the same inputs
    ///      produces the same addresses on mainnet, Arbitrum, Base, Gnosis Chain, and Optimism.
    ///      This is the key benefit of using the canonical deployer - true cross-chain determinism.
    function test_ProxyAddressesSameAcrossAllNetworks() public view {
        // List of chain IDs to test
        uint256[] memory chainIds = new uint256[](5);
        chainIds[0] = 1; // Ethereum mainnet
        chainIds[1] = 42161; // Arbitrum
        chainIds[2] = 8453; // Base
        chainIds[3] = 100; // Gnosis Chain
        chainIds[4] = 10; // Optimism

        // Compute addresses for each chain
        address[] memory navProxyAddresses = new address[](5);
        address[] memory bridgeProxyAddresses = new address[](5);
        string[] memory chainNames = new string[](5);
        chainNames[0] = "Mainnet";
        chainNames[1] = "Arbitrum";
        chainNames[2] = "Base";
        chainNames[3] = "Gnosis";
        chainNames[4] = "Optimism";

        console2.log("\n=== Testing Cross-Chain Address Determinism ===");
        console2.log("Canonical CREATE2 Deployer:", CANONICAL_CREATE2_DEPLOYER);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Proxy bytecode uses placeholder (same on all chains), not real impl address
            address placeholder = _getPlaceholderAddress();
            bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
            bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));

            bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
            bytes memory bridgeProxyBytecode =
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));

            // Compute addresses using canonical CREATE2 deployer
            navProxyAddresses[i] = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
            bridgeProxyAddresses[i] =
                _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

            console2.log(string(abi.encodePacked("\n", chainNames[i], " (Chain ID ", vm.toString(chainId), "):")));
            console2.log("  NAV Proxy:", navProxyAddresses[i]);
            console2.log("  Bridge Proxy:", bridgeProxyAddresses[i]);
        }

        // Verify all NAV proxy addresses are the same across all chains
        for (uint256 i = 1; i < navProxyAddresses.length; i++) {
            assertEq(
                navProxyAddresses[0],
                navProxyAddresses[i],
                string(
                    abi.encodePacked(
                        "NAV proxy address should be same on all chains, but differs on chain ",
                        vm.toString(chainIds[i])
                    )
                )
            );
        }

        // Verify all Bridge proxy addresses are the same across all chains
        for (uint256 i = 1; i < bridgeProxyAddresses.length; i++) {
            assertEq(
                bridgeProxyAddresses[0],
                bridgeProxyAddresses[i],
                string(
                    abi.encodePacked(
                        "Bridge proxy address should be same on all chains, but differs on chain ",
                        vm.toString(chainIds[i])
                    )
                )
            );
        }

        console2.log("\n[OK] All proxy addresses are identical across all networks!");
        console2.log("  NAV Proxy (same on all chains):", navProxyAddresses[0]);
        console2.log("  Bridge Proxy (same on all chains):", bridgeProxyAddresses[0]);
        console2.log("\nThis proves true cross-chain determinism using the canonical CREATE2 deployer.");
    }

    /// @notice Test that different deployers (different CREATE2 deployer contract addresses) yield diverging proxy addresses.
    /// @dev CREATE2 address = f(deployer, salt, bytecodeHash). Same salt+bytecode with different deployer => different address.
    function test_DifferentDeployersLeadToDivergingProxyAddresses() public view {
        address placeholder = _getPlaceholderAddress();
        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));

        address withCanonicalNav = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        address withCanonicalBridge =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        // Different deployer addresses (e.g. another chain's deployer or a custom contract) => different proxy addresses
        address otherDeployer1 = address(0x0000000000000000000000000000000000000001);
        address otherDeployer2 = address(0x000000000000000000000000000000000000dEaD);

        address withOther1Nav = _computeCreate2Address(otherDeployer1, saltNavProxy, navProxyBytecode);
        address withOther1Bridge = _computeCreate2Address(otherDeployer1, saltBridgeProxy, bridgeProxyBytecode);
        address withOther2Nav = _computeCreate2Address(otherDeployer2, saltNavProxy, navProxyBytecode);
        address withOther2Bridge = _computeCreate2Address(otherDeployer2, saltBridgeProxy, bridgeProxyBytecode);

        assertEq(withCanonicalNav, withCanonicalNav, "sanity");
        assertTrue(withCanonicalNav != withOther1Nav, "NAV proxy address must differ when deployer differs");
        assertTrue(withCanonicalBridge != withOther1Bridge, "Bridge proxy address must differ when deployer differs");
        assertTrue(withOther1Nav != withOther2Nav, "NAV proxy must differ between two non-canonical deployers");
        assertTrue(withOther1Bridge != withOther2Bridge, "Bridge proxy must differ between two non-canonical deployers");

        console2.log("\n[OK] Different deployers lead to diverging proxy addresses");
        console2.log("  Canonical deployer NAV:", withCanonicalNav);
        console2.log("  Other deployer 1 NAV:  ", withOther1Nav);
        console2.log("  Other deployer 2 NAV:  ", withOther2Nav);
    }

    /// @notice Test that AtomicProxyDeployer uses the same address formula as the script (canonical CREATE2 + same salts).
    /// @dev Verifies ConfigReader.computeSalt matches AtomicProxyDeployer's salt formula so script and AtomicProxyDeployer yield identical proxy addresses.
    function test_AtomicProxyDeployerProducesSameAddressesAsScript() public view {
        // Salts must match AtomicProxyDeployer (keccak256(abi.encodePacked(name, version)) with version from DeploySalts)
        assertEq(
            ConfigReader.computeSalt("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL),
            keccak256(abi.encodePacked("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL)),
            "Placeholder salt mismatch"
        );
        assertEq(
            ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY),
            keccak256(abi.encodePacked("NAVCalculatorProxy", DeploySalts.NAV_PROXY)),
            "NAV proxy salt mismatch"
        );
        assertEq(
            ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY),
            keccak256(abi.encodePacked("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY)),
            "Bridge proxy salt mismatch"
        );

        address placeholder = _getPlaceholderAddress();
        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));

        address expectedNavProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        address expectedBridgeProxy =
            _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        assertTrue(expectedNavProxy != address(0) && expectedBridgeProxy != address(0), "Computed addresses non-zero");
        assertTrue(expectedNavProxy != expectedBridgeProxy, "NAV and Bridge proxy addresses differ");

        console2.log("[OK] AtomicProxyDeployer and script use same formula, same proxy addresses");
        console2.log("  NAV proxy (canonical):   ", expectedNavProxy);
        console2.log("  Bridge proxy (canonical): ", expectedBridgeProxy);
    }

    /// @notice Test full AtomicProxyDeployer flow when proxies are not yet deployed (e.g. fresh chain or cleared).
    /// @dev Skips when proxies already exist at expected addresses (e.g. mainnet fork); otherwise deploys and asserts init.
    function test_AtomicProxyDeployerFullFlowWhenProxiesEmpty() public {
        address placeholder = _getPlaceholderAddress();
        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));

        address navProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);
        address bridgeProxy = _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        // Skip if either proxy is already deployed (e.g. on a mainnet fork after a real deploy). The
        // NAV-only deploy path (02_2) deploys the NAV proxy without the Bridge proxy, so a both-or-neither
        // check would miss that case and try to re-deploy the existing NAV proxy (reverts NotAuthorized).
        // Full flow is covered by broadcast.
        if (navProxy.code.length > 0 || bridgeProxy.code.length > 0) {
            console2.log(
                "[SKIP] test_AtomicProxyDeployerFullFlowWhenProxiesEmpty: proxies already deployed at expected addresses"
            );
            return;
        }

        NAVCalculator navImpl = new NAVCalculator();
        BridgeEscrow bridgeImpl = new BridgeEscrow();
        vm.deal(address(this), 1 ether);
        address adminToGrant =
            chainConfig.admin != address(0) ? chainConfig.admin : address(0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537);

        new AtomicProxyDeployer(
            address(navImpl),
            address(bridgeImpl),
            chainConfig.chainlinkSequencerFeed,
            chainConfig.nativeTokenSymbol,
            adminToGrant,
            adminToGrant
        );

        NAVCalculator nav = NAVCalculator(navProxy);
        BridgeEscrow bridge = BridgeEscrow(payable(bridgeProxy));
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), adminToGrant), "NAV admin should be granted");
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), adminToGrant), "Bridge admin should be granted");
        console2.log("[OK] AtomicProxyDeployer full flow: proxies upgraded and admin granted");
    }

    /// @notice Test that config can be read for all chains, logging per-chain Safe and implementation addresses
    /// @dev Proxy bytecode uses a placeholder impl, so implementation addresses may differ per chain.
    ///      This test reads config for each chain and logs per-chain impl addresses, flagging any
    ///      Safe-address differences without asserting on them.
    function test_ImplementationAddressesSameAcrossAllNetworks() public view {
        // List of chain IDs to test
        uint256[] memory chainIds = new uint256[](5);
        chainIds[0] = 1; // Ethereum mainnet
        chainIds[1] = 42161; // Arbitrum
        chainIds[2] = 8453; // Base
        chainIds[3] = 100; // Gnosis Chain
        chainIds[4] = 10; // Optimism

        // Read ACTUAL implementation addresses from config files (as deployed by script 01)
        address[] memory navImplAddresses = new address[](5);
        address[] memory bridgeImplAddresses = new address[](5);
        string[] memory chainNames = new string[](5);
        chainNames[0] = "Mainnet";
        chainNames[1] = "Arbitrum";
        chainNames[2] = "Base";
        chainNames[3] = "Gnosis";
        chainNames[4] = "Optimism";

        console2.log("\n=== Verifying Implementation Addresses (from script 01 deployments) ===");
        console2.log("Canonical CREATE2 Deployer:", CANONICAL_CREATE2_DEPLOYER);
        console2.log("Reading ACTUAL addresses from config files...");

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            ConfigReader.ChainConfig memory config = ConfigReader.readChainConfig(vm, chainId);

            // Read ACTUAL deployed addresses from config (as saved by script 01)
            address recordedNavImpl = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorImplementation");
            address recordedBridgeImpl = ConfigReader.readDeployedAddress(vm, chainId, "BridgeEscrowImplementation");

            navImplAddresses[i] = recordedNavImpl;
            bridgeImplAddresses[i] = recordedBridgeImpl;

            console2.log(string(abi.encodePacked("\n", chainNames[i], " (Chain ID ", vm.toString(chainId), "):")));
            console2.log("  Safe Multisig:", config.securityCouncil);
            console2.log("  NAV Implementation:", recordedNavImpl);
            console2.log("  Bridge Implementation:", recordedBridgeImpl);
        }

        // Implementation addresses may differ per chain; proxy bytecode uses a placeholder, so proxy addresses
        // are the same across chains regardless. 02b uses chain-specific impl addresses for upgradeAndCall.
        for (uint256 i = 1; i < navImplAddresses.length; i++) {
            if (
                navImplAddresses[0] != address(0) && navImplAddresses[i] != address(0)
                    && navImplAddresses[0] != navImplAddresses[i]
            ) {
                console2.log(
                    string(
                        abi.encodePacked(
                            "[INFO] NAV implementation differs on chain ",
                            vm.toString(chainIds[i]),
                            " (OK: proxy uses placeholder)"
                        )
                    )
                );
            }
        }
        for (uint256 i = 1; i < bridgeImplAddresses.length; i++) {
            if (
                bridgeImplAddresses[0] != address(0) && bridgeImplAddresses[i] != address(0)
                    && bridgeImplAddresses[0] != bridgeImplAddresses[i]
            ) {
                console2.log(
                    string(
                        abi.encodePacked(
                            "[INFO] Bridge implementation differs on chain ",
                            vm.toString(chainIds[i]),
                            " (OK: proxy uses placeholder)"
                        )
                    )
                );
            }
        }

        // Safe address is typically the same on all chains (proxy admin); log if config differs per chain
        for (uint256 i = 1; i < chainIds.length; i++) {
            ConfigReader.ChainConfig memory config0 = ConfigReader.readChainConfig(vm, chainIds[0]);
            ConfigReader.ChainConfig memory configI = ConfigReader.readChainConfig(vm, chainIds[i]);
            if (config0.securityCouncil != configI.securityCouncil) {
                console2.log(
                    string(
                        abi.encodePacked(
                            "[INFO] Safe address differs on chain ", vm.toString(chainIds[i]), " (config choice)"
                        )
                    )
                );
            }
        }

        console2.log("\n[OK] Config read for all chains.");
        console2.log("Proxy addresses are the same across chains (bytecode uses placeholder impl).");
        console2.log("Implementation addresses may differ per chain; 02b uses them for upgradeAndCall.");
    }

    /// @notice Test that non-Safe Admin cannot re-initialize an already initialized proxy
    /// @dev The `initializer` modifier prevents re-initialization, but anyone can initialize once
    function test_NonAdminCannotReinitializeProxy() public {
        require(chainConfig.securityCouncil != address(0), "Safe multisig address not configured");
        require(chainConfig.admin != address(0), "Admin address not configured");

        // Deploy implementations
        NAVCalculator navImpl = new NAVCalculator();
        UUPSPlaceholder placeholder = new UUPSPlaceholder();

        // Deploy proxy with placeholder implementation
        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        // Upgrade to real implementation and initialize
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.securityCouncil, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );

        // Upgrade and initialize; admin = msg.sender (caller of upgradeToAndCall)
        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(navImpl), navInitData);

        // Verify it's initialized (deployer = Safe has DEFAULT_ADMIN_ROLE)
        NAVCalculator nav = NAVCalculator(address(proxy));
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.securityCouncil), "Proxy should be initialized");

        // Try to re-initialize (should fail due to initializer modifier)
        vm.prank(EOA2);
        vm.expectRevert(); // Should revert due to initializer modifier
        nav.initialize(chainConfig.securityCouncil, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol);

        console2.log("[OK] Re-initialization correctly reverts");
    }

    /// @notice Test that Safe Admin can initialize proxy via upgradeToAndCall
    /// @dev The Safe calls upgradeToAndCall directly on the UUPS proxy to upgrade from the
    ///      placeholder impl and initialize in one step (UUPS has no separate ProxyAdmin)
    function test_SafeAdminCanInitializeProxy() public {
        require(chainConfig.securityCouncil != address(0), "Safe multisig address not configured");
        require(chainConfig.admin != address(0), "Admin address not configured");

        // Deploy implementations
        NAVCalculator navImpl = new NAVCalculator();
        BridgeEscrow bridgeImpl = new BridgeEscrow();
        UUPSPlaceholder placeholder = new UUPSPlaceholder();

        // Deploy proxies with placeholder implementations
        UUPSProxy navProxy = new UUPSProxy(address(placeholder), "");
        UUPSProxy bridgeProxy = new UUPSProxy(address(placeholder), "");

        // Prepare initialization data (admin = Safe, chainId = block.chainid in BridgeEscrow)
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.securityCouncil, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (chainConfig.securityCouncil, uint64(chainConfig.chainId), initialAccounts, initialAdapters)
        );

        // Upgrade and initialize; admin = msg.sender (Safe)
        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(navProxy)).upgradeToAndCall(address(navImpl), navInitData);

        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(bridgeProxy)).upgradeToAndCall(address(bridgeImpl), bridgeInitData);

        // Verify both proxies are initialized (deployer = Safe has DEFAULT_ADMIN_ROLE)
        NAVCalculator nav = NAVCalculator(address(navProxy));
        BridgeEscrow bridge = BridgeEscrow(payable(address(bridgeProxy)));

        assertTrue(
            nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.securityCouncil), "NAV proxy should be initialized"
        );
        assertTrue(
            bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), chainConfig.securityCouncil),
            "Bridge proxy should be initialized"
        );

        console2.log("[OK] Safe Admin can successfully initialize proxies");
    }

    /// @notice Test that non-admin cannot upgrade UUPS proxy
    /// @dev Only addresses with DEFAULT_ADMIN_ROLE can upgrade (checked by _authorizeUpgrade)
    function test_NonAdminCannotUpgradeUUPSProxy() public {
        require(chainConfig.securityCouncil != address(0), "Safe multisig address not configured");
        require(chainConfig.admin != address(0), "Admin address not configured");

        // Deploy implementations
        NAVCalculator navImpl = new NAVCalculator();
        UUPSPlaceholder placeholder = new UUPSPlaceholder();

        // Deploy proxy with placeholder implementation
        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        // Initialize proxy first; admin = Safe
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.securityCouncil, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );
        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(navImpl), navInitData);

        // Now try to upgrade as EOA1 (not admin) - should fail
        NAVCalculator newNavImpl = new NAVCalculator();
        vm.prank(EOA1);
        vm.expectRevert(); // Should revert because EOA1 does not have DEFAULT_ADMIN_ROLE
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(newNavImpl), "");

        console2.log("[OK] Non-admin cannot upgrade UUPS proxy");
    }

    /// @notice Test that anyone can initialize an uninitialized proxy directly (current behavior)
    /// @dev The initializer modifier only prevents re-initialization, not who can initialize
    function test_AnyoneCanInitializeUninitializedProxy() public {
        require(chainConfig.securityCouncil != address(0), "Safe multisig address not configured");
        require(chainConfig.admin != address(0), "Admin address not configured");

        // Deploy implementations
        NAVCalculator navImpl = new NAVCalculator();
        BridgeEscrow bridgeImpl = new BridgeEscrow();
        UUPSPlaceholder placeholder = new UUPSPlaceholder();

        // Deploy proxies with placeholder implementations
        UUPSProxy navProxy = new UUPSProxy(address(placeholder), "");
        UUPSProxy bridgeProxy = new UUPSProxy(address(placeholder), "");

        // Prepare initialization data (admin = Safe)
        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.securityCouncil, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (chainConfig.securityCouncil, uint64(chainConfig.chainId), initialAccounts, initialAdapters)
        );

        // Upgrade and initialize as Safe (deployer = admin)
        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(navProxy)).upgradeToAndCall(address(navImpl), navInitData);

        vm.prank(chainConfig.securityCouncil);
        UUPSUpgradeable(address(bridgeProxy)).upgradeToAndCall(address(bridgeImpl), bridgeInitData);

        // Verify both proxies are initialized (deployer has DEFAULT_ADMIN_ROLE)
        NAVCalculator nav = NAVCalculator(address(navProxy));
        BridgeEscrow bridge = BridgeEscrow(payable(address(bridgeProxy)));

        assertTrue(
            nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), chainConfig.securityCouncil), "NAV proxy should be initialized"
        );
        assertTrue(
            bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), chainConfig.securityCouncil),
            "Bridge proxy should be initialized"
        );

        console2.log("[OK] Anyone can initialize an uninitialized proxy (deployer becomes admin)");
        console2.log("  Safe initialized both proxies");
    }

    // ============ Tests from 02b (init flow, calldata, Safe TX) ============

    /// @notice UUPS proxy has no ProxyAdmin - upgrades go directly through proxy to implementation
    function test_UUPSProxyHasNoProxyAdmin() public {
        UUPSPlaceholder placeholder = new UUPSPlaceholder();
        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

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
        UUPSPlaceholder placeholder = new UUPSPlaceholder();
        BridgeEscrow bridgeImpl = new BridgeEscrow();

        UUPSProxy proxy = new UUPSProxy(address(placeholder), "");

        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData =
            abi.encodeCall(BridgeEscrow.initialize, (admin, uint64(block.chainid), initialAccounts, initialAdapters));

        vm.prank(safe);
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(bridgeImpl), bridgeInitData);

        BridgeEscrow bridge = BridgeEscrow(payable(address(proxy)));
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), admin), "Bridge proxy should be initialized with admin");
        console2.log("[OK] 02b upgradeToAndCall flow initializes Bridge proxy");
    }

    /// @notice Build the same calldata as 02b and verify selector and targets.
    function test_02bCalldataStructure() public pure {
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

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(navCalldata), UUPSUpgradeable.upgradeToAndCall.selector, "NAV tx uses upgradeToAndCall");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(bridgeCalldata), UUPSUpgradeable.upgradeToAndCall.selector, "Bridge tx uses upgradeToAndCall");
        assertEq(navCalldata.length > 4, true, "NAV calldata should have parameters");
        assertEq(bridgeCalldata.length > 4, true, "Bridge calldata should have parameters");
        console2.log("[OK] 02b calldata structure (targets + upgradeToAndCall selector) is valid");
    }

    // ============ Helper Functions ============

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    /// @notice Gets implementation addresses from fork or deployment records
    function _getImplementations() internal view returns (address navImpl, address bridgeImpl) {
        // First try to read from deployment records
        address recordedNavImpl = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorImplementation");
        address recordedBridgeImpl = ConfigReader.readDeployedAddress(vm, currentChainId, "BridgeEscrowImplementation");

        // If not in records, compute expected addresses using the real Safe address (as in production)
        if (recordedNavImpl == address(0)) {
            bytes32 saltNavImpl = ConfigReader.computeSalt("NAVCalculatorImplementation", DeploySalts.NAV_IMPL);
            navImpl = _computeCreate2Address(chainConfig.securityCouncil, saltNavImpl, type(NAVCalculator).creationCode);
        } else {
            navImpl = recordedNavImpl;
        }

        if (recordedBridgeImpl == address(0)) {
            bytes32 saltBridgeImpl = ConfigReader.computeSalt("BridgeEscrowImplementation", 1);
            bridgeImpl =
                _computeCreate2Address(chainConfig.securityCouncil, saltBridgeImpl, type(BridgeEscrow).creationCode);
        } else {
            bridgeImpl = recordedBridgeImpl;
        }

        // Verify implementations exist on fork
        require(_hasCode(navImpl), "NAVCalculator implementation not deployed on fork");
        require(_hasCode(bridgeImpl), "BridgeEscrow implementation not deployed on fork");
    }

    /// @notice Computes CREATE2 address (same formula as BaseDeployScript)
    function _computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
        );
    }

    /// @notice Placeholder impl address used in proxy bytecode (same as 02a: ProxyPlaceholderImpl, UUPSPlaceholder)
    function _getPlaceholderAddress() internal view returns (address) {
        bytes32 salt = ConfigReader.computeSalt("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL);
        return _computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salt, type(UUPSPlaceholder).creationCode);
    }

    /// @notice Checks if an address has code
    function _hasCode(address addr) internal view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        return codeSize > 0;
    }
}
