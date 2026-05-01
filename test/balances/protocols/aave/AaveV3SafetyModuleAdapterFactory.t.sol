// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AaveV3SafetyModuleAdapterFactory} from "src/balances/protocols/aave/AaveV3SafetyModuleAdapterFactory.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/aave/AaveV3SafetyModule.sol";
import {BalanceAdapterRegistry} from "src/balances/factories/BalanceAdapterRegistry.sol";

import {MockNAVForRegistry} from "test/balances/factories/MockNAVForRegistry.sol";

/// @notice Mock stake token implementing the minimal `IStakeToken` interface used by the adapter at registration.
contract MockStakeToken {
    address public immutable REWARD_TOKEN;
    address public immutable STAKED_TOKEN;

    constructor(address rewardToken_, address stakedToken_) {
        REWARD_TOKEN = rewardToken_;
        STAKED_TOKEN = stakedToken_;
    }

    function balanceOf(address) external pure returns (uint256) { return 0; }
    function previewRedeem(uint256) external pure returns (uint256) { return 0; }
    function getTotalRewardsBalance(address) external pure returns (uint256) { return 0; }
}

/// @title AaveV3SafetyModuleAdapterFactoryTest
/// @notice Asserts the SM factory's typed deploy/predict signatures and protocol-key wiring.
contract AaveV3SafetyModuleAdapterFactoryTest is Test {
    bytes32 internal constant KEY_SM = keccak256("AaveV3SafetyModule");

    MockNAVForRegistry internal nav;
    BalanceAdapterRegistry internal registry;
    AaveV3SafetyModuleAdapterFactory internal factory;

    MockStakeToken internal stkA;
    MockStakeToken internal stkB;

    address internal owner = address(0xA11CE);
    address internal admin = address(0xADA1);
    address internal stranger = address(0xBADBAD);

    address internal asset1 = address(0xAA11);
    address internal asset2 = address(0xBB22);

    function setUp() public {
        nav = new MockNAVForRegistry();
        registry = new BalanceAdapterRegistry(address(nav), owner);
        factory = new AaveV3SafetyModuleAdapterFactory(address(registry), address(nav), owner);
        vm.prank(owner);
        registry.setFactory(KEY_SM, address(factory));

        stkA = new MockStakeToken(asset1, asset1); // staked == reward
        stkB = new MockStakeToken(asset1, asset2); // distinct staked / reward
    }

    function _initial() internal view returns (AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory) {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory init =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](2);
        init[0] = AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(stkA), positionDetail: "stkA"});
        init[1] = AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(stkB), positionDetail: "stkB"});
        return init;
    }

    function test_protocolKey_isAaveV3SafetyModule() public view {
        assertEq(factory.PROTOCOL_KEY(), KEY_SM);
    }

    function test_predict_matches_deploy() public {
        bytes32 salt = keccak256("sm-v1");
        address predicted = factory.predict(_initial(), admin, "Aave V3 Safety Module", salt);

        vm.prank(owner);
        address actual = factory.deploy(_initial(), admin, "Aave V3 Safety Module", salt);
        assertEq(actual, predicted);
        assertGt(actual.code.length, 0);
    }

    function test_deploy_registersWithRegistryAndNAV() public {
        bytes32 salt = keccak256("sm-v2");
        vm.prank(owner);
        address adapter = factory.deploy(_initial(), admin, "Aave V3 Safety Module", salt);

        assertTrue(factory.isFromFactory(adapter));
        assertTrue(factory.isTracked(adapter));
        assertTrue(registry.isAdapterRegistered(adapter));
        assertEq(registry.adapterProtocol(adapter), KEY_SM);
        assertEq(nav.addedCount(), 1);
        assertEq(nav.addedHistory(0), adapter);
    }

    function test_deploy_revertsIfNotOwner() public {
        bytes32 salt = keccak256("sm-v3");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deploy(_initial(), admin, "Aave V3 Safety Module", salt);
    }

    function test_deployedAdapterHasCorrectAdminAndStakeTokens() public {
        bytes32 salt = keccak256("sm-v4");
        vm.prank(owner);
        address adapter = factory.deploy(_initial(), admin, "Aave V3 Safety Module", salt);

        AaveV3SafetyModuleBalanceOracle a = AaveV3SafetyModuleBalanceOracle(adapter);
        assertEq(a.owner(), admin);
        assertEq(address(a.NAV_CALCULATOR()), address(nav));
        assertEq(a.PROTOCOL(), "Aave V3 Safety Module");
        assertEq(a.stakeTokenCount(), 2);
        assertTrue(a.isStakeTokenRegistered(address(stkA)));
        assertTrue(a.isStakeTokenRegistered(address(stkB)));
    }

    function test_deploy_emptyInitial_isAllowed() public {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        bytes32 salt = keccak256("sm-empty");
        vm.prank(owner);
        address adapter = factory.deploy(empty, admin, "Aave V3 Safety Module", salt);
        assertEq(AaveV3SafetyModuleBalanceOracle(adapter).stakeTokenCount(), 0);
    }

    function test_predict_changesWithSalt() public view {
        address p1 = factory.predict(_initial(), admin, "Aave V3 Safety Module", bytes32(uint256(1)));
        address p2 = factory.predict(_initial(), admin, "Aave V3 Safety Module", bytes32(uint256(2)));
        assertTrue(p1 != p2);
    }
}
