// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC4626WrapBalanceAdapter} from "src/balances/protocols/ERC4626WrapBalanceAdapter.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal ERC-4626 wrapper mock for unit tests
contract MockERC4626Wrapper {
    address private immutable _asset;
    uint256 private _convertRatioBps; // 10_000 = 1:1
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = asset_;
        _convertRatioBps = 10_000;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _convertRatioBps) / 10_000;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setConvertRatioBps(uint256 bps) external {
        _convertRatioBps = bps;
    }
}

contract MockToken {
    string public symbol = "GHO";
    uint8 public decimals = 18;
}

/// @title ERC4626WrapBalanceAdapter unit tests (no fork)
contract ERC4626WrapBalanceAdapterTest is Test {
    MockBalances mockBalances;
    MockERC4626Wrapper wrapper;
    MockToken underlying;
    ERC4626WrapBalanceAdapter adapter;

    address alice = makeAddr("alice");

    string constant PROTOCOL = "Aave V3";
    string constant POSITION_DETAIL_BASE =
        "{\"protocol\":\"Aave V3\",\"product\":\"Lending\",\"name\":\"Prime Instance (LidoGHO stata wrap)\"";
    string constant POSITION_ID = "0x0000000000000000000000000000000000000001";

    function setUp() public {
        mockBalances = new MockBalances();
        underlying = new MockToken();
        wrapper = new MockERC4626Wrapper(address(underlying));
        // Stub `isAssetRegistered(underlying) -> true` so the constructor check passes.
        _stubAssetRegistered();
        adapter = new ERC4626WrapBalanceAdapter(address(wrapper), address(mockBalances));
    }

    /// @dev Stubs both:
    ///  - `NAVCalculator.isAssetRegistered(underlying) -> true` for the construction-time gate, and
    ///  - `NAVCalculator.getRegisteredAssets() -> [underlying]` for the runtime intersection check.
    function _stubAssetRegistered() internal {
        vm.mockCall(
            address(mockBalances),
            abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, address(underlying)),
            abi.encode(true)
        );
        INAVCalculator.Asset[] memory reg = new INAVCalculator.Asset[](1);
        reg[0] = INAVCalculator.Asset({asset: address(underlying), symbol: "GHO", decimals: 18});
        vm.mockCall(
            address(mockBalances), abi.encodeWithSelector(INAVCalculator.getRegisteredAssets.selector), abi.encode(reg)
        );
    }

    function test_constructor_invalidArgs_zeroWrapper() public {
        vm.expectRevert(InvalidArguments.selector);
        new ERC4626WrapBalanceAdapter(address(0), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractWrapper() public {
        vm.expectRevert("Wrapper must be a contract");
        new ERC4626WrapBalanceAdapter(address(0xdead), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new ERC4626WrapBalanceAdapter(address(wrapper), address(0xdead));
    }

    function test_constructor_reverts_whenUnderlyingNotRegistered() public {
        MockToken otherUnderlying = new MockToken();
        MockERC4626Wrapper otherWrapper = new MockERC4626Wrapper(address(otherUnderlying));
        // `mockBalances.isAssetRegistered(otherUnderlying)` falls back to default `false`.
        vm.expectRevert("Wrapper underlying must be a NAV-registered asset");
        new ERC4626WrapBalanceAdapter(address(otherWrapper), address(mockBalances));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(adapter.WRAPPER()), address(wrapper));
        assertEq(adapter.ASSET(), address(underlying));
        assertEq(address(adapter.NAV_CALCULATOR()), address(mockBalances));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0x12345678));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(underlying));
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), address(underlying));
        assertEq(amount, 0);
        assertEq(isDebt, false);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0xbeef));
        assertEq(amount, 0);
        assertEq(isDebt, false);
    }

    function test_getAdapterBalanceForAsset_zeroBalance() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(underlying));
        assertEq(amount, 0);
        assertEq(isDebt, false);
    }

    function test_getAdapterBalanceForAsset_1to1() public {
        wrapper.setBalance(alice, 100e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(underlying));
        assertEq(amount, 100e18);
        assertEq(isDebt, false);
    }

    function test_getAdapterBalanceForAsset_appliesConvertRatio() public {
        // 1 share = 1.0361 underlying (simulating stata-token accrual)
        wrapper.setBalance(alice, 100e18);
        wrapper.setConvertRatioBps(10_361);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(underlying));
        assertEq(amount, 103_61e16); // 103.61 * 1e18
    }

    function test_getAdapterBalances_empty_whenZero() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterBalances_one_entry() public {
        wrapper.setBalance(alice, 50e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(underlying));
        assertEq(amounts[0], 50e18);
        assertEq(isDebt[0], false);
    }

    function test_getAdapterPositions_dropped_whenAssetUnregisteredAfterDeploy() public {
        // Simulate the underlying being unregistered post-deploy (e.g. via nav.unregisterAsset).
        // Restore default empty `getRegisteredAssets()` from MockBalances; constructor mock for
        // `isAssetRegistered` already happened, so this only affects the runtime intersection.
        vm.clearMockedCalls();
        wrapper.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "should drop when underlying not currently registered");
    }

    function test_getAdapterPositions_emitted_whenRegistered() public {
        _stubAssetRegistered();
        wrapper.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(underlying));
        assertEq(positions[0].amount, 100e18);
        assertEq(positions[0].isDebt, false);
        assertEq(positions[0].positionId, abi.encode(address(wrapper)));
        assertEq(positions[0].balanceAdapter, address(adapter));
    }

    function test_getAdapterPositions_assetFilter_match() public {
        _stubAssetRegistered();
        wrapper.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(underlying));
        assertEq(positions.length, 1);
    }

    function test_getAdapterPositions_assetFilter_nonmatch() public {
        _stubAssetRegistered();
        wrapper.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0xbeef));
        assertEq(positions.length, 0);
    }
}
