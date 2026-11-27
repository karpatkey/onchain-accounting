// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {AaveV3Module} from "poc/fundconfig/modules/AaveV3Module.sol";
import {AaveV3BorrowModule} from "poc/fundconfig/modules/AaveV3BorrowModule.sol";
import {SwapModule} from "poc/fundconfig/modules/SwapModule.sol";
import {NoPositionAdapter} from "poc/fundconfig/modules/swap/NoPositionAdapter.sol";
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
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface IAaveDataProviderFork {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProviderFork {
    function getPool() external view returns (address);
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

/// @notice Aave V3 borrow (debt leg) and Uniswap V3 single-hop swap positions, on a mainnet fork at a pinned block.
/// @dev Every test deploys a fresh Safe and FundConfig, so no state leaks across tests. Gas lines are emitted as
///      `GASPROF <key> <gas>` for `docs/research/fund-infra/gas-complex-debt-swap.json`.
contract FundConfigDebtSwapForkTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_500_000;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant AAVE_ADAPTER = 0xa1b3c695A768A6Ce571fF699F463224CB32260C1; // AaveV3InstancesMeta
    address internal constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address internal constant ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bytes32 internal constant ROLE_KEY = keccak256("manager");
    uint8 internal constant CALL = 0;

    address internal safeOwner;
    address internal curator;
    address internal manager;
    ModuleRegistry internal registry;
    AaveV3Module internal aaveWeth;
    AaveV3BorrowModule internal borrowUsdc;
    SwapModule internal swap;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        safeOwner = makeAddr("safeOwner");
        curator = makeAddr("curator");
        manager = makeAddr("manager");

        registry = new ModuleRegistry(address(this));
        aaveWeth = new AaveV3Module(keccak256("aave-v3-weth"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        borrowUsdc = new AaveV3BorrowModule(keccak256("aave-v3-borrow-usdc"), AAVE_DATA_PROVIDER, AAVE_ADAPTER);
        swap = new SwapModule(
            keccak256("uniswap-v3-swap"), SWAP_ROUTER02, UNIV3_FACTORY, address(new NoPositionAdapter())
        );
        registry.register(aaveWeth);
        registry.register(borrowUsdc);
        registry.register(swap);
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

    /// @dev Declares a position as the curator and returns the gas of `addPosition`.
    function _addPos(FundConfig fc, bytes32 moduleId, bytes32 instance) internal returns (uint256 gas) {
        vm.prank(curator);
        fc.addPosition(moduleId, instance);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _manager(FundConfig fc) internal {
        vm.prank(curator);
        fc.assignManager(manager, true);
    }

    /// @dev Executes through Roles as the manager and returns the gas of the Roles call.
    function _exec(IRolesV2 roles, address to, bytes memory data) internal returns (uint256 gas) {
        vm.prank(manager);
        roles.execTransactionWithRole(to, 0, data, CALL, ROLE_KEY, true);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _aavePool() internal view returns (address) {
        return IAavePoolAddressesProviderFork(IAaveDataProviderFork(AAVE_DATA_PROVIDER).ADDRESSES_PROVIDER()).getPool();
    }

    function _nav(FundConfig fc) internal view returns (int256 value) {
        bool stale;
        (value, stale) = fc.fundNav(USDC);
        assertFalse(stale);
    }

    /// @dev Fund holding 5 WETH supplied to Aave as collateral, with the WETH position declared and a manager set.
    function _fundWithCollateral(uint256 saltNonce) internal returns (address safe, FundConfig fc, IRolesV2 roles) {
        (safe, fc, roles) = _newFund(saltNonce);
        deal(WETH, safe, 5e18);
        _addPos(fc, aaveWeth.moduleId(), _addr(WETH));
        _manager(fc);
        _exec(roles, WETH, abi.encodeCall(IERC20.approve, (_aavePool(), 5e18)));
        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.supply, (WETH, 5e18, safe, 0)));
    }

    function _swapParams(address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn)
        internal
        pure
        returns (ISwapRouter02Fork.ExactInputSingleParams memory p)
    {
        p = ISwapRouter02Fork.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
    }

    /// @dev Fund with 10,000 USDC, the USDC/WETH 0.05% pool declared, and the manager set.
    function _swapFund(uint256 saltNonce) internal returns (address safe, FundConfig fc, IRolesV2 roles) {
        (safe, fc, roles) = _newFund(saltNonce);
        deal(USDC, safe, 10_000e6);
        console2.log("GASPROF swap.addPosition", _addPos(fc, swap.moduleId(), _addr(USDC_WETH_500)));
        _manager(fc);
    }

    // ---------------------------------------------------------------- borrow

    /// @notice Collateral 5 WETH, borrow 2,000 USDC. With the borrowed cash held, NAV is unchanged (debt offset by cash).
    ///         With the cash removed from the fund, NAV falls by the borrowed value.
    function test_borrow_navCountsDebtAgainstCollateral() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _fundWithCollateral(1);
        int256 navBefore = _nav(fc);

        uint256 gasAdd = _addPos(fc, borrowUsdc.moduleId(), _addr(USDC));
        console2.log("GASPROF borrow.addPosition", gasAdd);

        uint256 gasBorrow =
            _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.borrow, (USDC, 2000e6, 2, 0, safe)));
        console2.log("GASPROF borrow.borrow", gasBorrow);
        assertEq(IERC20(USDC).balanceOf(safe), 2000e6);

        int256 navWithCash = _nav(fc);
        assertApproxEqRel(uint256(navWithCash), uint256(navBefore), 1e15);

        address sink = makeAddr("sink");
        vm.prank(safe);
        IERC20(USDC).transfer(sink, 2000e6);

        int256 navSwept = _nav(fc);
        assertApproxEqRel(uint256(navWithCash - navSwept), 2000e6, 1e16);
    }

    /// @notice Removal is blocked while the reserve has debt, and allowed once the debt is repaid.
    function test_borrow_removalBlockedWhileDebt_allowedAfterRepay() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _fundWithCollateral(2);

        bytes32 borrowId = borrowUsdc.moduleId();
        _addPos(fc, borrowId, _addr(USDC));
        _exec(roles, _aavePool(), abi.encodeCall(IAavePoolFork.borrow, (USDC, 2000e6, 2, 0, safe)));

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(FundConfig.PositionNotEmpty.selector, borrowId, _addr(USDC)));
        fc.removePosition(borrowId, _addr(USDC));

        // Aave's max-repay debt rounds up by a unit; top the Safe up so repay-all can settle.
        deal(USDC, safe, IERC20(USDC).balanceOf(safe) + 1e6);
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (_aavePool(), type(uint256).max)));
        uint256 gasRepay = _exec(
            roles, _aavePool(), abi.encodeCall(IAavePoolFork.repay, (USDC, type(uint256).max, 2, safe))
        );
        console2.log("GASPROF borrow.repay", gasRepay);

        vm.prank(curator);
        fc.removePosition(borrowId, _addr(USDC));
        console2.log("GASPROF borrow.removePosition", vm.lastCallGas().gasTotalUsed);
        assertEq(fc.positions().length, 1);
    }

    /// @notice Borrowing on behalf of a third party reverts: `onBehalfOf` must be the Safe.
    function test_borrow_onBehalfOfThirdParty_reverts() public {
        (, FundConfig fc, IRolesV2 roles) = _fundWithCollateral(3);
        _addPos(fc, borrowUsdc.moduleId(), _addr(USDC));

        address thirdParty = makeAddr("thirdParty");
        address pool = _aavePool();
        vm.expectRevert();
        _exec(roles, pool, abi.encodeCall(IAavePoolFork.borrow, (USDC, 1000e6, 2, 0, thirdParty)));
    }

    /// @notice Borrowing an asset that no declared borrow position names reverts.
    function test_borrow_undeclaredAsset_reverts() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _fundWithCollateral(4);
        _addPos(fc, borrowUsdc.moduleId(), _addr(USDC));

        address pool = _aavePool();
        vm.expectRevert();
        _exec(roles, pool, abi.encodeCall(IAavePoolFork.borrow, (DAI, 1000e18, 2, 0, safe)));
    }

    // ---------------------------------------------------------------- swap

    /// @notice Swap 1,000 USDC for WETH through the declared pool. NAV counts the output token and stays flat (up to fee).
    function test_swap_allowedPath_navCountsOutputToken() public {
        (address safe, FundConfig fc, IRolesV2 roles) = _swapFund(5);
        int256 navBefore = _nav(fc);

        uint256 gasApprove = _exec(roles, USDC, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 1000e6)));
        console2.log("GASPROF swap.approve", gasApprove);

        uint256 gasSwap = _exec(
            roles,
            SWAP_ROUTER02,
            abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (_swapParams(USDC, WETH, 500, safe, 1000e6)))
        );
        console2.log("GASPROF swap.exactInputSingle", gasSwap);

        assertEq(IERC20(USDC).balanceOf(safe), 9000e6);
        assertGt(IERC20(WETH).balanceOf(safe), 0);

        int256 navAfter = _nav(fc);
        assertApproxEqRel(uint256(navAfter), uint256(navBefore), 1e15);
    }

    /// @notice The reverse direction (WETH -> USDC) is also declared for the pool.
    function test_swap_reverseDirectionAllowed() public {
        (address safe, , IRolesV2 roles) = _swapFund(6);
        deal(WETH, safe, 1e18);

        _exec(roles, WETH, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 1e18)));
        _exec(
            roles,
            SWAP_ROUTER02,
            abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (_swapParams(WETH, USDC, 500, safe, 1e18)))
        );

        assertEq(IERC20(WETH).balanceOf(safe), 0);
        assertGt(IERC20(USDC).balanceOf(safe), 10_000e6);
    }

    /// @notice Output token not declared by the pool reverts.
    function test_swap_undeclaredOutputToken_reverts() public {
        (address safe, , IRolesV2 roles) = _swapFund(7);
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 1000e6)));

        vm.expectRevert();
        _exec(
            roles,
            SWAP_ROUTER02,
            abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (_swapParams(USDC, DAI, 500, safe, 1000e6)))
        );
    }

    /// @notice A fee tier other than the pool's reverts.
    function test_swap_wrongFee_reverts() public {
        (address safe, , IRolesV2 roles) = _swapFund(8);
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 1000e6)));

        vm.expectRevert();
        _exec(
            roles,
            SWAP_ROUTER02,
            abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (_swapParams(USDC, WETH, 3000, safe, 1000e6)))
        );
    }

    /// @notice A recipient other than the Safe reverts.
    function test_swap_recipientNotSafe_reverts() public {
        (, , IRolesV2 roles) = _swapFund(9);
        _exec(roles, USDC, abi.encodeCall(IERC20.approve, (SWAP_ROUTER02, 1000e6)));

        address thirdParty = makeAddr("thirdParty");
        bytes memory data =
            abi.encodeCall(ISwapRouter02Fork.exactInputSingle, (_swapParams(USDC, WETH, 500, thirdParty, 1000e6)));
        vm.expectRevert();
        _exec(roles, SWAP_ROUTER02, data);
    }

    /// @notice A pool address that the factory does not register for its pair and fee is rejected at declaration.
    function test_addPosition_nonCanonicalPool_reverts() public {
        (, FundConfig fc,) = _newFund(10);
        bytes32 moduleId = swap.moduleId();
        address notPool = makeAddr("notAPool");
        vm.prank(curator);
        vm.expectRevert();
        fc.addPosition(moduleId, _addr(notPool));
    }
}
