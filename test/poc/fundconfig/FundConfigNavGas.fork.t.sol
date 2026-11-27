// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {IPositionModule} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {MorphoVaultModule} from "poc/fundconfig/modules/MorphoVaultModule.sol";
import {AaveV3Module} from "poc/fundconfig/modules/AaveV3Module.sol";
import {CurveGaugeModule} from "poc/fundconfig/modules/CurveGaugeModule.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface ISafeNavGas {
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

interface ISafeProxyFactoryNavGas {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface IERC4626NavGas {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface IAavePoolNavGas {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveDataProviderNavGas {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProviderNavGas {
    function getPool() external view returns (address);
}

/// @notice NAV-read gas on a mainnet fork: `fundNav` (FundConfig) and `getAccountNav` (NAVCalculator, production
///         accounts), plus the CRV staleness control for findings-curve-crv.md section 2.
/// @dev Cold = every address the read touches that we can name is `vm.cool`ed right before the call. Feed contracts are
///      not named, so they keep whatever warmth the fork gives them. Warm = the identical call repeated.
contract FundConfigNavGasForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;
    uint256 internal constant PROD_BLOCK = 26_500_000; // NAV proxy absent at 25_735_412; same block as FORK_BLOCK

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant MORPHO_VAULT = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd; // kpk_USDC_Prime
    address internal constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant MORPHO_ADAPTER = 0x72a012B30b240458C3f79fd20E5c2A907d77e54f; // MorphoVaultsMeta
    address internal constant AAVE_ADAPTER = 0xa1b3c695A768A6Ce571fF699F463224CB32260C1; // AaveV3InstancesMeta
    address internal constant CURVE_GAUGE_ADAPTER = 0xC0c22b89E9cC80a3891dF0ceF1e81b78b865F646; // CurveGaugesMeta
    address internal constant GAUGE = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;
    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // Production accounts from test/integration/accounts.json (chain 1). Quote = USD (address(0)).
    address internal constant ACCOUNT_2 = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b;
    address internal constant ACCOUNT_9 = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    address internal constant ACCOUNT_10 = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;

    bytes32 internal constant ROLE_KEY = keccak256("manager");
    uint8 internal constant CALL = 0;

    address internal safeOwner;
    address internal curator;
    address internal manager;
    ModuleRegistry internal registry;
    MorphoVaultModule internal morpho;
    AaveV3Module internal aave;
    CurveGaugeModule internal curveGauge;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        safeOwner = makeAddr("safeOwner");
        curator = makeAddr("curator");
        manager = makeAddr("manager");

