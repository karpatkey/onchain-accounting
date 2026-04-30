// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {BalanceAdapterRegistry} from "src/balances/factories/BalanceAdapterRegistry.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";

import {MockNAVForRegistry} from "test/balances/factories/MockNAVForRegistry.sol";
import {MockBalanceAdapter, NonAdapter} from "test/balances/factories/MockBalanceAdapter.sol";

/// @notice Concrete child for exercising BalanceAdapterFactoryBase behavior end-to-end.
contract HarnessFactory is BalanceAdapterFactoryBase {
    constructor(bytes32 key, address registry, address nav, address initialOwner)
        BalanceAdapterFactoryBase(key, registry, nav, initialOwner)
    {}

    /// @notice Deploys a `MockBalanceAdapter` via CREATE2 — used to test the base's deploy/predict helpers.
    function deployMock(bytes32 salt) external onlyOwner returns (address adapter) {
        bytes memory initCode = type(MockBalanceAdapter).creationCode;
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predictMock(bytes32 salt) external pure returns (address) {
        return _predictCreate2(salt, keccak256(type(MockBalanceAdapter).creationCode));
    }
}

contract BalanceAdapterFactoryBaseTest is Test {
    bytes32 internal constant KEY = keccak256("TestProtocol");

    MockNAVForRegistry internal nav;
    BalanceAdapterRegistry internal registry;
    HarnessFactory internal factory;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBADBAD);

    function setUp() public {
        nav = new MockNAVForRegistry();
        registry = new BalanceAdapterRegistry(address(nav), owner);
        factory = new HarnessFactory(KEY, address(registry), address(nav), owner);
        vm.prank(owner);
        registry.setFactory(KEY, address(factory));
    }

    // ── Constructor validation ────────────────────────────────────────────────

    function test_constructor_revertsOnZeroProtocolKey() public {
        vm.expectRevert(BalanceAdapterFactoryBase.ZeroAddress.selector);
        new HarnessFactory(bytes32(0), address(registry), address(nav), owner);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(BalanceAdapterFactoryBase.ZeroAddress.selector);
        new HarnessFactory(KEY, address(0), address(nav), owner);
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(BalanceAdapterFactoryBase.ZeroAddress.selector);
        new HarnessFactory(KEY, address(registry), address(0), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        // OZ Ownable raises its own error before the base's ZeroAddress check fires.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HarnessFactory(KEY, address(registry), address(nav), address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(factory.PROTOCOL_KEY(), KEY);
        assertEq(factory.NAV_CALCULATOR(), address(nav));
        assertEq(factory.REGISTRY(), address(registry));
        assertEq(factory.owner(), owner);
    }

    // ── registerExternal ──────────────────────────────────────────────────────

    function test_registerExternal_owner_tracks_andRegistersInRegistry() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        factory.registerExternal(address(a));

        assertTrue(factory.isTracked(address(a)));
        assertFalse(factory.isFromFactory(address(a)));
        assertTrue(registry.isAdapterRegistered(address(a)));
        assertEq(nav.addedCount(), 1);
    }

    function test_registerExternal_revertsIfNotOwner() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.registerExternal(address(a));
    }

    function test_registerExternal_revertsOnDuplicate() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.startPrank(owner);
        factory.registerExternal(address(a));
        vm.expectRevert(BalanceAdapterFactoryBase.AdapterAlreadyTracked.selector);
        factory.registerExternal(address(a));
        vm.stopPrank();
    }

    function test_registerExternal_revertsOnNonAdapter() public {
        NonAdapter bad = new NonAdapter();
        vm.prank(owner);
        vm.expectRevert(BalanceAdapterFactoryBase.NotAnAdapter.selector);
        factory.registerExternal(address(bad));
    }

    // ── onAdapterUnregistered ─────────────────────────────────────────────────

    function test_onAdapterUnregistered_revertsIfNotRegistry() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        factory.registerExternal(address(a));
        vm.prank(stranger);
        vm.expectRevert(BalanceAdapterFactoryBase.OnlyRegistry.selector);
        factory.onAdapterUnregistered(address(a));
    }

    function test_onAdapterUnregistered_clearsIsTracked() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        vm.prank(owner);
        factory.registerExternal(address(a));
        vm.prank(address(registry));
        factory.onAdapterUnregistered(address(a));
        assertFalse(factory.isTracked(address(a)));
    }

    function test_onAdapterUnregistered_revertsIfAdapterUnknown() public {
        vm.prank(address(registry));
        vm.expectRevert(BalanceAdapterFactoryBase.AdapterNotTracked.selector);
        factory.onAdapterUnregistered(address(0xdead));
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function test_getAdapters_returnsHistoricalList() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        MockBalanceAdapter b = new MockBalanceAdapter();
        vm.startPrank(owner);
        factory.registerExternal(address(a));
        factory.registerExternal(address(b));
        vm.stopPrank();
        address[] memory list = factory.getAdapters();
        assertEq(list.length, 2);
        assertEq(list[0], address(a));
        assertEq(list[1], address(b));
        assertEq(factory.adapterCount(), 2);
    }

    function test_getActiveAdapters_filtersUnregistered() public {
        MockBalanceAdapter a = new MockBalanceAdapter();
        MockBalanceAdapter b = new MockBalanceAdapter();
        vm.startPrank(owner);
        factory.registerExternal(address(a));
        factory.registerExternal(address(b));
        vm.stopPrank();
        vm.prank(address(registry));
        factory.onAdapterUnregistered(address(a));
        address[] memory active = factory.getActiveAdapters();
        assertEq(active.length, 1);
        assertEq(active[0], address(b));
    }

    // ── CREATE2 deploy + predict ──────────────────────────────────────────────

    function test_deploy_predict_matches() public {
        bytes32 salt = keccak256("salt-1");
        address predicted = factory.predictMock(salt);
        vm.prank(owner);
        address actual = factory.deployMock(salt);
        assertEq(actual, predicted);
    }

    function test_deploy_isIdempotent() public {
        bytes32 salt = keccak256("salt-2");
        vm.startPrank(owner);
        address first = factory.deployMock(salt);
        // Second deploy at same salt should be a no-op (already-deployed code returned), but
        // _track will revert on duplicate. Sanity-check that the first deploy went through.
        vm.expectRevert(BalanceAdapterFactoryBase.AdapterAlreadyTracked.selector);
        factory.deployMock(salt);
        vm.stopPrank();
        assertGt(first.code.length, 0);
    }

    function test_deploy_revertsIfNotOwner() public {
        bytes32 salt = keccak256("salt-3");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deployMock(salt);
    }
}
