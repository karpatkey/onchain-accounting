// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BalanceAdapterRegistry} from "src/balances/factories/BalanceAdapterRegistry.sol";
import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";

import {MockNAVForRegistry} from "test/balances/factories/MockNAVForRegistry.sol";
import {MockBalanceAdapter, NonAdapter} from "test/balances/factories/MockBalanceAdapter.sol";

/// @notice Minimal concrete factory for testing the registry's factory-key resolution + unregister callback.
contract DummyFactory is BalanceAdapterFactoryBase {
    constructor(bytes32 key, address registry, address nav, address initialOwner)
        BalanceAdapterFactoryBase(key, registry, nav, initialOwner)
    {}

    function callRegister(address adapter) external {
        // Intentionally bypasses _track to exercise registry-side validation paths.
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
    }

    function trackAndRegister(address adapter, bool fromFactory) external {
        _track(adapter, fromFactory);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
    }
}

contract BalanceAdapterRegistryTest is Test {
    bytes32 internal constant KEY_BAL = keccak256("BalancerV3");
    bytes32 internal constant KEY_MORPHO = keccak256("MorphoVault");

    MockNAVForRegistry internal nav;
    BalanceAdapterRegistry internal registry;
    DummyFactory internal balFactory;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBADBAD);

    function setUp() public {
        nav = new MockNAVForRegistry();
        registry = new BalanceAdapterRegistry(address(nav), owner);
        balFactory = new DummyFactory(KEY_BAL, address(registry), address(nav), owner);
        vm.prank(owner);
        registry.setFactory(KEY_BAL, address(balFactory));
    }

    // ── setFactory ────────────────────────────────────────────────────────────

    function test_setFactory_recordsMapping() public {
        assertEq(registry.factory(KEY_BAL), address(balFactory));
        assertEq(registry.factoryProtocolKey(address(balFactory)), KEY_BAL);
    }

    function test_setFactory_appendsKeyOnceOnly() public {
        DummyFactory other = new DummyFactory(KEY_BAL, address(registry), address(nav), owner);
        vm.prank(owner);
        registry.setFactory(KEY_BAL, address(other));
        bytes32[] memory keys = registry.getProtocolKeys();
        assertEq(keys.length, 1);
        assertEq(keys[0], KEY_BAL);
        assertEq(registry.factory(KEY_BAL), address(other));
        // Old factory should no longer resolve to the key.
        assertEq(registry.factoryProtocolKey(address(balFactory)), bytes32(0));
    }

    function test_setFactory_unsetClearsReverseLookup() public {
        vm.prank(owner);
        registry.setFactory(KEY_BAL, address(0));
        assertEq(registry.factory(KEY_BAL), address(0));
        assertEq(registry.factoryProtocolKey(address(balFactory)), bytes32(0));
    }

    function test_setFactory_revertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setFactory(KEY_MORPHO, address(0xdead));
    }

    function test_setFactory_revertsOnZeroKey() public {
        vm.prank(owner);
        vm.expectRevert(BalanceAdapterRegistry.UnknownProtocolKey.selector);
        registry.setFactory(bytes32(0), address(0xdead));
    }

    // ── register (from factory) ───────────────────────────────────────────────

    function test_register_fromFactory_callsNAV() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        balFactory.callRegister(address(a));
        assertTrue(registry.isAdapterRegistered(address(a)));
        assertEq(registry.adapterProtocol(address(a)), KEY_BAL);
        assertEq(nav.addedCount(), 1);
        assertEq(nav.addedHistory(0), address(a));
    }

    function test_register_skipsNAVIfAlreadyRegistered() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        nav.setOracleRegistered(address(a), true); // pretend NAV already has it
        balFactory.callRegister(address(a));
        assertTrue(registry.isAdapterRegistered(address(a)));
        assertEq(nav.addedCount(), 0); // skipped
    }

    function test_register_revertsIfCallerNotAFactory() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(stranger);
        vm.expectRevert(BalanceAdapterRegistry.FactoryNotAuthorized.selector);
        registry.register(address(a));
    }

    function test_register_revertsOnDuplicate() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        balFactory.callRegister(address(a));
        vm.expectRevert(BalanceAdapterRegistry.AdapterAlreadyRegistered.selector);
        balFactory.callRegister(address(a));
    }

    function test_register_revertsOnNonAdapter() public {
        NonAdapter bad = new NonAdapter();
        vm.expectRevert(BalanceAdapterRegistry.NotAnAdapter.selector);
        balFactory.callRegister(address(bad));
    }

    function test_register_revertsOnZeroAddress() public {
        vm.expectRevert(BalanceAdapterRegistry.ZeroAddress.selector);
        balFactory.callRegister(address(0));
    }

    // ── registerExternal (owner-only escape hatch) ────────────────────────────

    function test_registerExternal_byOwner_works() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        registry.registerExternal(KEY_MORPHO, address(a));
        assertTrue(registry.isAdapterRegistered(address(a)));
        assertEq(registry.adapterProtocol(address(a)), KEY_MORPHO);
    }

    function test_registerExternal_revertsOnNotOwner() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.registerExternal(KEY_MORPHO, address(a));
    }

    function test_registerExternal_revertsOnZeroKey() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        vm.expectRevert(BalanceAdapterRegistry.UnknownProtocolKey.selector);
        registry.registerExternal(bytes32(0), address(a));
    }

    // ── unregister ────────────────────────────────────────────────────────────

    function test_unregister_byOwner_callsNAVAndFactoryHook() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        balFactory.trackAndRegister(address(a), true);

        // Sanity: factory tracks it.
        assertTrue(balFactory.isTracked(address(a)));

        vm.prank(owner);
        registry.unregister(address(a));

        assertFalse(registry.isAdapterRegistered(address(a)));
        assertEq(nav.removedCount(), 1);
        assertEq(nav.removedHistory(0), address(a));
        // Factory hook was called → adapter dropped from factory's live set.
        assertFalse(balFactory.isTracked(address(a)));
    }

    function test_unregister_revertsIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(BalanceAdapterRegistry.AdapterNotRegistered.selector);
        registry.unregister(address(0xdead));
    }

    function test_unregister_revertsIfNotOwner() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        balFactory.callRegister(address(a));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.unregister(address(a));
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function test_getAdaptersByProtocol_delegatesToFactory() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        MockBalanceAdapter b = new MockBalanceAdapter();
        balFactory.trackAndRegister(address(a), true);
        balFactory.trackAndRegister(address(b), true);

        address[] memory list = registry.getAdaptersByProtocol(KEY_BAL);
        assertEq(list.length, 2);
        assertEq(list[0], address(a));
        assertEq(list[1], address(b));
    }

    function test_getAdaptersByProtocol_fallbackForKeyWithoutFactory() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        registry.registerExternal(KEY_MORPHO, address(a));
        address[] memory list = registry.getAdaptersByProtocol(KEY_MORPHO);
        assertEq(list.length, 1);
        assertEq(list[0], address(a));
    }

    function test_getActiveAdapters_filtersUnregistered() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        MockBalanceAdapter b = new MockBalanceAdapter();
        balFactory.trackAndRegister(address(a), true);
        balFactory.trackAndRegister(address(b), true);
        vm.prank(owner);
        registry.unregister(address(a));

        address[] memory active = registry.getActiveAdapters();
        assertEq(active.length, 1);
        assertEq(active[0], address(b));
    }

    function test_adapterCount_includesUnregistered() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        MockBalanceAdapter b = new MockBalanceAdapter();
        balFactory.trackAndRegister(address(a), true);
        balFactory.trackAndRegister(address(b), true);
        vm.prank(owner);
        registry.unregister(address(a));
        assertEq(registry.adapterCount(), 2);
    }
}
