// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {IPositionModule} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {MorphoVaultModule} from "poc/fundconfig/modules/MorphoVaultModule.sol";
import {AaveV3Module} from "poc/fundconfig/modules/AaveV3Module.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface ISafeGas {
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

interface ISafeProxyFactoryGas {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface IAaveDataProviderGas {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAaveProvidersGas {
    function getPool() external view returns (address);
}

/// @notice Mock ERC4626-shaped vault: `validate` and `permissions` of the Morpho module only call `asset()`.
contract MockVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @notice Gas profile for `FundConfig.addPosition`: T6 pair orderings, cold-access controls, and an N=1..8 scaling series.
/// @dev Emits `GASPROF <key> <gas>` lines via console2 for `docs/research/fund-infra/gas-profile.json`.
contract FundConfigGasForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MORPHO_VAULT = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd;
    address internal constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant MORPHO_ADAPTER = 0x72a012B30b240458C3f79fd20E5c2A907d77e54f;
    address internal constant AAVE_ADAPTER = 0xa1b3c695A768A6Ce571fF699F463224CB32260C1;
    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant ROLES_CREATE2 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    address internal constant ROLES_PACKER = 0x61C5B1bE435391fDd7BC6703F3740C0d11728a8C;
    address internal constant ROLES_INTEGRITY = 0x6a6Af4b16458Bc39817e4019fB02BD3b26d41049;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bytes32 internal constant ROLE_KEY = keccak256("manager");

    address internal safeOwner;
    address internal curator;
    ModuleRegistry internal registry;
    MorphoVaultModule internal morpho;
    AaveV3Module internal aave;
    address internal aavePool;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        safeOwner = makeAddr("safeOwner");
        curator = makeAddr("curator");

        registry = new ModuleRegistry(address(this));
        morpho = new MorphoVaultModule(MORPHO_ADAPTER);
        aave = new AaveV3Module(keccak256("aave-v3-usdc"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        registry.register(morpho);
        registry.register(aave);

        aavePool = IAaveProvidersGas(IAaveDataProviderGas(AAVE_DATA_PROVIDER).ADDRESSES_PROVIDER()).getPool();
    }

    // ---------------------------------------------------------------- helpers

    function _newFund(uint256 saltNonce) internal returns (FundConfig fc, IRolesV2 roles) {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner;
        bytes memory init = abi.encodeCall(
            ISafeGas.setup,
            (owners, 1, address(0), "", FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        address safe = ISafeProxyFactoryGas(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, saltNonce);

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
        ISafeGas(safe).enableModule(address(roles));
    }

    function _addr(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Marks every shared contract the add path touches as cold (EIP-2929), so the next call pays cold access.
    function _coolShared(FundConfig fc, IRolesV2 roles) internal {
        vm.cool(address(fc));
        vm.cool(address(roles));
        vm.cool(address(registry));
        vm.cool(address(morpho));
        vm.cool(address(aave));
        vm.cool(USDC);
        vm.cool(MORPHO_VAULT);
        vm.cool(AAVE_DATA_PROVIDER);
        vm.cool(aavePool);
        vm.cool(ROLES_MASTERCOPY);
        vm.cool(ROLES_CREATE2);
        vm.cool(ROLES_PACKER);
        vm.cool(ROLES_INTEGRITY);
    }

    /// @dev Adds one position as the curator and returns the gas of the `addPosition` call only.
    function _add(FundConfig fc, IRolesV2 roles, IPositionModule module, bytes32 instance, bool cool)
        internal
        returns (uint256 gas)
    {
        bytes32 moduleId = module.moduleId();
        if (cool) _coolShared(fc, roles);
        vm.prank(curator);
        fc.addPosition(moduleId, instance);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    /// @dev Two funds, each with Morpho then Aave on USDC. `coolFirst`/`coolSecond` cool the shared state before each add.
    function _pair(uint256 saltFirst, uint256 saltSecond, string memory tag, bool coolFirst, bool coolSecond) internal {
        (FundConfig f1, IRolesV2 r1) = _newFund(saltFirst);
        uint256 a1 = _add(f1, r1, morpho, _addr(MORPHO_VAULT), coolFirst);
        uint256 a2 = _add(f1, r1, aave, _addr(USDC), coolFirst);

        (FundConfig f2, IRolesV2 r2) = _newFund(saltSecond);
        uint256 b1 = _add(f2, r2, morpho, _addr(MORPHO_VAULT), coolSecond);
        uint256 b2 = _add(f2, r2, aave, _addr(USDC), coolSecond);

        console2.log(string.concat("GASPROF ", tag, ".first.morpho"), a1);
        console2.log(string.concat("GASPROF ", tag, ".first.aave"), a2);
        console2.log(string.concat("GASPROF ", tag, ".second.morpho"), b1);
        console2.log(string.concat("GASPROF ", tag, ".second.aave"), b2);
        console2.log(string.concat("GASPROF ", tag, ".first.total"), a1 + a2);
        console2.log(string.concat("GASPROF ", tag, ".second.total"), b1 + b2);
    }

    // ---------------------------------------------------------------- T6 orderings and controls

    /// @notice T6 as written: fund A then fund B, warm access inherited from the earlier fund.
    function test_profile_T6_AB() public {
        _pair(60, 61, "AB", false, false);
    }

    /// @notice Swapped order: the same two identical configs with the salts exchanged.
    function test_profile_T6_BA() public {
        _pair(61, 60, "BA", false, false);
    }

    /// @notice Every add cools the shared state: second-fund savings here come only from Roles blob reuse.
    function test_profile_T6_allCooled() public {
        _pair(60, 61, "ALLCOOL", true, true);
    }

    /// @notice Only the second fund is cooled: the gap to AB is warm-access effect.
    function test_profile_T6_secondCooled() public {
        _pair(60, 61, "SECOOL", false, true);
    }

    // ---------------------------------------------------------------- scaling

    /// @notice N=1..8 Morpho positions on one fund, all on distinct mock vaults sharing `approve(USDC)`.
    function test_profile_scaling_N1toN8() public {
        (FundConfig fc, IRolesV2 roles) = _newFund(70);
        for (uint256 n = 1; n <= 8; ++n) {
            MockVault vault = new MockVault(USDC);
            uint256 gas = _add(fc, roles, morpho, _addr(address(vault)), false);
            console2.log(string.concat("GASPROF SCALE.N", vm.toString(n)), gas);
        }
    }
}
