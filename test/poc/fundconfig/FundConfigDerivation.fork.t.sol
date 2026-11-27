// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {
    ConditionFlat,
    ExecutionOptions,
    IModuleProxyFactory,
    IRolesV2,
    ParameterType
} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {MorphoVaultModule} from "poc/fundconfig/modules/MorphoVaultModule.sol";
import {AaveV3Module} from "poc/fundconfig/modules/AaveV3Module.sol";
import {AaveV3BorrowModule} from "poc/fundconfig/modules/AaveV3BorrowModule.sol";
import {SwapModule} from "poc/fundconfig/modules/SwapModule.sol";
import {NoPositionAdapter} from "poc/fundconfig/modules/swap/NoPositionAdapter.sol";
import {UniswapV3LpModule} from "poc/fundconfig/modules/UniswapV3LpModule.sol";
import {CurvePoolModule} from "poc/fundconfig/modules/CurvePoolModule.sol";
import {CurveGaugeModule} from "poc/fundconfig/modules/CurveGaugeModule.sol";
import {EtherFiAssistedModule} from "poc/fundconfig/modules/EtherFiAssistedModule.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
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

interface IAavePoolFork {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
}

interface IAaveDataProviderFork {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProviderFork {
    function getPool() external view returns (address);
}

interface IERC4626Fork {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface ISwapRouter02Fork {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

struct MintParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
}

interface INonfungiblePositionManagerFork {
    function mint(MintParams calldata p) external payable returns (uint256, uint128, uint256, uint256);
}

interface IUniswapV3PoolFork {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IEtherFiAssistantFork {
    function requestWithdraw(uint256 amount) external returns (uint256 requestId);
}

/// @notice Derivation dump: one fund declaring 8 positions over 7 position types on a mainnet fork at a pinned block.
/// @dev Writes `out/derivation-example.json` (declared positions, the Roles keys they derive, and the NAV read back
///      from `fundNav`). Every field is read from the contracts (`permissions`, `accounting`, `assets`, adapter
///      balances, `permissionSet`); the only hand-written values are the test's own labels and funding amounts.
contract FundConfigDerivationForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;
    string internal constant OUT_PATH = "out/derivation-example.json";

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant MORPHO_VAULT = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd;
    address internal constant MORPHO_ADAPTER = 0x72a012B30b240458C3f79fd20E5c2A907d77e54f;
    address internal constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant AAVE_ADAPTER = 0xa1b3c695A768A6Ce571fF699F463224CB32260C1;
    address internal constant ETHERFI_ADAPTER = 0xd074FAf8D8f2909BE3E6D51c219916065c5d870A;
    address internal constant ETHERFI_ASSISTANT = 0xD2EA372e6c1bA08cE3d20F4Ce69d68f13E1F92c4;
    address internal constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address internal constant EETH_WHALE = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes32 internal constant ROLE_KEY = keccak256("manager");

    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNI_ADAPTER = 0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52;
    address internal constant POOL_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant CURVE_POOL_ADAPTER = 0x4c25B00401d28d5F6FC65a7Af8386b239FA5e735;
    address internal constant CURVE_GAUGE_ADAPTER = 0xC0c22b89E9cC80a3891dF0ceF1e81b78b865F646;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant THREE_CRV = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address internal constant GAUGE = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant CRV_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    uint8 internal constant CALL = 0;
    uint8 internal constant DELEGATECALL = 1;
    bytes4 internal constant ADD3 = bytes4(keccak256("add_liquidity(uint256[3],uint256)"));
    bytes4 internal constant GAUGE_DEPOSIT = bytes4(keccak256("deposit(uint256)"));

    struct Decl {
        IPositionModule module;
        bytes32 instance;
        string moduleName;
        string instanceLabel;
        string kind;
    }

