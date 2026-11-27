// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ExecutionOptions, IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {IPositionModule} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {MorphoVaultModule} from "poc/fundconfig/modules/MorphoVaultModule.sol";
import {AaveV3Module} from "poc/fundconfig/modules/AaveV3Module.sol";
import {EtherFiAssistedModule} from "poc/fundconfig/modules/EtherFiAssistedModule.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface ISafeFork {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function enableModule(address module) external;
}

interface ISafeProxyFactoryFork {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface IERC4626Fork {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IAavePoolFork {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveDataProviderFork {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProviderFork {
    function getPool() external view returns (address);
}

interface IEtherFiAssistantFork {
    function requestWithdraw(uint256 amount) external returns (uint256 requestId);
}

/// @notice T1-T7 for the FundConfig POC, on a mainnet fork at a pinned block.
/// @dev Every test deploys a fresh Safe (Safe 1.4.1) and a fresh FundConfig, so no state leaks across tests.
contract FundConfigForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MORPHO_VAULT = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd; // kpk_USDC_Prime
    address internal constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant MORPHO_ADAPTER = 0x72a012B30b240458C3f79fd20E5c2A907d77e54f; // MorphoVaultsMeta
    address internal constant AAVE_ADAPTER = 0xa1b3c695A768A6Ce571fF699F463224CB32260C1; // AaveV3InstancesMeta
    address internal constant ETHERFI_ADAPTER = 0xd074FAf8D8f2909BE3E6D51c219916065c5d870A; // EtherFiWithdrawalQueueAssisted
    address internal constant ETHERFI_ASSISTANT = 0xD2EA372e6c1bA08cE3d20F4Ce69d68f13E1F92c4;
    address internal constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address internal constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address internal constant EETH_WHALE = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bytes32 internal constant ROLE_KEY = keccak256("manager");
    uint8 internal constant CALL = 0;
    uint8 internal constant DELEGATECALL = 1;

    address internal safeOwner;
    address internal curator;
    address internal manager;
    ModuleRegistry internal registry;
    MorphoVaultModule internal morpho;
    AaveV3Module internal aave;
    EtherFiAssistedModule internal etherfi;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        safeOwner = makeAddr("safeOwner");
        curator = makeAddr("curator");
        manager = makeAddr("manager");

