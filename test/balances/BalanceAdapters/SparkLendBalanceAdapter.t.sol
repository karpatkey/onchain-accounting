// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Mock_ERC20} from "test/mocks/tokens.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {SparkLendBalanceAdapter} from "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

contract MockAavePoolAddressesProvider {
    address public pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function getLendingPool() external view returns (address) {
        return pool;
    }
}

contract MockAddressesProviderSource {
    MockAavePoolAddressesProvider public ap;

    constructor(address pool_) {
        ap = new MockAavePoolAddressesProvider(pool_);
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(ap);
    }

    /// @dev Repoint at a pool WITH code, so the adapter's bitmap branch is reachable.
    function setPool(address pool_) external {
        ap = new MockAavePoolAddressesProvider(pool_);
    }
}

contract MockAaveProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    struct UserReserve {
        uint256 aToken;
        uint256 stableDebt;
        uint256 variableDebt;
        bool asCollateral;
    }

    MockAddressesProviderSource public _src;
    TokenData[] public reserves;
    mapping(address => mapping(address => UserReserve)) public userReserves;

    constructor() {
        _src = new MockAddressesProviderSource(address(0x1234));
    }

    /// @dev Repoint the provider at a pool WITH code (see `MockSparkPool`); must be called BEFORE the adapter
    ///      is constructed, since SparkLendBalanceAdapter pins POOL in its constructor.
    function setAddressesProviderPool(address pool_) external {
        _src.setPool(pool_);
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(_src.ADDRESSES_PROVIDER());
    }

    function getAllReservesTokens() external view returns (TokenData[] memory) {
        return reserves;
    }

    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        )
    {
        UserReserve memory u = userReserves[asset][user];
        return (u.aToken, u.stableDebt, u.variableDebt, 0, 0, 0, 0, 0, u.asCollateral);
    }

    function addReserve(string memory symbol, address tokenAddress) external {
        reserves.push(TokenData({symbol: symbol, tokenAddress: tokenAddress}));
    }

    /// @notice Set a user's per-reserve balances (aToken supply, stable debt, variable debt, collateral flag).
    function setUserReserve(
        address asset,
        address user,
        uint256 aToken,
        uint256 stableDebt,
        uint256 variableDebt,
        bool asCollateral
    ) external {
        userReserves[asset][user] = UserReserve(aToken, stableDebt, variableDebt, asCollateral);
    }
}

/// @title SparkLendBalanceAdapterTest
/// @notice Unit and implementation tests for SparkLendBalanceAdapter
/// @dev Tests adapter logic and error handling without requiring fork
/// @dev SparkLendBalanceAdapter extends BalanceAdapterBase; its variable+stable debt-summing logic mirrors AaveV3InstancesMetaBalanceAdapter
/// @notice Minimal Spark/Aave Pool mock exposing the user-configuration bitmap the debt pre-pass uses, so the
///         bitmap branch is exercised rather than always falling through to the scan (a code-less pool address
///         sends every read down the fallback).
contract MockSparkPool {
    uint256 public cfgData;
    mapping(uint16 => address) private _byId;

    function setBorrowing(uint256 reserveIndex) external {
        cfgData |= (1 << (reserveIndex * 2));
    }

    function setReserveById(uint16 id, address asset) external {
        _byId[id] = asset;
    }

    function getUserConfiguration(address) external view returns (MockSparkUserConfig memory) {
        return MockSparkUserConfig({data: cfgData});
    }

    function getReserveAddressById(uint16 id) external view returns (address) {
        return _byId[id];
    }
}

struct MockSparkUserConfig {
    uint256 data;
}