    address internal curator;
    address internal manager;
    address internal safeOwner;
    ModuleRegistry internal registry;
    MorphoVaultModule internal morpho;
    AaveV3Module internal aaveSupply;
    AaveV3BorrowModule internal aaveBorrow;
    SwapModule internal swap;
    UniswapV3LpModule internal uniLp;
    CurvePoolModule internal curvePool;
    CurveGaugeModule internal curveGauge;
    EtherFiAssistedModule internal etherfi;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        safeOwner = makeAddr("safeOwner");
        curator = makeAddr("curator");
        manager = makeAddr("manager");

        registry = new ModuleRegistry(address(this));
        morpho = new MorphoVaultModule(MORPHO_ADAPTER);
        aaveSupply = new AaveV3Module(keccak256("aave-v3-supply"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        aaveBorrow = new AaveV3BorrowModule(keccak256("aave-v3-borrow"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        swap = new SwapModule(
            keccak256("uniswap-v3-swap"), SWAP_ROUTER02, UNIV3_FACTORY, address(new NoPositionAdapter())
        );
        uniLp = new UniswapV3LpModule(UNI_ADAPTER, NPM, UNIV3_FACTORY);
        curvePool = new CurvePoolModule(CURVE_POOL_ADAPTER);
        curveGauge = new CurveGaugeModule(CURVE_GAUGE_ADAPTER);
        etherfi = new EtherFiAssistedModule(ETHERFI_ASSISTANT, ETHERFI_ADAPTER);

        registry.register(morpho);
        registry.register(aaveSupply);
        registry.register(aaveBorrow);
        registry.register(swap);
        registry.register(uniLp);
        registry.register(curvePool);
        registry.register(curveGauge);
        registry.register(etherfi);
    }

    /// @notice Declares the 8 positions, funds them through Roles, and writes the derivation dump.
    function test_derivationExample() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(77);
        Decl[] memory decls = _declarations();
        for (uint256 i; i < decls.length; ++i) {
            _addPosition(fc, decls[i].module, decls[i].instance);
        }
        assertEq(fc.positions().length, decls.length);
        _manager(fc);

        deal(USDC, safe, 10_000e6);
        deal(WETH, safe, 3 ether);
        _fundPositions(safe, roles);

        (string memory json, int256 positionSum, int256 navValue, bool navStale) =
            _document(safe, fc, roles, decls);
        assertEq(navValue, positionSum);
        vm.writeJson(json, OUT_PATH);
        assertFalse(navStale);
    }

    // ---------------------------------------------------------------- setup

    function _declarations() internal view returns (Decl[] memory d) {
        d = new Decl[](8);
        d[0] = Decl(IPositionModule(address(morpho)), _addr(MORPHO_VAULT), "MorphoVaultModule", "kpk_USDC_Prime", "morpho-vault");
        d[1] = Decl(IPositionModule(address(aaveSupply)), _addr(WETH), "AaveV3Module", "Aave V3 WETH supply (collateral)", "aave-v3-supply");
        d[2] = Decl(IPositionModule(address(aaveBorrow)), _addr(USDC), "AaveV3BorrowModule", "Aave V3 USDC borrow", "aave-v3-borrow");
        d[3] = Decl(IPositionModule(address(swap)), _addr(POOL_500), "SwapModule", "Uniswap V3 USDC/WETH 0.05% swap", "uniswap-v3-swap");
        d[4] = Decl(IPositionModule(address(uniLp)), _addr(POOL_500), "UniswapV3LpModule", "Uniswap V3 USDC/WETH 0.05% LP", "uniswap-v3-lp");
        d[5] = Decl(IPositionModule(address(curvePool)), _addr(THREE_POOL), "CurvePoolModule", "Curve 3pool", "curve-pool");
        d[6] = Decl(IPositionModule(address(curveGauge)), _addr(GAUGE), "CurveGaugeModule", "Curve 3pool gauge", "curve-gauge");
        d[7] = Decl(IPositionModule(address(etherfi)), _addr(ETHERFI_ASSISTANT), "EtherFiAssistedModule", "EtherFi withdrawal assistant", "etherfi-assisted");
    }

    function _fundPositions(address safe, IRolesV2 roles) internal {
        // Morpho vault: deposit 1,000 USDC.
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, 1000e6)), CALL);
        _exec(roles, MORPHO_VAULT, abi.encodeCall(IERC4626Fork.deposit, (1000e6, safe)), CALL);