        registry = new ModuleRegistry(address(this));
        morpho = new MorphoVaultModule(MORPHO_ADAPTER);
        aave = new AaveV3Module(keccak256("aave-v3-usdc"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        etherfi = new EtherFiAssistedModule(ETHERFI_ASSISTANT, ETHERFI_ADAPTER);
        registry.register(morpho);
        registry.register(aave);
        registry.register(etherfi);
    }

    // ---------------------------------------------------------------- helpers

    function _newFund(uint256 saltNonce) internal returns (address safe, FundConfig fc, IRolesV2 roles) {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner;
        bytes memory init = abi.encodeCall(
            ISafeFork.setup,
            (owners, 1, address(0), "", FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactoryFork(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, saltNonce);

        fc = new FundConfig(
            registry,
            INAVCalculator(NAV_PROXY),
            IModuleProxyFactory(MODULE_FACTORY),
            ROLES_MASTERCOPY,
            safe,
            curator,
            ROLE_KEY,
            saltNonce
        );
        roles = fc.ROLES();

        vm.prank(safe);
        ISafeFork(safe).enableModule(address(roles));
    }

    function _addr(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _addPosition(FundConfig fc, IPositionModule module, bytes32 instance) internal {
        bytes32 moduleId = module.moduleId();
        vm.prank(curator);
        fc.addPosition(moduleId, instance);
    }

    function _manager(FundConfig fc) internal {
        vm.prank(curator);
        fc.assignManager(manager, true);
    }

    function _exec(IRolesV2 roles, address to, bytes memory data, uint8 op) internal {
        vm.prank(manager);
        roles.execTransactionWithRole(to, 0, data, op, ROLE_KEY, true);
    }

    function _aavePool() internal view returns (address) {
        return IAavePoolAddressesProviderFork(IAaveDataProviderFork(AAVE_DATA_PROVIDER).ADDRESSES_PROVIDER()).getPool();
    }

    // ---------------------------------------------------------------- T1

    /// @notice T1: declared Morpho vault + Aave USDC; the manager deposits through Roles and NAV tracks the funded value.
    function test_T1_allowedPath_fundNavTracksDeposits() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(1);
        deal(USDC, safe, 200_000e6);

        _addPosition(fc, morpho, _addr(MORPHO_VAULT));
        _addPosition(fc, aave, _addr(USDC));
        _manager(fc);

        (int256 navBefore, bool staleBefore) = fc.fundNav(USDC);
        assertFalse(staleBefore);
        assertGt(navBefore, 0);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 100_000e6)), CALL);
        _exec(roles, MORPHO_VAULT, abi.encodeCall(IERC4626Fork.deposit, (100_000e6, safe)), CALL);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), 100_000e6)), CALL);
        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.supply, (USDC, 100_000e6, safe, 0)), CALL);

        assertEq(IERC20(USDC).balanceOf(safe), 0);
        assertGt(IERC4626Fork(MORPHO_VAULT).balanceOf(safe), 0);

        (int256 navAfter, bool staleAfter) = fc.fundNav(USDC);
        assertFalse(staleAfter);
        assertApproxEqRel(uint256(navAfter), uint256(navBefore), 1e15);
    }

    // ---------------------------------------------------------------- T2

    /// @notice T2: undeclared target, undeclared spender, and a receiver other than the Safe all revert.
    function test_T2_denied() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(2);
        deal(USDC, safe, 1_000e6);

        _addPosition(fc, morpho, _addr(MORPHO_VAULT));
        _addPosition(fc, aave, _addr(USDC));
        _manager(fc);

        address undeclaredVault = makeAddr("undeclaredVault");
        vm.expectRevert();
        _exec(roles, undeclaredVault, abi.encodeCall(IERC4626Fork.deposit, (1e6, safe)), CALL);

        vm.expectRevert();
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (makeAddr("undeclaredSpender"), 1e6)), CALL);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 1_000e6)), CALL);
        vm.expectRevert();
        _exec(roles, MORPHO_VAULT, abi.encodeCall(IERC4626Fork.deposit, (1e6, manager)), CALL);
    }

    // ---------------------------------------------------------------- T3

    /// @notice T3: the shared approve(USDC) is merged across Morpho and Aave; removing one spender leaves the other.
    function test_T3_mergeAndRemoval() public {
        (, FundConfig fc, IRolesV2 roles) = _newFund(3);
        _addPosition(fc, morpho, _addr(MORPHO_VAULT));
        _addPosition(fc, aave, _addr(USDC));
        _manager(fc);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 1e6)), CALL);
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), 1e6)), CALL);

        bytes32 moduleId = morpho.moduleId();
        vm.prank(curator);
        fc.removePosition(moduleId, _addr(MORPHO_VAULT));

        vm.expectRevert();
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 1e6)), CALL);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), 2e6)), CALL);
    }

    // ---------------------------------------------------------------- T4

    /// @notice T4: removePosition reverts while the position holds value and succeeds after full withdrawal.
    function test_T4_removalGuard() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(4);
        deal(USDC, safe, 50_000e6);
        _addPosition(fc, aave, _addr(USDC));
        _manager(fc);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), 50_000e6)), CALL);
        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.supply, (USDC, 50_000e6, safe, 0)), CALL);

        bytes32 instance = _addr(USDC);
        bytes32 moduleId = aave.moduleId();
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(FundConfig.PositionNotEmpty.selector, moduleId, instance));
        fc.removePosition(moduleId, instance);

        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.withdraw, (USDC, type(uint256).max, safe)), CALL);
        assertGt(IERC20(USDC).balanceOf(safe), 49_999e6);

        vm.prank(curator);
        fc.removePosition(moduleId, instance);

        address pool = _aavePool();
        vm.expectRevert();
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (pool, 1e6)), CALL);
    }

    // ---------------------------------------------------------------- T5

    /// @notice T5: the EtherFi module lets the manager delegatecall the assistant; the direct LiquidityPool call is denied.
    function test_T5_assistedCompleteness() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(5);
        _addPosition(fc, etherfi, _addr(ETHERFI_ASSISTANT));
        _manager(fc);

        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(safe, 10 ether);

        _exec(roles, ETHERFI_ASSISTANT, abi.encodeCall(IEtherFiAssistantFork.requestWithdraw, (5 ether)), DELEGATECALL);
        assertApproxEqRel(IERC20(EETH).balanceOf(safe), 5 ether, 1e15);

        vm.expectRevert();
        _exec(roles, LIQUIDITY_POOL, abi.encodeWithSignature("requestWithdraw(address,uint256)", manager, 1 ether), CALL);
    }

    // ---------------------------------------------------------------- T6

    /// @notice T6: identical config in two funds; the second fund's setup is cheaper because condition buffers dedupe.
    function test_T6_gasDedupe() public {
        uint256 totalA;
        uint256 totalB;

        (, FundConfig fcA,) = _newFund(60);
        _addPosition(fcA, morpho, _addr(MORPHO_VAULT));
        uint256 gasA1 = vm.lastCallGas().gasTotalUsed;
        _addPosition(fcA, aave, _addr(USDC));
        uint256 gasA2 = vm.lastCallGas().gasTotalUsed;

        (, FundConfig fcB,) = _newFund(61);
        _addPosition(fcB, morpho, _addr(MORPHO_VAULT));
        uint256 gasB1 = vm.lastCallGas().gasTotalUsed;
        _addPosition(fcB, aave, _addr(USDC));
        uint256 gasB2 = vm.lastCallGas().gasTotalUsed;

        totalA = gasA1 + gasA2;
        totalB = gasB1 + gasB2;

        console2.log("T6 fund A addPosition(morpho) gas", gasA1);
        console2.log("T6 fund A addPosition(aave) gas", gasA2);
        console2.log("T6 fund B addPosition(morpho) gas", gasB1);
        console2.log("T6 fund B addPosition(aave) gas", gasB2);
        console2.log("T6 fund A total gas", totalA);
        console2.log("T6 fund B total gas", totalB);

        assertLt(totalB, totalA);
    }

    // ---------------------------------------------------------------- T7

    /// @notice T7: FundConfig owns Roles; owner-only Roles calls and direct Safe calls are not reachable by anyone else.
    function test_T7_noBypass() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(7);
        _addPosition(fc, morpho, _addr(MORPHO_VAULT));
        _manager(fc);

        assertEq(roles.owner(), address(fc));

        vm.prank(curator);
        vm.expectRevert();
        roles.allowFunction(ROLE_KEY, USDC, IERC20.approve.selector, ExecutionOptions.None);

        vm.prank(curator);
        (bool ok,) = address(fc).call(
            abi.encodeWithSignature("allowFunction(bytes32,address,bytes4,uint8)", ROLE_KEY, USDC, IERC20.approve.selector, 0)
        );
        assertFalse(ok);

        vm.prank(curator);
        (ok,) = address(fc).call(
            abi.encodeWithSignature("scopeTarget(bytes32,address)", ROLE_KEY, USDC)
        );
        assertFalse(ok);

        vm.expectRevert();
        _exec(roles, safe, abi.encodeCall(ISafeFork.enableModule, (makeAddr("attacker"))), CALL);
    }
}
