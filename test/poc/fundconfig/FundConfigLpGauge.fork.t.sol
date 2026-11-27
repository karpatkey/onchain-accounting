// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {IPositionModule} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {UniswapV3LpModule} from "poc/fundconfig/modules/UniswapV3LpModule.sol";
import {CurvePoolModule} from "poc/fundconfig/modules/CurvePoolModule.sol";
import {CurveGaugeModule} from "poc/fundconfig/modules/CurveGaugeModule.sol";
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

struct IncreaseParams {
    uint256 tokenId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

struct DecreaseParams {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
}

interface INonfungiblePositionManagerFork {
    function mint(MintParams calldata p) external payable returns (uint256, uint128, uint256, uint256);
    function increaseLiquidity(IncreaseParams calldata p) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseParams calldata p) external payable returns (uint256, uint256);
    function collect(CollectParams calldata p) external payable returns (uint256, uint256);
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

interface IUniswapV3PoolFork {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface ICurveGaugeFork {
    function balanceOf(address account) external view returns (uint256);
}

contract FundConfigLpGaugeForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Uniswap V3 (mainnet). Pools: USDC/WETH 0.05% (declared) and USDC/WETH 0.3% (undeclared).
    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNI_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNI_ADAPTER = 0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52; // UniswapV3PoolsMeta
    address internal constant POOL_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant POOL_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    // Curve 3pool + gauge (mainnet).
    address internal constant CURVE_POOL_ADAPTER = 0x4c25B00401d28d5F6FC65a7Af8386b239FA5e735; // CurvePoolsMeta
    address internal constant CURVE_GAUGE_ADAPTER = 0xC0c22b89E9cC80a3891dF0ceF1e81b78b865F646; // CurveGaugesMeta
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant THREE_CRV = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address internal constant GAUGE = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;

    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bytes32 internal constant ROLE_KEY = keccak256("manager");
    uint8 internal constant CALL = 0;

    bytes4 internal constant ADD3 = bytes4(keccak256("add_liquidity(uint256[3],uint256)"));
    bytes4 internal constant REMOVE3 = bytes4(keccak256("remove_liquidity(uint256,uint256[3])"));
    bytes4 internal constant GAUGE_DEPOSIT = bytes4(keccak256("deposit(uint256)"));
    bytes4 internal constant GAUGE_WITHDRAW = bytes4(keccak256("withdraw(uint256)"));
    bytes4 internal constant MINT_CRV = bytes4(keccak256("mint(address)"));
    address internal constant CRV_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;
    address internal constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    address internal curator;
    address internal manager;
    address internal other;
    ModuleRegistry internal registry;
    UniswapV3LpModule internal uniModule;
    CurvePoolModule internal curvePoolModule;
    CurveGaugeModule internal curveGaugeModule;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        curator = makeAddr("curator");
        manager = makeAddr("manager");
        other = makeAddr("other");

        registry = new ModuleRegistry(address(this));
        uniModule = new UniswapV3LpModule(UNI_ADAPTER, NPM, UNI_FACTORY);
        curvePoolModule = new CurvePoolModule(CURVE_POOL_ADAPTER);
        curveGaugeModule = new CurveGaugeModule(CURVE_GAUGE_ADAPTER);
        registry.register(uniModule);
        registry.register(curvePoolModule);
        registry.register(curveGaugeModule);
    }

    // ---------------------------------------------------------------- helpers

