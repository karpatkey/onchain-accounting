// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {IProtocolDataProvider} from "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Minimal PoolAddressesProvider mock: getPool() + getMarketId().
contract MockAaveAddressesProvider {
    address public pool;
    string private _marketId;

    constructor(address pool_, string memory marketId_) {
        pool = pool_;
        _marketId = marketId_;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function getMarketId() external view returns (string memory) {
        return _marketId;
    }
}

/// @notice Minimal Aave Pool mock exposing the user-configuration bitmap the debt pre-pass uses.
contract MockAavePool {
    uint256 public cfgData;
    address[] private _list;
    mapping(uint16 => address) private _byId;
    bool private _configReturnsShort;

    function setUserConfig(uint256 data) external {
        cfgData = data;
    }

    function setReservesList(address[] memory list) external {
        _list = list;
    }

    /// @dev Bit 2*i marks "borrowing reserve i"; helper to set it for a reserve index.
    function setBorrowing(uint256 reserveIndex) external {
        cfgData |= (1 << (reserveIndex * 2));
    }

    function getUserConfiguration(address) external view returns (MockUserConfigurationMap memory) {
        if (_configReturnsShort) {
            assembly {
                return(0, 8) // <32 bytes: a `try` would NOT catch the decode failure, so the caller must
            }
        }
        return MockUserConfigurationMap({data: cfgData});
    }

    /// @dev Stage a pool that answers the selector successfully but with unusable data.
    function setConfigReturnsShort(bool v) external {
        _configReturnsShort = v;
    }

    function getReservesList() external view returns (address[] memory) {
        return _list;
    }

    /// @dev Id-keyed accessor, mirroring the real pool. `_list` here is index==id; the dropped-reserve case
    ///     (where the two diverge) is staged with `setReserveById`.
    function getReserveAddressById(uint16 id) external view returns (address) {
        if (_byId[id] != address(0)) return _byId[id];
        return id < _list.length ? _list[id] : address(0);
    }

    /// @dev Stage an id->asset mapping that does NOT match `_list` order, reproducing a post-`dropReserve` pool.
    function setReserveById(uint16 id, address asset) external {
        _byId[id] = asset;
    }
}

struct MockUserConfigurationMap {
    uint256 data;
}

/// @notice Minimal Aave ProtocolDataProvider mock: reserves list, per-user reserve data, ADDRESSES_PROVIDER.
contract MockAaveDataProvider {
    address public ADDRESSES_PROVIDER;
    IProtocolDataProvider.TokenData[] private _reserves;

    struct UserData {
        uint256 aToken;
        uint256 variableDebt;
        uint256 stableDebt;
        bool usageAsCollateral;
    }

    mapping(address => mapping(address => UserData)) private _userData;

    constructor(address addressesProvider) {
        ADDRESSES_PROVIDER = addressesProvider;
    }

    function addReserve(string memory symbol, address token) external {
        _reserves.push(IProtocolDataProvider.TokenData({symbol: symbol, tokenAddress: token}));
    }

    function setUserData(address user, address asset, uint256 aToken, uint256 variableDebt, bool usageAsCollateral)
        external
    {
        _userData[user][asset] = UserData(aToken, variableDebt, 0, usageAsCollateral);
    }

    /// @notice Set a legacy stable-debt amount for a (user, asset). Leaves the other fields untouched.
    function setStableDebt(address user, address asset, uint256 stableDebt) external {
        _userData[user][asset].stableDebt = stableDebt;
    }

    function getAllReservesTokens() external view returns (IProtocolDataProvider.TokenData[] memory) {
        return _reserves;
    }

    function getUserReserveData(address asset, address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint40, bool)
    {
        UserData memory d = _userData[user][asset];
        return (d.aToken, d.stableDebt, d.variableDebt, 0, 0, 0, 0, 0, d.usageAsCollateral);
    }
}

/// @title AaveV3InstancesMetaBalanceAdapter unit tests (mocks, no fork)
contract AaveV3InstancesMetaUnitTest is BalanceAdapterTestBase {
    using Strings for address;

    AaveV3InstancesMetaBalanceAdapter public adapter;
    MockAaveDataProvider public dp;
    MockAaveAddressesProvider public addrProvider;
    address public constant codelessPool = 0x1111111111111111111111111111111111111111;
    MockAavePool public pool;

    function setUp() public override {
        super.setUp(); // registers usdc, dai, weth on `balances`
        pool = new MockAavePool();
        addrProvider = new MockAaveAddressesProvider(address(pool), "Aave V3 Test Instance");
        dp = new MockAaveDataProvider(address(addrProvider));
        dp.addReserve("USDC", address(usdc));
        dp.addReserve("WETH", address(weth));
        address[] memory list = new address[](2);
        list[0] = address(usdc);
        list[1] = address(weth);
        pool.setReservesList(list);
        adapter = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(balances));
    }

    function _ids() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(address(dp))));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_empty() public {
        dp.setUserData(alice, address(usdc), 100e6, 0, true);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
    }

    function test_collateralSupplyBorrow_legs() public {
        // WETH used as collateral, USDC supplied (not collateral) + USDC borrowed.
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        dp.setUserData(alice, address(usdc), 1000e6, 400e6, false);

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 3, "collateral(WETH) + supply(USDC) + borrow(USDC)");

        // Reserve order: USDC first, WETH second.
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1000e6);
        assertFalse(pos[0].isDebt);
        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertEq(pos[1].amount, 400e6);
        assertTrue(pos[1].isDebt);
        assertEq(pos[2].balanceAsset.asset, address(weth));
        assertEq(pos[2].amount, 5e18);
        assertFalse(pos[2].isDebt);

        // Identity derived on-chain: positionId = abi.encode(pool) (reserve lives in balanceAsset),
        // protocolSubId = AAVE_V3_LENDING, protocolId = AAVE_V3, protocolBrand = AAVE.
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAdapter, address(adapter));
            assertEq(pos[i].protocolSubId, keccak256("aave-v3-lending"));
            assertEq(pos[i].protocolId, keccak256("aave-v3"));
            assertEq(pos[i].protocolBrand, keccak256("aave"));
            assertEq(pos[i].positionId, abi.encode(pool), "positionId = abi.encode(pool), no reserve");
        }
    }

    function test_borrowLeg_sumsStableAndVariableDebt() public {
        // Legacy stable debt + variable debt on the same reserve must collapse into ONE Borrowed leg.
        // Emitting them as two rows would share the same (protocolId, positionId, balanceAsset, Borrowed)
        // key and collide; the sum is what NAV needs.
        dp.setUserData(alice, address(usdc), 0, 400e6, false); // variable debt
        dp.setStableDebt(alice, address(usdc), 100e6); // legacy stable debt on the same reserve

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 1, "single Borrowed leg (stable + variable summed)");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertTrue(pos[0].isDebt);
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Borrowed));
        assertEq(pos[0].amount, 500e6, "variable(400) + stable(100)");
        assertEq(pos[0].positionId, abi.encode(pool));
    }

    function test_assetFilter_returnsOnlyAsset() public {
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        dp.setUserData(alice, address(usdc), 1000e6, 400e6, false);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(usdc));
        assertEq(pos.length, 2, "USDC supply + borrow");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[1].balanceAsset.asset, address(usdc));
    }

    function test_noPosition_empty() public view {
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_ids());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }

    //
    // Unreportable debt must never leave supplies standing alone (over-report)
    //

    /// @dev Bitmap path: the account borrows a reserve whose asset is NOT registered, so the adapter cannot
    ///      emit that debt leg. Reporting the registered supply alone would count the position as pure credit
    ///      and over-report NAV by the whole borrow, so the entire instance must report nothing.
    function test_unreportableDebt_viaBitmap_suppressesInstance() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18); // deliberately NOT registered
        dp.addReserve("XYZ", address(unregistered));
        address[] memory list = new address[](3);
        list[0] = address(usdc);
        list[1] = address(weth);
        list[2] = address(unregistered);
        pool.setReservesList(list);

        dp.setUserData(alice, address(weth), 5e18, 0, true); // registered supply
        dp.setUserData(alice, address(unregistered), 0, 100e18, false); // unreportable debt
        pool.setBorrowing(2); // reserve index 2 == the unregistered token

        assertEq(
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(0)).length,
            0,
            "supplies must not be reported without the unreportable debt"
        );
        assertEq(
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(weth)).length,
            0,
            "assetFilter must not resurrect the unoffset supply leg"
        );
    }

    /// @dev The mirror case: a borrow on a REGISTERED reserve is reportable, so the position is emitted
    ///      normally. Without this, the pre-pass could suppress everything and the suite would not notice.
    function test_reportableDebt_viaBitmap_stillReports() public {
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        dp.setUserData(alice, address(usdc), 0, 400e6, false);
        pool.setBorrowing(0); // reserve index 0 == USDC, registered

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(p.length, 2, "registered supply + registered borrow both reported");
    }

    /// @dev Fallback path: a pool without the bitmap (here, no code at all) must still detect the unreportable
    ///      debt by scanning reserves — and must not revert, which it did before the explicit code check
    ///      (Solidity's non-contract-call check fires in the caller frame and `try` cannot catch it).
    function test_unreportableDebt_viaScanFallback_suppressesInstance() public {
        MockAaveAddressesProvider ap2 = new MockAaveAddressesProvider(codelessPool, "codeless");
        MockAaveDataProvider dp2 = new MockAaveDataProvider(address(ap2));
        dp2.addReserve("WETH", address(weth));
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18);
        dp2.addReserve("XYZ", address(unregistered));
        dp2.setUserData(alice, address(weth), 5e18, 0, true);
        dp2.setUserData(alice, address(unregistered), 0, 100e18, false);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(uint160(address(dp2))));
        assertEq(
            adapter.getAdapterPositionsForInstances(alice, ids, address(0)).length,
            0,
            "scan fallback must suppress, not revert"
        );

        // `length == 0` is ALSO what per-instance revert isolation returns, so the assertion above cannot by
        // itself tell suppression from a swallowed revert. Pin it down: with the unreportable debt cleared,
        // the very same code-less-pool path must report the supply leg.
        dp2.setUserData(alice, address(unregistered), 0, 0, false);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(alice, ids, address(0));
        assertEq(p.length, 1, "the fallback path itself must work, not merely revert into an empty array");
        assertEq(p[0].balanceAsset.asset, address(weth));
    }

    /// @dev A borrowing bit can outlive the debt: Aave clears it only on an exact-full repay (unscaled), while
    ///      the debt token burns scaled with rounding. Suppressing on the bit alone would erase the instance
    ///      from NAV permanently, and would disagree with the scan fallback, which requires debt > 0.
    function test_staleBorrowingBit_withZeroDebt_doesNotSuppress() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18);
        dp.addReserve("XYZ", address(unregistered));
        pool.setReserveById(4, address(unregistered));
        pool.setBorrowing(4); // bit set...
        dp.setUserData(alice, address(unregistered), 0, 0, false); // ...but the debt is gone
        dp.setUserData(alice, address(weth), 5e18, 0, true);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(p.length, 1, "a stale borrowing bit with no debt must not suppress the instance");
        assertEq(p[0].balanceAsset.asset, address(weth));
    }

    /// @dev Regression: the user-configuration bitmap is keyed on a reserve's STORED id, but
    ///      `getReservesList()` compacts out dropped reserves and truncates, so after any `dropReserve` list
    ///      index != id. Indexing the list positionally checked the WRONG asset — either missing the
    ///      unreportable borrow (over-report) or suppressing a healthy instance. Stages that divergence: the
    ///      borrowed reserve sits at id 5 while the compacted list holds a registered asset at index 5.
    function test_droppedReserve_idNotListIndex_stillDetectsUnreportableDebt() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18); // deliberately NOT registered
        dp.addReserve("XYZ", address(unregistered));

        // Compacted list: index 5 is a REGISTERED asset (what the buggy positional lookup would have read).
        address[] memory list = new address[](6);
        list[0] = address(usdc);
        list[1] = address(weth);
        list[2] = address(usdc);
        list[3] = address(weth);
        list[4] = address(usdc);
        list[5] = address(weth);
        pool.setReservesList(list);
        // True id mapping: id 5 is the UNREGISTERED token the account actually borrows.
        pool.setReserveById(5, address(unregistered));

        dp.setUserData(alice, address(weth), 5e18, 0, true); // registered supply
        dp.setUserData(alice, address(unregistered), 0, 100e18, false); // unreportable debt
        pool.setBorrowing(5);

        assertEq(
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(0)).length,
            0,
            "must resolve the borrowed reserve by id, not by list position"
        );
    }

    /// @dev A borrow on a DROPPED reserve id (address(0)) must be skipped, not treated as unreportable.
    function test_droppedReserve_zeroAddress_doesNotSuppress() public {
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        pool.setReserveById(7, address(0)); // dropped
        pool.setBorrowing(7);

        assertGt(
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(0)).length,
            0,
            "a dropped reserve id must not suppress the instance"
        );
    }

    /// @dev A pool that answers `getUserConfiguration` with fewer than 32 bytes must reach the scan fallback,
    ///      not revert. `try` catches neither the non-contract check nor a return-data decode failure, so the
    ///      bitmap read is a low-level staticcall; without that this reverts into an empty array instead.
    function test_shortConfigReturndata_reachesScanFallback() public {
        pool.setConfigReturnsShort(true);
        dp.setUserData(alice, address(weth), 5e18, 0, true);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(p.length, 1, "must fall back to the scan and still report");
        assertEq(p[0].balanceAsset.asset, address(weth));
    }
}
