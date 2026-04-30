// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BalancerV3AdapterFactory} from "src/balances/protocols/balancer/BalancerV3AdapterFactory.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/balancer/BalancerV3.sol";
import {BalanceAdapterRegistry} from "src/balances/factories/BalanceAdapterRegistry.sol";
import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";

import {MockNAVForRegistry} from "test/balances/factories/MockNAVForRegistry.sol";
import {MockContract} from "test/mocks/MockContract.sol";

/// @notice Mock gauge that returns its pool from `lp_token()` (required by BalancerV3 ctor).
contract MockGauge {
    address private _lpToken;

    constructor(address pool_) {
        _lpToken = pool_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address) {
        return _lpToken;
    }
}

/// @notice Representative test for one protocol factory. The base + registry tests cover the
///         shared CREATE2/track/register flow; this test asserts the typed deploy/predict
///         signatures and protocol-key wiring are correct for BalancerV3.
contract BalancerV3AdapterFactoryTest is Test {
    bytes32 internal constant KEY_BAL = keccak256("BalancerV3");

    MockNAVForRegistry internal nav;
    BalanceAdapterRegistry internal registry;
    BalancerV3AdapterFactory internal factory;

    MockContract internal pool;
    MockGauge internal gauge;
    MockContract internal minter;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBADBAD);

    function setUp() public {
        nav = new MockNAVForRegistry();
        registry = new BalanceAdapterRegistry(address(nav), owner);
        factory = new BalancerV3AdapterFactory(address(registry), address(nav), owner);
        vm.prank(owner);
        registry.setFactory(KEY_BAL, address(factory));

        pool = new MockContract();
        gauge = new MockGauge(address(pool));
        minter = new MockContract();
    }

    function test_protocolKey_isBalancerV3() public view {
        assertEq(factory.PROTOCOL_KEY(), KEY_BAL);
    }

    function test_predict_matches_deploy() public {
        bytes32 salt = keccak256("balv3-pool-1");
        address predicted = factory.predict(address(pool), address(gauge), address(minter), "Balancer v3", salt);
        vm.prank(owner);
        address actual = factory.deploy(address(pool), address(gauge), address(minter), "Balancer v3", salt);
        assertEq(actual, predicted);
        assertGt(actual.code.length, 0);
    }

    function test_deploy_registersWithRegistryAndNAV() public {
        bytes32 salt = keccak256("balv3-pool-2");
        vm.prank(owner);
        address adapter = factory.deploy(address(pool), address(gauge), address(minter), "Balancer v3", salt);

        assertTrue(factory.isFromFactory(adapter));
        assertTrue(factory.isTracked(adapter));
        assertTrue(registry.isAdapterRegistered(adapter));
        assertEq(registry.adapterProtocol(adapter), KEY_BAL);
        assertEq(nav.addedCount(), 1);
        assertEq(nav.addedHistory(0), adapter);
    }

    function test_deploy_revertsIfNotOwner() public {
        bytes32 salt = keccak256("balv3-pool-3");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deploy(address(pool), address(gauge), address(minter), "Balancer v3", salt);
    }

    function test_deployedAdapterHasMatchingImmutables() public {
        bytes32 salt = keccak256("balv3-pool-4");
        vm.prank(owner);
        address adapter = factory.deploy(address(pool), address(gauge), address(minter), "Balancer v3", salt);

        BalancerV3PoolBalanceOracle a = BalancerV3PoolBalanceOracle(adapter);
        assertEq(address(a.POOL()), address(pool));
        assertEq(address(a.GAUGE()), address(gauge));
        assertEq(address(a.BALANCER_MINTER()), address(minter));
        assertEq(address(a.NAV_CALCULATOR()), address(nav));
    }

    function test_predict_isDeterministic() public view {
        bytes32 salt = keccak256("balv3-pool-5");
        address p1 = factory.predict(address(pool), address(gauge), address(minter), "Balancer v3", salt);
        address p2 = factory.predict(address(pool), address(gauge), address(minter), "Balancer v3", salt);
        assertEq(p1, p2);
    }

    function test_predict_changesWithSalt() public view {
        address p1 = factory.predict(address(pool), address(gauge), address(minter), "Balancer v3", bytes32(uint256(1)));
        address p2 = factory.predict(address(pool), address(gauge), address(minter), "Balancer v3", bytes32(uint256(2)));
        assertTrue(p1 != p2);
    }
}