    function _newFund(uint256 saltNonce) internal returns (address safe, FundConfig fc, IRolesV2 roles) {
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("safeOwner");
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

    function _approve(IRolesV2 roles, address token, address spender, uint256 amount) internal {
        _exec(roles, token, abi.encodeCall(IERC20.approve, (spender, amount)), CALL);
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

    /// @dev Mints a USDC/WETH NFT from an EOA (not the Safe), so ownership is set up outside the fund.
    function _eoaMint(uint24 fee, address recipient) internal returns (uint256 tokenId) {
        deal(USDC, other, 2_000e6);
        deal(WETH, other, 2 ether);
        vm.startPrank(other);
        IERC20(USDC).approve(NPM, type(uint256).max);
        IERC20(WETH).approve(NPM, type(uint256).max);
        (tokenId,,,) = INonfungiblePositionManagerFork(NPM).mint(_mintParams(POOL_500, fee, recipient));
        vm.stopPrank();
    }

    function _lastNftOf(address owner) internal view returns (uint256) {
        uint256 n = INonfungiblePositionManagerFork(NPM).balanceOf(owner);
        return INonfungiblePositionManagerFork(NPM).tokenOfOwnerByIndex(owner, n - 1);
    }

    // ---------------------------------------------------------------- Uniswap V3 LP

    /// @notice mint / increase / decrease / collect through Roles on a declared pool; NFT is Safe-owned.
    function test_UNI_lifecycleAllowed() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(10);
        deal(USDC, safe, 2_000e6);
        deal(WETH, safe, 2 ether);
        _addPosition(fc, uniModule, _addr(POOL_500));
        _manager(fc);

        _approve(roles, USDC, NPM, type(uint256).max);
        _approve(roles, WETH, NPM, type(uint256).max);

        MintParams memory mp = _mintParams(POOL_500, 500, safe);
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.mint, (mp)), CALL);
        uint256 tokenId = _lastNftOf(safe);
        assertEq(INonfungiblePositionManagerFork(NPM).ownerOf(tokenId), safe);

        IncreaseParams memory ip = IncreaseParams({
            tokenId: tokenId,
            amount0Desired: 500e6,
            amount1Desired: 0.25 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.increaseLiquidity, (ip)), CALL);
        console2.log("uni increaseLiquidity via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);

        (,,,,,,,uint128 liq,,,,) = INonfungiblePositionManagerFork(NPM).positions(tokenId);
        DecreaseParams memory dp = DecreaseParams({
            tokenId: tokenId,
            liquidity: liq / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.decreaseLiquidity, (dp)), CALL);
        console2.log("uni decreaseLiquidity via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);

        uint256 usdcBefore = IERC20(USDC).balanceOf(safe);
        CollectParams memory cp = CollectParams({
            tokenId: tokenId,
            recipient: safe,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.collect, (cp)), CALL);
        console2.log("uni collect via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);
        assertGt(IERC20(USDC).balanceOf(safe), usdcBefore);

        // Direct Custom-condition cost: the checker as called by the Roles clone (msg.sender = roles).
        bytes memory data = abi.encodeCall(
            INonfungiblePositionManagerFork.increaseLiquidity,
            (IncreaseParams(tokenId, 1, 1, 0, 0, block.timestamp + 1 hours))
        );
        vm.prank(address(roles));
        uint256 g0 = gasleft();
        (bool ok,) = uniModule.check(NPM, 0, data, 0, 4, 32, bytes12(uint96(uint160(POOL_500))));
        uint256 checkGas = g0 - gasleft();
        assertTrue(ok);
        console2.log("uni Custom check() direct gas (approx, incl. external call overhead)", checkGas);
    }

    /// @notice An NFT the Safe does not own cannot be increased, even on a declared pool.
    function test_UNI_otherOwnerTokenIdReverts() public {
        (, FundConfig fc, IRolesV2 roles) = _newFund(11);
        _addPosition(fc, uniModule, _addr(POOL_500));
        _manager(fc);
        _approve(roles, USDC, NPM, type(uint256).max);
        _approve(roles, WETH, NPM, type(uint256).max);

        uint256 otherId = _eoaMint(500, other);
        IncreaseParams memory ip = IncreaseParams({
            tokenId: otherId,
            amount0Desired: 1e6,
            amount1Desired: 1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        vm.expectRevert();
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.increaseLiquidity, (ip)), CALL);
    }

    /// @notice Safe-owned NFT from an undeclared pool (same tokens, different fee) is not actionable: the pool
    ///         binding in the Custom checker rejects it even though ownership passes.
    function test_UNI_safeOwnedUndeclaredPoolReverts() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(12);
        _addPosition(fc, uniModule, _addr(POOL_500));
        _manager(fc);
        _approve(roles, USDC, NPM, type(uint256).max);
        _approve(roles, WETH, NPM, type(uint256).max);

        uint256 tokenId = _eoaMint(3000, safe);
        assertEq(INonfungiblePositionManagerFork(NPM).ownerOf(tokenId), safe);

        IncreaseParams memory ip = IncreaseParams({
            tokenId: tokenId,
            amount0Desired: 1e6,
            amount1Desired: 1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        vm.expectRevert();
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.increaseLiquidity, (ip)), CALL);
    }

    /// @notice Minting into an undeclared pool (fee tier 0.3% vs declared 0.05%) reverts on the EqualTo fee/pool match.
    function test_UNI_mintOtherPoolReverts() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(13);
        deal(USDC, safe, 2_000e6);
        deal(WETH, safe, 2 ether);
        _addPosition(fc, uniModule, _addr(POOL_500));
        _manager(fc);
        _approve(roles, USDC, NPM, type(uint256).max);
        _approve(roles, WETH, NPM, type(uint256).max);

        MintParams memory mp = _mintParams(POOL_500, 3000, safe);
        vm.expectRevert();
        _exec(roles, NPM, abi.encodeCall(INonfungiblePositionManagerFork.mint, (mp)), CALL);
    }