        registry = new ModuleRegistry(address(this));
        morpho = new MorphoVaultModule(MORPHO_ADAPTER);
        aave = new AaveV3Module(keccak256("aave-v3-usdc"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        curveGauge = new CurveGaugeModule(CURVE_GAUGE_ADAPTER);
        registry.register(morpho);
        registry.register(aave);
        registry.register(curveGauge);
    }

    // ---------------------------------------------------------------- helpers

    function _newFund(uint256 saltNonce) internal returns (address safe, FundConfig fc, IRolesV2 roles) {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner;
        bytes memory init = abi.encodeCall(
            ISafeNavGas.setup,
            (owners, 1, address(0), "", FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactoryNavGas(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, saltNonce);

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
        ISafeNavGas(safe).enableModule(address(roles));
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
        return IAavePoolAddressesProviderNavGas(
            IAaveDataProviderNavGas(AAVE_DATA_PROVIDER).ADDRESSES_PROVIDER()
        ).getPool();
    }

    /// @dev The first 12 `MorphoVaultsMeta` instances from script/config/nav-config/meta-balance-adapters/1.json.
    function _morphoVaults() internal pure returns (address[] memory v) {
        v = new address[](12);
        v[0] = 0xd564F765F9aD3E7d2d6cA782100795a885e8e7C8;
        v[1] = 0xBb50A5341368751024ddf33385BA8cf61fE65FF9;
        v[2] = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd;
        v[3] = 0x4Ef53d2cAa51C447fdFEEedee8F07FD1962C9ee6;
        v[4] = 0xa877D5bb0274dcCbA8556154A30E1Ca4021a275f;
        v[5] = 0xD5cCe260E7a755DDf0Fb9cdF06443d593AaeaA13;
        v[6] = 0x870F0BF29A25A40E7CC087cD5C53e70C11F2C8A8;
        v[7] = 0x5dbf760b4fd0cDdDe0366b33aEb338b2A6d77725;
        v[8] = 0x1a1985F50352b58090eb36425AfdFacbaC7806F4;
        v[9] = 0x7a72bcD2c3F7F7e4D6679170a0625bAB15D7DDa1;
        v[10] = 0xb5ce3CA2C774b72955C25875022FdD91f7a7B938;
        v[11] = 0x355A1c6A3f1946d4DbD7cE932492925AB9F261a7;
    }

    /// @dev Cools the named addresses, then reads `fundNav(USDC)` twice. Returns cold and warm gas plus the stale flag.
    function _measure(string memory tag, FundConfig fc, address safe, address[] memory extra)
        internal
        returns (uint256 cold, uint256 warm, int256 value, bool stale)
    {
        address[] memory fixedSet = new address[](8);
        fixedSet[0] = address(fc);
        fixedSet[1] = safe;
        fixedSet[2] = NAV_PROXY;
        fixedSet[3] = MORPHO_ADAPTER;
        fixedSet[4] = AAVE_ADAPTER;
        fixedSet[5] = CURVE_GAUGE_ADAPTER;
        fixedSet[6] = USDC;
        fixedSet[7] = CRV_TOKEN;
        for (uint256 i; i < fixedSet.length; ++i) {
            vm.cool(fixedSet[i]);
        }
        for (uint256 i; i < extra.length; ++i) {
            vm.cool(extra[i]);
        }

        (value, stale) = fc.fundNav(USDC);
        cold = vm.lastCallGas().gasTotalUsed;
        (value, stale) = fc.fundNav(USDC);
        warm = vm.lastCallGas().gasTotalUsed;

        console2.log(string.concat("GASNAV ", tag, " cold"), cold);
        console2.log(string.concat("GASNAV ", tag, " warm"), warm);
        console2.log(string.concat("GASNAV ", tag, " value"), value);
        console2.log(string.concat("GASNAV ", tag, " stale"), stale);
    }

    // ---------------------------------------------------------------- CRV staleness control

    /// @notice CRV held, gauge declared, fresh at the fork block, then +1 day with no new feed round.
    /// @dev Confirms or refutes findings-curve-crv.md section 2.
    function test_CRV_stalenessControl_crvHeld() public {
        (address safe, FundConfig fc,) = _newFund(400);
        deal(CRV_TOKEN, safe, 1_000e18);
        _addPosition(fc, curveGauge, _addr(GAUGE));

        (, bool staleBefore) = fc.fundNav(USDC);
        assertFalse(staleBefore, "CRV fresh at fork block");

        vm.warp(block.timestamp + 1 days);
        (, bool staleAfter) = fc.fundNav(USDC);
        assertTrue(staleAfter, "CRV stale after +1 day");

        console2.log("GASNAV CRV_control.crvHeld.staleBefore", staleBefore);
        console2.log("GASNAV CRV_control.crvHeld.staleAfter1d", staleAfter);
    }

    /// @notice Isolation control: the same warp with USDC held instead of CRV. If this is stale too, the USDC
    ///         price or quote feed, not CRV, drives the held-CRV result.
    function test_CRV_stalenessControl_usdcHeld() public {
        (address safe, FundConfig fc,) = _newFund(401);
        deal(USDC, safe, 1_000e6);
        _addPosition(fc, morpho, _addr(MORPHO_VAULT));

        (, bool staleBefore) = fc.fundNav(USDC);
        assertFalse(staleBefore, "USDC fresh at fork block");

        vm.warp(block.timestamp + 1 days);
        (, bool staleAfter) = fc.fundNav(USDC);

        console2.log("GASNAV CRV_control.usdcHeld.staleBefore", staleBefore);
        console2.log("GASNAV CRV_control.usdcHeld.staleAfter1d", staleAfter);
    }

    // ---------------------------------------------------------------- fundNav cost

    /// @notice fundNav scaling with N zero-balance Morpho positions (real MorphoVaultsMeta instances).
    function test_fundNav_scalingMorpho() public {
        address[] memory vaults = _morphoVaults();
        uint256[5] memory ns = [uint256(0), 1, 2, 4, 8];
        for (uint256 k; k < ns.length; ++k) {
            uint256 n = ns[k];
            (address safe, FundConfig fc,) = _newFund(500 + n);
            _manager(fc);
            address[] memory extra = new address[](n);
            for (uint256 i; i < n; ++i) {
                _addPosition(fc, morpho, _addr(vaults[i]));
                extra[i] = vaults[i];
            }
            _measure(string.concat("scale.morpho.N", vm.toString(n)), fc, safe, extra);
        }
        // N=12 (full MorphoVaultsMeta set) on one fund.
        (address safe12, FundConfig fc12,) = _newFund(512);
        address[] memory all = new address[](12);
        for (uint256 i; i < 12; ++i) {
            _addPosition(fc12, morpho, _addr(vaults[i]));
            all[i] = vaults[i];
        }
        _measure("scale.morpho.N12", fc12, safe12, all);
    }

    /// @notice Per-type cost, funded: one Morpho vault position with a deposit, read with USDC as the quote.
    function test_fundNav_morphoFunded() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(600);
        deal(USDC, safe, 100_000e6);
        _addPosition(fc, morpho, _addr(MORPHO_VAULT));
        _manager(fc);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 100_000e6)), CALL);
        _exec(roles, MORPHO_VAULT, abi.encodeCall(IERC4626NavGas.deposit, (100_000e6, safe)), CALL);