contract SparkLendBalanceAdapterTest is BalanceAdapterTestBase {
    SparkLendBalanceAdapter public adapter;
    MockAaveProtocolDataProvider public mockDataProvider;

    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        adapter = new SparkLendBalanceAdapter(address(mockDataProvider), address(balances));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getAdapterBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getAdapterBalanceForAsset should return 0 for unsupported tokens
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
    }

    // ============================================
    // Legacy stable debt (regression: must not be dropped → would over-report NAV)
    // ============================================

    /// @notice The Borrow leg must include legacy stable debt (SparkLend is an Aave V3 fork; `getUserReserveData`'s
    ///         2nd return `currentStableDebt` was previously discarded, understating debt and overstating NAV).
    function test_borrow_includesLegacyStableDebt() public {
        address dai = makeAddr("dai");
        mockDataProvider.addReserve("DAI", dai);

        // Legacy stable debt only (no variable debt). Pre-fix this returned 0; it must now report the stable debt.
        mockDataProvider.setUserReserve(dai, alice, 0, 3 ether, 0, false);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, dai);
        assertEq(amount, 3 ether, "legacy stable debt must be counted in the borrow leg");
        assertTrue(isDebt, "stable-debt-only position is net debt");

        // Both stable + variable debt → the borrow leg is their sum.
        mockDataProvider.setUserReserve(dai, alice, 0, 3 ether, 2 ether, false);
        (amount, isDebt) = adapter.getAdapterBalanceForAsset(alice, dai);
        assertEq(amount, 5 ether, "borrow leg = variableDebt + stableDebt");
        assertTrue(isDebt);

        // Supply net of (stable + variable) debt.
        mockDataProvider.setUserReserve(dai, alice, 10 ether, 3 ether, 2 ether, false);
        (amount, isDebt) = adapter.getAdapterBalanceForAsset(alice, dai);
        assertEq(amount, 5 ether, "net = supply 10 - (3 stable + 2 variable)");
        assertFalse(isDebt);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_getAdapterBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(address(0));

        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(address(0), address(0));

        assertEq(positions.length, 0);
    }

    /// @dev SparkLend drops unregistered reserves from `active`, so a borrow on one would simply vanish while
    ///      the registered supplies were still reported — counting the position as pure credit and
    ///      over-reporting NAV by the whole borrow. The whole instance must report nothing instead.
    ///      Exercises the scan fallback: the mock's pool address has no code, so the configuration bitmap is
    ///      unavailable (and must not revert the read).
    function test_unreportableDebt_suppressesWholeInstance() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18); // deliberately NOT registered
        mockDataProvider.addReserve("WETH", address(weth));
        mockDataProvider.addReserve("XYZ", address(unregistered));

        mockDataProvider.setUserReserve(address(weth), alice, 5e18, 0, 0, true); // registered supply
        mockDataProvider.setUserReserve(address(unregistered), alice, 0, 0, 100e18, false); // unreportable debt

        assertEq(
            adapter.getAdapterPositions(alice, address(0)).length,
            0,
            "supplies must not be reported without the unreportable debt"
        );
        assertEq(
            adapter.getAdapterPositions(alice, address(weth)).length,
            0,
            "assetFilter must not resurrect the unoffset supply leg"
        );
    }

    /// @dev The mirror case: with every borrowed reserve registered, the position reports normally.
    function test_reportableDebt_stillReports() public {
        mockDataProvider.addReserve("WETH", address(weth));
        mockDataProvider.addReserve("USDC", address(usdc));
        mockDataProvider.setUserReserve(address(weth), alice, 5e18, 0, 0, true);
        mockDataProvider.setUserReserve(address(usdc), alice, 0, 0, 400e6, false);

        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 2, "supply + borrow both reported");
    }

    /// @dev The bitmap branch, which the other Spark tests never reach because the default mock pool address is
    ///      code-less and sends every read to the scan fallback. Builds an adapter whose POOL has code.
    function test_unreportableDebt_viaBitmap_suppressesInstance() public {
        MockSparkPool p = new MockSparkPool();
        MockAaveProtocolDataProvider dp2 = new MockAaveProtocolDataProvider();
        dp2.setAddressesProviderPool(address(p));

        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18);
        dp2.addReserve("WETH", address(weth));
        dp2.addReserve("XYZ", address(unregistered));
        dp2.setUserReserve(address(weth), alice, 5e18, 0, 0, true);
        dp2.setUserReserve(address(unregistered), alice, 0, 0, 100e18, false);
        p.setReserveById(1, address(unregistered));
        p.setBorrowing(1);

        SparkLendBalanceAdapter a2 = new SparkLendBalanceAdapter(address(dp2), address(balances));
        assertEq(a2.getAdapterPositions(alice, address(0)).length, 0, "bitmap path must suppress");

        // And a stale bit with no debt must NOT suppress — the bit can outlive the debt.
        dp2.setUserReserve(address(unregistered), alice, 0, 0, 0, false);
        assertEq(a2.getAdapterPositions(alice, address(0)).length, 1, "stale bit with zero debt must not suppress");
    }

    // ============================================
    // IPositionDescribable
    // ============================================

    /// @dev Configuration-view probe: a consumer describing configuration has no positionId, so it can only call
    ///      `positionLabels("")`. This adapter's breadcrumb is positionId-independent and it emits a single
    ///      positionId (`abi.encode(POOL)`; reserves are told apart by balanceAsset + positionKind), so the probe
    ///      answers with the full constant breadcrumb. What this pins is that the probe never silently collapses
    ///      to `[]` — a positionId-derived leaf added later must still return at least the `"Market"` category
    ///      per the `_labels` empty-leaf convention, and this assertion should then be relaxed, not deleted.
    function test_positionLabels_emptyProbe_returnsTheConstantShape() public view {
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 2);
        assertEq(labels[0], "Market");
        assertEq(labels[1], "SparkLend");
    }
}
