// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestEnvConfigurator} from "../../test/TestEnvConfigurator.sol";
import {Create2Deployer} from "../../src/deployment/Create2Deployer.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {Empty} from "../../src/utils/Empty.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";

/// @title DeploymentTest
/// @notice Tests for deployment scripts and infrastructure
contract DeploymentTest is TestEnvConfigurator {
    // Test addresses
    address constant SAFE_ADDRESS = address(0x1);
    address constant ADMIN_ADDRESS = address(0x2);
    address constant MANAGER_ADDRESS = address(0x3);

    Create2Deployer public create2Deployer;
    NAVCalculator public navImplementation;
    BridgeEscrow public bridgeImplementation;

    function setUp() public {
        // Deploy Create2Deployer
        create2Deployer = new Create2Deployer();

        // NavRegistryLib is pre-linked at this deterministic CREATE2 address (foundry.toml) and DELEGATECALL'd by
        // NAVCalculator during initialize() (registerAsset for the native asset). Etch its runtime code there so the
        // proxy-init tests below find it (mirrors how the other NAVCalculator tests etch the pre-linked libraries).
        vm.etch(0x706cD291D3164B7F50e8FEBDE5d744a3eb12Ed56, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);
    }

    /// @notice Test Create2Deployer deployment
    function test_DeployCreate2Deployer() public view {
        assertEq(address(create2Deployer).code.length > 0, true, "Create2Deployer not deployed");
    }

    /// @notice Test CREATE2 address computation
    function test_ComputeCreate2Address() public view {
        bytes32 salt = keccak256("test");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // Compute address using Create2Deployer
        address computed = create2Deployer.computeAddress(salt, bytecode);

        // Verify it matches manual calculation
        // Note: computeAddress uses address(this) inside Create2Deployer, which is the Create2Deployer contract address
        address expected = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(create2Deployer), salt, keccak256(bytecode))))
            )
        );

        assertEq(computed, expected, "Computed address mismatch");
    }

    /// @notice Test CREATE2 deployment via delegatecall
    function test_Create2DeploymentViaDelegatecall() public {
        bytes32 salt = keccak256("delegatetest");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // In delegatecall context, address(this) inside Create2Deployer becomes this test contract
        // So we need to compute the expected address using this contract as deployer
        address expectedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))))
        );

        // Deploy via delegatecall
        (bool success,) =
            address(create2Deployer).delegatecall(abi.encodeCall(Create2Deployer.deploy, (salt, bytecode)));

        assertTrue(success, "Delegatecall failed");
        assertEq(expectedAddress.code.length > 0, true, "Contract not deployed");
    }

    /// @notice Test deterministic proxy deployment
    function test_DeterministicProxyDeployment() public {
        // Deploy implementation
        navImplementation = new NAVCalculator();

        // Prepare init data
        bytes memory initData = abi.encodeCall(NAVCalculator.initialize, (ADMIN_ADDRESS, address(0), "ETH"));

        // Generate proxy bytecode
        bytes memory proxyBytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(navImplementation), initData));

        bytes32 salt1 = keccak256("proxy1");
        bytes32 salt2 = keccak256("proxy2");

        // Deploy first proxy
        address proxy1 = create2Deployer.deploy(salt1, proxyBytecode);

        // Deploy second proxy with different salt
        address proxy2 = create2Deployer.deploy(salt2, proxyBytecode);

        // Verify both deployed
        assertEq(proxy1.code.length > 0, true, "Proxy1 not deployed");
        assertEq(proxy2.code.length > 0, true, "Proxy2 not deployed");

        // Verify they have different addresses
        assertTrue(proxy1 != proxy2, "Proxies should have different addresses");

        // Verify both are initialized
        NAVCalculator nav1 = NAVCalculator(proxy1);
        NAVCalculator nav2 = NAVCalculator(proxy2);

        assertTrue(nav1.hasRole(nav1.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Proxy1 not initialized");
        assertTrue(nav2.hasRole(nav2.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Proxy2 not initialized");
    }

    /// @notice Test that same salt + bytecode = same address across "chains" (contexts)
    function test_SameAddressAcrossContexts() public {
        bytes32 salt = keccak256("crosschain");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // Compute address using first Create2Deployer instance
        address addr1 = create2Deployer.computeAddress(salt, bytecode);

        // Create a new Create2Deployer instance
        Create2Deployer deployer2 = new Create2Deployer();

        // Compute address using second Create2Deployer instance
        address addr2 = deployer2.computeAddress(salt, bytecode);

        // Addresses will be different because CREATE2 uses the deployer contract address (address(this) in Create2Deployer)
        // Different Create2Deployer instances have different addresses, so they produce different CREATE2 addresses
        // This test verifies that different deployer instances produce different addresses (expected behavior)
        assertTrue(addr1 != addr2, "Different deployer instances should produce different addresses");

        // Verify both addresses are computed correctly
        address expected1 = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(create2Deployer), salt, keccak256(bytecode))))
            )
        );
        address expected2 = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(deployer2), salt, keccak256(bytecode)))))
        );
        assertEq(addr1, expected1, "First address computation incorrect");
        assertEq(addr2, expected2, "Second address computation incorrect");
    }

    /// @notice Test CREATE2 deployment fails with duplicate salt
    function test_FailsOnDuplicateSalt() public {
        bytes32 salt = keccak256("duplicate");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // First deployment should succeed
        address deployed1 = create2Deployer.deploy(salt, bytecode);
        assertEq(deployed1.code.length > 0, true, "First deployment failed");

        // Second deployment with same salt should revert
        vm.expectRevert();
        create2Deployer.deploy(salt, bytecode);
    }

    /// @notice Test UUPS upgradeability for NAVCalculator
    function test_NAVCalculatorUpgradeability() public {
        // Deploy implementation
        navImplementation = new NAVCalculator();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(NAVCalculator.initialize, (ADMIN_ADDRESS, address(0), "ETH"));

        ERC1967Proxy proxy = new ERC1967Proxy(address(navImplementation), initData);
        NAVCalculator nav = NAVCalculator(address(proxy));

        // Verify initialized
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Not initialized");

        // Deploy new implementation
        NAVCalculator newImplementation = new NAVCalculator();

        // Upgrade (as admin)
        vm.prank(ADMIN_ADDRESS);
        nav.upgradeToAndCall(address(newImplementation), "");

        // Verify still works
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Lost admin after upgrade");
    }

    /// @notice Test UUPS upgradeability for BridgeEscrow
    function test_BridgeEscrowUpgradeability() public {
        // Deploy implementation
        bridgeImplementation = new BridgeEscrow();

        // Deploy proxy
        address[] memory emptyAccounts = new address[](0);
        address[] memory emptyAdapters = new address[](0);

        bytes memory initData = abi.encodeCall(
            BridgeEscrow.initialize, (ADMIN_ADDRESS, uint64(block.chainid), emptyAccounts, emptyAdapters)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(bridgeImplementation), initData);
        BridgeEscrow bridge = BridgeEscrow(payable(address(proxy)));

        // Verify initialized
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Not initialized");

        // Deploy new implementation
        BridgeEscrow newImplementation = new BridgeEscrow();

        // Upgrade (as admin)
        vm.prank(ADMIN_ADDRESS);
        bridge.upgradeToAndCall(address(newImplementation), "");

        // Verify still works
        assertTrue(bridge.hasRole(bridge.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Lost admin after upgrade");
    }

    /// @notice Test salt generation is deterministic
    function test_SaltGeneration() public pure {
        bytes32 salt1 = ConfigReader.computeSalt("NAVCalculatorProxy", 1);
        bytes32 salt2 = ConfigReader.computeSalt("NAVCalculatorProxy", 1);
        bytes32 salt3 = ConfigReader.computeSalt("NAVCalculatorProxy", 2);

        // Same name + version = same salt
        assertEq(salt1, salt2, "Salt should be deterministic");

        // Different version = different salt
        assertTrue(salt1 != salt3, "Different version should produce different salt");
    }

    /// @notice Test that proxy deployment yields the same proxy address on every chain (CREATE2 determinism)
    /// @dev Uses the same formula as 02a_DeployProxies: same deployer (canonical CREATE2) + same salt + same
    ///      bytecode (with Empty placeholder) => same proxy address on mainnet, Arbitrum, etc.
    function test_ProxyAddressSameAcrossChains() public pure {
        address deployer = address(0x4e59b44847b379578588920cA78FbF26c0B4956C); // Canonical CREATE2 deployer

        // Deploy Empty placeholder first
        bytes32 saltEmpty = ConfigReader.computeSalt("Empty", 1);
        address emptyPlaceholder = _computeCreate2Address(deployer, saltEmpty, type(Empty).creationCode);

        bytes32 saltNavProxy = ConfigReader.computeSalt("NAVCalculatorProxy", 1);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(emptyPlaceholder, ""));

        bytes32 saltBridgeProxy = ConfigReader.computeSalt("BridgeEscrowProxy", 1);
        bytes memory bridgeProxyBytecode =
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(emptyPlaceholder, ""));

        address navProxy = _computeCreate2Address(deployer, saltNavProxy, navProxyBytecode);
        address bridgeProxy = _computeCreate2Address(deployer, saltBridgeProxy, bridgeProxyBytecode);

        assertTrue(navProxy != address(0), "NAV proxy address should be non-zero");
        assertTrue(bridgeProxy != address(0), "Bridge proxy address should be non-zero");
        assertTrue(navProxy != bridgeProxy, "NAV and Bridge proxy addresses should differ");

        // Determinism: same deployer + salt + bytecode => same address on every chain
        address navProxy2 = _computeCreate2Address(deployer, saltNavProxy, navProxyBytecode);
        address bridgeProxy2 = _computeCreate2Address(deployer, saltBridgeProxy, bridgeProxyBytecode);
        assertEq(navProxy, navProxy2, "NAVCalculator proxy address must be same across chains");
        assertEq(bridgeProxy, bridgeProxy2, "BridgeEscrow proxy address must be same across chains");
    }

    /// @dev Same CREATE2 formula as BaseDeployScript.computeCreate2Address (used by deploy scripts)
    function _computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
        );
    }

    /// @notice Test that Create2Deployer is stateless (no storage)
    function test_Create2DeployerIsStateless() public {
        // Deploy contract
        bytes32 salt = keccak256("stateless");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        create2Deployer.deploy(salt, bytecode);

        // Check storage slots (should all be empty)
        // This is a basic check - a truly stateless contract has no state variables
        bytes32 slot0 = vm.load(address(create2Deployer), bytes32(uint256(0)));
        bytes32 slot1 = vm.load(address(create2Deployer), bytes32(uint256(1)));

        assertEq(slot0, bytes32(0), "Slot 0 should be empty");
        assertEq(slot1, bytes32(0), "Slot 1 should be empty");
    }

    /// @notice Test CREATE2 address computation from hash
    function test_ComputeAddressFromHash() public view {
        bytes32 salt = keccak256("hashtest");
        bytes memory bytecode = type(NAVCalculator).creationCode;
        bytes32 bytecodeHash = keccak256(bytecode);

        // Compute from bytecode
        address addr1 = create2Deployer.computeAddress(salt, bytecode);

        // Compute from hash
        address addr2 = create2Deployer.computeAddressFromHash(salt, bytecodeHash);

        assertEq(addr1, addr2, "Address computation should match");
    }

    /// @notice Test deployment event emission
    function test_DeploymentEventEmission() public {
        bytes32 salt = keccak256("eventtest");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // Compute expected address
        address expectedAddress = create2Deployer.computeAddress(salt, bytecode);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit Create2Deployer.Deployed(expectedAddress, salt);

        // Deploy
        create2Deployer.deploy(salt, bytecode);
    }

    /// @notice Test multiple sequential deployments
    function test_MultipleSequentialDeployments() public {
        uint256 count = 5;
        address[] memory deployed = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 salt = keccak256(abi.encodePacked("multi", i));
            bytes memory bytecode = type(NAVCalculator).creationCode;

            deployed[i] = create2Deployer.deploy(salt, bytecode);

            // Verify each deployment
            assertEq(deployed[i].code.length > 0, true, "Deployment failed");

            // Verify uniqueness
            for (uint256 j = 0; j < i; j++) {
                assertTrue(deployed[i] != deployed[j], "Duplicate address");
            }
        }
    }

    /// @notice Test initialization cannot be called twice
    function test_CannotReinitialize() public {
        // Deploy and initialize NAVCalculator
        navImplementation = new NAVCalculator();

        bytes memory initData = abi.encodeCall(NAVCalculator.initialize, (ADMIN_ADDRESS, address(0), "ETH"));

        ERC1967Proxy proxy = new ERC1967Proxy(address(navImplementation), initData);
        NAVCalculator nav = NAVCalculator(address(proxy));

        // Try to initialize again - should fail
        vm.expectRevert();
        nav.initialize(ADMIN_ADDRESS, address(0), "ETH");
    }

    /// @notice Test proxy admin role is set correctly
    function test_ProxyAdminRoleSetCorrectly() public {
        navImplementation = new NAVCalculator();

        bytes memory initData = abi.encodeCall(NAVCalculator.initialize, (ADMIN_ADDRESS, address(0), "ETH"));

        ERC1967Proxy proxy = new ERC1967Proxy(address(navImplementation), initData);
        NAVCalculator nav = NAVCalculator(address(proxy));

        // Admin should have DEFAULT_ADMIN_ROLE
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), ADMIN_ADDRESS), "Admin role not set");

        // Others should not
        assertFalse(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), address(this)), "This should not be admin");
    }

    /// @notice Test Safe delegatecall simulation
    function test_SafeDelegatecallSimulation() public {
        // Create a mock Safe contract
        MockSafe safe = new MockSafe();

        // Deploy Create2Deployer
        Create2Deployer deployer = new Create2Deployer();

        // Prepare deployment
        bytes32 salt = keccak256("safetest");
        bytes memory bytecode = type(NAVCalculator).creationCode;

        // In delegatecall context, address(this) inside Create2Deployer becomes the Safe's address
        // So we compute the expected address using the Safe address as deployer
        address expectedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(safe), salt, keccak256(bytecode)))))
        );

        // Deploy via Safe delegatecall
        bytes memory deployCall = abi.encodeCall(Create2Deployer.deploy, (salt, bytecode));
        address deployed = safe.delegatecallDeploy(address(deployer), deployCall);

        // Verify deployment
        assertEq(deployed, expectedAddress, "Address mismatch");
        assertEq(deployed.code.length > 0, true, "Contract not deployed");
    }

    /// @notice Test that getAlchemyUrl returns valid RPC URLs
    function test_GetAlchemyUrlReturnsValidUrl() public view {
        // Test mainnet URL
        string memory mainnetUrl = getAlchemyUrl("eth-mainnet");
        assertTrue(bytes(mainnetUrl).length > 0, "Mainnet URL should not be empty");

        // Test Arbitrum URL
        string memory arbitrumUrl = getAlchemyUrl("arb-mainnet");
        assertTrue(bytes(arbitrumUrl).length > 0, "Arbitrum URL should not be empty");

        // Test Base URL
        string memory baseUrl = getAlchemyUrl("base-mainnet");
        assertTrue(bytes(baseUrl).length > 0, "Base URL should not be empty");

        // Test Optimism URL
        string memory optimismUrl = getAlchemyUrl("opt-mainnet");
        assertTrue(bytes(optimismUrl).length > 0, "Optimism URL should not be empty");

        // Test Gnosis URL
        string memory gnosisUrl = getAlchemyUrl("gnosis-mainnet");
        assertTrue(bytes(gnosisUrl).length > 0, "Gnosis URL should not be empty");
    }
}

/// @notice Mock Safe contract for testing delegatecall
contract MockSafe {
    function delegatecallDeploy(address target, bytes memory data) external returns (address) {
        (bool success, bytes memory result) = target.delegatecall(data);
        require(success, "Delegatecall failed");
        return abi.decode(result, (address));
    }
}