        address[] memory extra = new address[](1);
        extra[0] = MORPHO_VAULT;
        (,, int256 value, bool stale) = _measure("type.morpho.funded", fc, safe, extra);
        assertGt(value, 0);
        assertFalse(stale);
    }

    /// @notice Per-type cost, funded: one Aave V3 USDC supply position, read with USDC as the quote.
    function test_fundNav_aaveFunded() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(601);
        deal(USDC, safe, 100_000e6);
        _addPosition(fc, aave, _addr(USDC));
        _manager(fc);

        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), 100_000e6)), CALL);
        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolNavGas.supply, (USDC, 100_000e6, safe, 0)), CALL);

        address[] memory extra = new address[](0);
        (,, int256 value, bool stale) = _measure("type.aave.funded", fc, safe, extra);
        assertGt(value, 0);
        assertFalse(stale);
    }

    /// @notice Per-type cost, zero-balance: one CurveGaugesMeta position (gauge declared, no stake).
    function test_fundNav_curveGaugeZero() public {
        (address safe, FundConfig fc,) = _newFund(602);
        _addPosition(fc, curveGauge, _addr(GAUGE));

        address[] memory extra = new address[](1);
        extra[0] = GAUGE;
        _measure("type.curveGauge.zero", fc, safe, extra);
    }

    // ---------------------------------------------------------------- production accounts

    /// @notice getAccountNav for the three largest production accounts, each on a fresh fork at PROD_BLOCK.
    ///         Each account is read cold (fresh fork) and then warm (repeat). Quote = USD.
    function test_prodNav_accounts() public {
        address[3] memory accounts = [ACCOUNT_2, ACCOUNT_9, ACCOUNT_10];
        string[3] memory tags = ["account2", "account9", "account10"];
        for (uint256 k; k < accounts.length; ++k) {
            createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), PROD_BLOCK);
            INAVCalculator nav = INAVCalculator(NAV_PROXY);

            INAVCalculator.NAV memory n = nav.getAccountNav(accounts[k], address(0));
            uint256 cold = vm.lastCallGas().gasTotalUsed;
            nav.getAccountNav(accounts[k], address(0));
            uint256 warm = vm.lastCallGas().gasTotalUsed;

            console2.log(string.concat("GASNAV prod.", tags[k], " cold"), cold);
            console2.log(string.concat("GASNAV prod.", tags[k], " warm"), warm);
            console2.log(string.concat("GASNAV prod.", tags[k], " value"), n.value);
            console2.log(string.concat("GASNAV prod.", tags[k], " quoteAssetStale"), n.quoteAssetStale);
            console2.log(string.concat("GASNAV prod.", tags[k], " stalePriceAssets"), n.stalePriceAssets.length);
        }
    }
}