    // ---------------------------------------------------------------- Curve pool + gauge

    /// @notice enter (add_liquidity -> LP -> gauge deposit) and exit (withdraw -> remove_liquidity) through Roles;
    ///         NAV counts both legs (stays within 1% of the pre-entry value while the LP is staked).
    function test_CRV_enterExitBothLegsCounted() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(14);
        deal(USDC, safe, 1_000e6);
        _addPosition(fc, curvePoolModule, _addr(THREE_POOL));
        _addPosition(fc, curveGaugeModule, _addr(GAUGE));
        _manager(fc);

        (int256 navBefore, bool staleBefore) = fc.fundNav(USDC);
        assertFalse(staleBefore);

        _approve(roles, USDC, THREE_POOL, 1_000e6);
        uint256[3] memory amounts;
        amounts[1] = 1_000e6;
        _exec(roles, THREE_POOL, abi.encodeWithSelector(ADD3, amounts, uint256(0)), CALL);
        console2.log("curve add_liquidity via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);

        uint256 lp = IERC20(THREE_CRV).balanceOf(safe);
        assertGt(lp, 0);

        _approve(roles, THREE_CRV, GAUGE, lp);
        _exec(roles, GAUGE, abi.encodeWithSelector(GAUGE_DEPOSIT, lp), CALL);
        console2.log("curve gauge deposit via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);
        assertEq(IERC20(THREE_CRV).balanceOf(safe), 0);
        assertEq(ICurveGaugeFork(GAUGE).balanceOf(safe), lp);

        (int256 navStaked, bool staleStaked) = fc.fundNav(USDC);
        assertFalse(staleStaked);
        assertApproxEqRel(uint256(navStaked), uint256(navBefore), 1e16);

        _exec(roles, GAUGE, abi.encodeWithSelector(GAUGE_WITHDRAW, lp), CALL);
        console2.log("curve gauge withdraw via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);
        assertEq(ICurveGaugeFork(GAUGE).balanceOf(safe), 0);
        assertEq(IERC20(THREE_CRV).balanceOf(safe), lp);

        uint256[3] memory minAmounts;
        _exec(roles, THREE_POOL, abi.encodeWithSelector(REMOVE3, lp, minAmounts), CALL);
        console2.log("curve remove_liquidity via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);
        assertEq(IERC20(THREE_CRV).balanceOf(safe), 0);
        assertGt(IERC20(DAI).balanceOf(safe), 0);
        assertGt(IERC20(USDC).balanceOf(safe), 0);
        assertGt(IERC20(USDT).balanceOf(safe), 0);

        (int256 navAfter, bool staleAfter) = fc.fundNav(USDC);
        assertFalse(staleAfter);
        assertApproxEqRel(uint256(navAfter), uint256(navBefore), 1e16);
    }

    /// @notice CRV claim through Roles: the gauge accrues CRV while staked; `Minter.mint(gauge)` pays it to the Safe.
    ///         NAV is not asserted here: `fundNav` values the claimed CRV stale at this block (see the doc), so this test
    ///         checks only the permission and the transfer.
    function test_CRV_claimViaMinter() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(16);
        deal(USDC, safe, 1_000e6);
        _addPosition(fc, curvePoolModule, _addr(THREE_POOL));
        _addPosition(fc, curveGaugeModule, _addr(GAUGE));
        _manager(fc);

        _approve(roles, USDC, THREE_POOL, 1_000e6);
        uint256[3] memory amounts;
        amounts[1] = 1_000e6;
        _exec(roles, THREE_POOL, abi.encodeWithSelector(ADD3, amounts, uint256(0)), CALL);

        uint256 lp = IERC20(THREE_CRV).balanceOf(safe);
        _approve(roles, THREE_CRV, GAUGE, lp);
        _exec(roles, GAUGE, abi.encodeWithSelector(GAUGE_DEPOSIT, lp), CALL);
        console2.log("curve gauge deposit via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);

        vm.warp(block.timestamp + 1 days);
        _exec(roles, CRV_MINTER, abi.encodeWithSelector(MINT_CRV, GAUGE), CALL);
        console2.log("curve gauge mint(gauge) via execTransactionWithRole gasTotalUsed", vm.lastCallGas().gasTotalUsed);
        assertGt(IERC20(CRV_TOKEN).balanceOf(safe), 0);
    }

    /// @notice Per-leg removal guard. The gauge leg is blocked while staked. The 3pool wallet leg is NOT guarded: the
    ///         upstream CurvePoolsMeta cannot decompose classic 3pool LP (CurvePoolLib.getLpToken falls through), so the
    ///         pool position is removable while LP is held. This test characterizes that gap.
    function test_CRV_removalGuard() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _newFund(15);
        deal(USDC, safe, 1_000e6);
        _addPosition(fc, curvePoolModule, _addr(THREE_POOL));
        _addPosition(fc, curveGaugeModule, _addr(GAUGE));
        _manager(fc);

        _approve(roles, USDC, THREE_POOL, 1_000e6);
        uint256[3] memory amounts;
        amounts[1] = 1_000e6;
        _exec(roles, THREE_POOL, abi.encodeWithSelector(ADD3, amounts, uint256(0)), CALL);
        uint256 lp = IERC20(THREE_CRV).balanceOf(safe);

        bytes32 poolModuleId = curvePoolModule.moduleId();
        bytes32 gaugeModuleId = curveGaugeModule.moduleId();

        // Wallet LP held, but the upstream adapter reports no pool-leg balance for classic 3pool (known gap): not blocked.
        assertGt(IERC20(THREE_CRV).balanceOf(safe), 0);
        vm.prank(curator);
        fc.removePosition(poolModuleId, _addr(THREE_POOL));

        _approve(roles, THREE_CRV, GAUGE, lp);
        _exec(roles, GAUGE, abi.encodeWithSelector(GAUGE_DEPOSIT, lp), CALL);

        // Staked leg holds value: gauge position cannot be removed.
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(FundConfig.PositionNotEmpty.selector, gaugeModuleId, _addr(GAUGE)));
        fc.removePosition(gaugeModuleId, _addr(GAUGE));
    }
}