        // Aave V3: USDC LTV is 0 at this block, so supply 1 WETH as collateral and borrow 100 USDC against it.
        address pool = _aavePool();
        _exec(roles, WETH, abi.encodeCall(IERC20.approve, (pool, 1 ether)), CALL);
        _exec(roles, pool, abi.encodeCall(IAavePoolFork.supply, (WETH, 1 ether, safe, 0)), CALL);
        _exec(roles, pool, abi.encodeCall(IAavePoolFork.borrow, (USDC, 100e6, 2, 0, safe)), CALL);

        // Uniswap V3 swap: 500 USDC -> WETH through SwapRouter02 on the 0.05% pool.
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 500e6)), CALL);
        ISwapRouter02Fork.ExactInputSingleParams memory p = ISwapRouter02Fork.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: 500,
            recipient: safe,
            amountIn: 500e6,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        _exec(roles, SWAP_ROUTER02, abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (p)), CALL);

        // Uniswap V3 LP: mint a USDC/WETH 0.05% position owned by the Safe.
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (NPM, type(uint256).max)), CALL);
        _exec(roles, WETH, abi.encodeCall(IERC20.approve, (NPM, type(uint256).max)), CALL);
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.mint, (_mintParams(POOL_500, 500, safe))), CALL);

        // Curve 3pool: add 1,000 USDC, then stake the 3Crv LP in the gauge.
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (THREE_POOL, 1000e6)), CALL);
        uint256[3] memory amounts;
        amounts[1] = 1000e6;
        _exec(roles, THREE_POOL, abi.encodeWithSelector(ADD3, amounts, uint256(0)), CALL);
        uint256 lp = IERC20(THREE_CRV).balanceOf(safe);
        _exec(roles, THREE_CRV, abi.encodeCall(IERC20.approve, (GAUGE, lp)), CALL);
        _exec(roles, GAUGE, abi.encodeWithSelector(GAUGE_DEPOSIT, lp), CALL);

        // EtherFi: request a withdrawal of 5 eETH through the assistant (delegatecall).
        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(safe, 10 ether);
        _exec(roles, ETHERFI_ASSISTANT, abi.encodeCall(IEtherFiAssistantFork.requestWithdraw, (5 ether)), DELEGATECALL);
    }

    // ---------------------------------------------------------------- document

    function _document(address safe, FundConfig fc, IRolesV2 roles, Decl[] memory decls)
        internal
        view
        returns (string memory json, int256 positionSum, int256 navValue, bool navStale)
    {
        string memory positions_;
        for (uint256 i; i < decls.length; ++i) {
            (string memory pj, int256 net,) = _positionJson(i, safe, decls[i]);
            positions_ = _add(positions_, pj);
            positionSum += net;
        }
        int256 walletNet = _walletNet(decls, safe);
        positionSum += walletNet;

        PermissionLeaf[] memory leaves = fc.permissionSet();
        (string memory keys, uint256 keyCount) = _rolesKeysJson(leaves);

        (navValue, navStale) = fc.fundNav(USDC);

        string memory meta = _obj(
            string.concat(
                _kv("schema", _q("fundconfig-derivation/v1")),
                ",",
                _kv("chainId", vm.toString(block.chainid)),
                ",",
                _kv("forkBlock", vm.toString(FORK_BLOCK)),
                ",",
                _kv("quoteAsset", _q(vm.toString(USDC))),
                ",",
                _kv("positionCount", vm.toString(decls.length)),
                ",",
                _kv("rolesKeyCount", vm.toString(keyCount)),
                ",",
                _kv("leafCount", vm.toString(leaves.length))
            )
        );

        string memory fund = _obj(
            string.concat(
                _kv("fundConfig", _q(vm.toString(address(fc)))),
                ",",
                _kv("safe", _q(vm.toString(safe))),
                ",",
                _kv("roles", _q(vm.toString(address(roles)))),
                ",",
                _kv("curator", _q(vm.toString(fc.CURATOR()))),
                ",",
                _kv("manager", _q(vm.toString(manager))),
                ",",
                _kv("roleKey", _q(vm.toString(ROLE_KEY))),
                ",",
                _kv("registry", _q(vm.toString(address(fc.REGISTRY())))),
                ",",
                _kv("navCalculator", _q(vm.toString(address(fc.NAV_CALCULATOR()))))
            )
        );

        string memory nav = _obj(
            string.concat(
                _kv("quoteAsset", _q(vm.toString(USDC))),
                ",",
                _kv("fundNav", vm.toString(navValue)),
                ",",
                _kv("stale", vm.toString(navStale)),
                ",",
                _kv("walletNet", vm.toString(walletNet)),
                ",",
                _kv("sumOfNet", vm.toString(positionSum))
            )
        );

        json = _obj(
            string.concat(
                _kv("meta", meta),
                ",",
                _kv("fund", fund),
                ",",
                _kv("positions", _arr(positions_)),
                ",",
                _kv("rolesKeys", keys),
                ",",
                _kv("nav", nav)
            )
        );
    }

    function _positionJson(uint256 idx, address safe, Decl memory d)
        internal
        view
        returns (string memory json, int256 net, bool stale)
    {
        Accounting memory acc = d.module.accounting(d.instance);
        (string memory bals, int256 n, bool s) = _balancesJson(d.module, d.instance, safe);

        string memory body = _kv("index", vm.toString(idx));
        body = _add(body, _kv("kind", _q(d.kind)));
        body = _add(body, _kv("moduleName", _q(d.moduleName)));
        body = _add(body, _kv("moduleId", _q(vm.toString(d.module.moduleId()))));
        body = _add(body, _kv("instance", _q(vm.toString(d.instance))));
        body = _add(body, _kv("instanceLabel", _q(d.instanceLabel)));
        body = _add(body, _kv("accounting", _accountingJson(acc)));
        body = _add(body, _kv("assets", _assetsJson(d.module, d.instance)));
        body = _add(body, _kv("leaves", _leavesJson(d.module, d.instance)));
        body = _add(body, _kv("balances", bals));
        body = _add(body, _kv("netValue", vm.toString(n)));
        body = _add(body, _kv("stale", vm.toString(s)));

        json = _obj(body);
        net = n;
        stale = s;
    }

    function _accountingJson(Accounting memory a) internal pure returns (string memory) {
        string memory body = _kv("adapter", _q(vm.toString(a.adapter)));
        body = _add(body, _kv("isMeta", vm.toString(a.isMeta)));
        body = _add(body, _kv("coordinate", _q(vm.toString(a.coordinate))));
        body = _add(body, _kv("assetFilter", _q(vm.toString(a.assetFilter))));
        return _obj(body);
    }

    function _assetsJson(IPositionModule module, bytes32 instance) internal view returns (string memory) {
        address[] memory assets = module.assets(instance);
        string memory out;
        for (uint256 i; i < assets.length; ++i) {
            string memory body = _kv("asset", _q(vm.toString(assets[i])));
            body = _add(body, _kv("label", _q(_label(assets[i]))));
            out = _add(out, _obj(body));
        }
        return _arr(out);
    }

    function _leavesJson(IPositionModule module, bytes32 instance) internal view returns (string memory) {
        PermissionLeaf[] memory leaves = module.permissions(instance);
        string memory out;
        for (uint256 i; i < leaves.length; ++i) {
            out = _add(out, _leafJson(leaves[i]));
        }
        return _arr(out);
    }

    function _leafJson(PermissionLeaf memory leaf) internal view returns (string memory) {
        string memory conds;
        for (uint256 j; j < leaf.conditions.length; ++j) {
            conds = _add(conds, _conditionJson(leaf.conditions[j]));
        }
        string memory body = _kv("target", _q(vm.toString(leaf.target)));
        body = _add(body, _kv("targetLabel", _q(_label(leaf.target))));
        body = _add(body, _kv("selector", _q(vm.toString(abi.encodePacked(leaf.selector)))));
        body = _add(body, _kv("signature", _q(_signatureOf(leaf.selector))));
        body = _add(body, _kv("options", _q(_optionsName(leaf.options))));
        body = _add(body, _kv("conditions", _arr(conds)));
        return _obj(body);
    }

    function _conditionJson(ConditionFlat memory c) internal pure returns (string memory) {
        string memory body = _kv("parent", vm.toString(uint256(c.parent)));
        body = _add(body, _kv("paramType", _q(_paramTypeName(c.paramType))));
        body = _add(body, _kv("operator", vm.toString(uint256(c.operator))));
        body = _add(body, _kv("operatorName", _q(_opName(c.operator))));
        body = _add(body, _kv("compValue", _q(vm.toString(c.compValue))));
        return _obj(body);
    }

    function _balancesJson(IPositionModule module, bytes32 instance, address safe)
        internal
        view
        returns (string memory out, int256 net, bool stale)
    {
        INAVCalculator.PositionBalance[] memory bals = _balances(module, instance, safe);
        for (uint256 i; i < bals.length; ++i) {
            INAVCalculator.PositionBalance memory b = bals[i];
            int256 signed;
            bool s;
            if (b.amount != 0) {
                (int256 v, bool vs) = _price(b.balanceAsset.asset, b.amount);
                signed = b.isDebt ? -v : v;
                s = vs;
            }
            net += signed;
            stale = stale || s;

            string memory body = _kv("asset", _q(vm.toString(b.balanceAsset.asset)));
            body = _add(body, _kv("symbol", _q(b.balanceAsset.symbol)));
            body = _add(body, _kv("amount", vm.toString(b.amount)));
            body = _add(body, _kv("isDebt", vm.toString(b.isDebt)));
            body = _add(body, _kv("protocolId", _q(vm.toString(b.protocolId))));
            body = _add(body, _kv("protocolSubId", _q(vm.toString(b.protocolSubId))));
            body = _add(body, _kv("positionKind", _q(_kindName(uint8(b.positionKind)))));
            body = _add(body, _kv("isLocked", vm.toString(b.isLocked)));
            body = _add(body, _kv("value", vm.toString(signed)));
            body = _add(body, _kv("stale", vm.toString(s)));
            out = _add(out, _obj(body));
        }
        out = _arr(out);
    }

    /// @dev One entry per distinct (target, selector) in the raw leaf set, with the merge decision FundConfig makes
    ///      in `_writeKey`: any unconditional leaf means `allowFunction`, otherwise `scopeFunction` with one tree
    ///      (single conditional leaf) or the OR of all conditional trees.
    function _rolesKeysJson(PermissionLeaf[] memory leaves) internal view returns (string memory out, uint256 count) {
        for (uint256 i; i < leaves.length; ++i) {
            if (_seenBefore(leaves, i)) continue;
            out = _add(out, _keyJson(leaves, leaves[i].target, leaves[i].selector));
            ++count;
        }
        out = _arr(out);
    }

    function _seenBefore(PermissionLeaf[] memory leaves, uint256 i) internal pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (leaves[j].target == leaves[i].target && leaves[j].selector == leaves[i].selector) return true;
        }
        return false;
    }

    function _keyJson(PermissionLeaf[] memory leaves, address target, bytes4 selector)
        internal
        view
        returns (string memory)
    {
        uint256 leafCount;
        uint256 conditionalCount;
        bool unconditional;
        bool optSet;
        ExecutionOptions opts;
        for (uint256 j; j < leaves.length; ++j) {
            PermissionLeaf memory leaf = leaves[j];
            if (leaf.target != target || leaf.selector != selector) continue;
            ++leafCount;
            if (!optSet) {
                opts = leaf.options;
                optSet = true;
            } else if (leaf.options != opts) {
                revert("options mismatch within a roles key");
            }
            if (leaf.conditions.length == 0) {
                unconditional = true;
            } else {
                ++conditionalCount;
            }
        }

        string memory body = _kv("target", _q(vm.toString(target)));
        body = _add(body, _kv("targetLabel", _q(_label(target))));
        body = _add(body, _kv("selector", _q(vm.toString(abi.encodePacked(selector)))));
        body = _add(body, _kv("signature", _q(_signatureOf(selector))));
        body = _add(body, _kv("options", _q(_optionsName(opts))));
        body = _add(body, _kv("leafCount", vm.toString(leafCount)));
        body = _add(body, _kv("conditionalLeafCount", vm.toString(conditionalCount)));
        body = _add(body, _kv("unconditionalLeaf", vm.toString(unconditional)));
        body = _add(
            body, _kv("roleCall", _q(unconditional ? "allowFunction" : "scopeFunction"))
        );
        string memory merge = unconditional ? "none" : (conditionalCount == 1 ? "single" : "or");
        body = _add(body, _kv("conditionMerge", _q(merge)));
        return _obj(body);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Mirrors FundConfig's wallet term: deduplicated union of `assets()` across declared positions, valued at the Safe's holdings.
    function _walletNet(Decl[] memory decls, address safe) internal view returns (int256 net) {
        address nativeEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        uint256 cap;
        address[][] memory perDecl = new address[][](decls.length);
        for (uint256 i; i < decls.length; ++i) {
            perDecl[i] = decls[i].module.assets(decls[i].instance);
            cap += perDecl[i].length;
        }
        address[] memory tokens = new address[](cap);
        uint256 n;
        for (uint256 i; i < perDecl.length; ++i) {
            for (uint256 j; j < perDecl[i].length; ++j) {
                address t = perDecl[i][j];
                bool seen;
                for (uint256 k; k < n; ++k) {
                    if (tokens[k] == t) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) tokens[n++] = t;
            }
        }
        for (uint256 k; k < n; ++k) {
            uint256 bal = tokens[k] == nativeEth ? safe.balance : IERC20(tokens[k]).balanceOf(safe);
            if (bal == 0) continue;
            (int256 v,) = _price(tokens[k], bal);
            net += v;
        }
    }

    function _balances(IPositionModule module, bytes32 instance, address safe)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        Accounting memory a = module.accounting(instance);
        if (a.isMeta) {
            bytes32[] memory instances = new bytes32[](1);
            instances[0] = a.coordinate;
            return IMetaBalanceAdapter(a.adapter).getAdapterPositionsForInstances(safe, instances, a.assetFilter);
        }
        return IBalanceAdapter(a.adapter).getAdapterPositions(safe, a.assetFilter);
    }

    function _price(address asset, uint256 amount) internal view returns (int256, bool) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        return INAVCalculator(NAV_PROXY).calculateValue(assets, amounts, USDC);
    }

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

    function _addr(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _tick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3PoolFork(pool).slot0();
    }

    /// @dev Full-range-ish position (±600 ticks around the current tick, aligned to the fee tier's tickSpacing).
    function _mintParams(address pool, uint24 fee, address recipient) internal view returns (MintParams memory p) {
        int24 spacing = fee == 500 ? int24(10) : int24(60);
        int24 base = (_tick(pool) / spacing) * spacing;
        p = MintParams({
            token0: USDC,
            token1: WETH,
            fee: fee,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0Desired: 1_000e6,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 1 hours
        });
    }

    function _label(address a) internal view returns (string memory) {
        if (a == USDC) return "USDC";
        if (a == WETH) return "WETH";
        if (a == DAI) return "DAI";
        if (a == USDT) return "USDT";
        if (a == CRV) return "CRV";
        if (a == THREE_CRV) return "3Crv";
        if (a == EETH) return "eETH";
        if (a == MORPHO_VAULT) return "kpk_USDC_Prime (Morpho vault)";
        if (a == THREE_POOL) return "Curve 3pool";
        if (a == GAUGE) return "Curve 3pool gauge";
        if (a == CRV_MINTER) return "Curve CRV minter";
        if (a == NPM) return "Uniswap V3 NonfungiblePositionManager";
        if (a == SWAP_ROUTER02) return "Uniswap SwapRouter02";
        if (a == POOL_500) return "Uniswap V3 USDC/WETH 0.05%";
        if (a == ETHERFI_ASSISTANT) return "EtherFi withdrawal assistant";
        if (a == _aavePool()) return "Aave V3 Pool";
        return vm.toString(a);
    }

    function _signatureOf(bytes4 sel) internal pure returns (string memory) {
        string[20] memory sigs = [
            "approve(address,uint256)",
            "deposit(uint256,address)",
            "redeem(uint256,address,address)",
            "withdraw(uint256,address,address)",
            "supply(address,uint256,address,uint16)",
            "withdraw(address,uint256,address)",
            "borrow(address,uint256,uint256,uint16,address)",
            "repay(address,uint256,uint256,address)",
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
            "increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))",
            "decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))",
            "collect((uint256,address,uint128,uint128))",
            "add_liquidity(uint256[3],uint256)",
            "remove_liquidity(uint256,uint256[3])",
            "deposit(uint256)",
            "withdraw(uint256)",
            "mint(address)",
            "requestWithdraw(uint256)",
            "claimWithdraw(uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            if (bytes4(keccak256(bytes(sigs[i]))) == sel) return sigs[i];
        }
        revert("selector not in signature table");
    }

    function _paramTypeName(ParameterType t) internal pure returns (string memory) {
        string[7] memory names = ["None", "Static", "Dynamic", "Tuple", "Array", "Calldata", "AbiEncoded"];
        return names[uint8(t)];
    }

    function _optionsName(ExecutionOptions o) internal pure returns (string memory) {
        string[4] memory names = ["None", "Send", "DelegateCall", "Both"];
        return names[uint8(o)];
    }

    function _opName(uint8 op) internal pure returns (string memory) {
        if (op == 0) return "PASS";
        if (op == 2) return "OR";
        if (op == 5) return "MATCHES";
        if (op == 15) return "EQUAL_TO_AVATAR";
        if (op == 16) return "EQUAL_TO";
        if (op == 22) return "CUSTOM";
        return "UNNAMED";
    }

    function _kindName(uint8 k) internal pure returns (string memory) {
        string[7] memory names = ["Wallet", "Supplied", "Borrowed", "Collateral", "Staking", "Rewards", "Fees"];
        return names[k];
    }

    // JSON assembly. forge-std's serializeJson replaces the whole object, so nested objects are concatenated here
    // and the finished document is written with vm.writeJson.

    function _add(string memory body, string memory item) internal pure returns (string memory) {
        if (bytes(body).length == 0) return item;
        return string.concat(body, ",", item);
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

    function _kv(string memory k, string memory raw) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", raw);
    }

    function _obj(string memory body) internal pure returns (string memory) {
        return string.concat("{", body, "}");
    }

    function _arr(string memory body) internal pure returns (string memory) {
        return string.concat("[", body, "]");
    }
}
