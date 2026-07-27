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
import {RawReplier, RawReplyLib} from "test/mocks/RawReplier.sol";

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
        adapter = new AaveV3InstancesMetaBalanceAdapter(address(balances));
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

/// @title AaveV3InstancesMetaBalanceAdapter — `positionLabels` fail-open tests
/// @notice `positionLabels` is a verbose/display-only path and MUST NOT revert, whatever the instance's pool or
///         addresses-provider answers with. The label chain is `pool.ADDRESSES_PROVIDER()` →
///         `addressesProvider.getMarketId()`, and BOTH hops can fail in ways a `try`/`catch` does not cover:
///         Solidity's `extcodesize` precheck fires before a high-level call to a code-less address, and a return-data
///         **decode** failure reverts in the *calling* frame, so it propagates straight past `catch`. Each test below
///         stages exactly one such shape via {RawReplier} and asserts the label degrades to `["Market"]`.
contract AaveV3InstancesMetaLabelReadTest is BalanceAdapterTestBase {
    /// @dev The gas the whole external `positionLabels` call may consume against a hostile target. Comfortably above
    ///      the two 100k stipends the adapter forwards, and far below what an uncapped probe costs — the gas-burning
    ///      and giant-revert-payload cases below each cost tens of millions without the cap.
    uint256 private constant GAS_CEILING = 1_000_000;

    /// @dev Mirrors the adapter's private `LABEL_READ_GAS`, so a test can assert a hop really burned its stipend.
    uint256 private constant LABEL_READ_GAS = 100_000;

    /// @dev Deliberately much tighter than {GAS_CEILING}. The 150 KB revert payload costs ~82k with the explicit
    ///      staticcall output size and ~153k without it (the caller would `returndatacopy` all 150 KB and pay the
    ///      quadratic memory expansion). A loose ceiling would pass in BOTH cases and assert nothing — this bound is
    ///      what makes removing the output size a test failure rather than a silent regression.
    uint256 private constant OUTPUT_CAP_CEILING = 120_000;

    AaveV3InstancesMetaBalanceAdapter public adapter;
    RawReplier public poolReplier;
    RawReplier public providerReplier;

    address public constant CODELESS = 0x2222222222222222222222222222222222222222;

    function setUp() public override {
        super.setUp();
        adapter = new AaveV3InstancesMetaBalanceAdapter(address(balances));
        poolReplier = new RawReplier();
        providerReplier = new RawReplier();
        // Default chain: pool resolves to the provider, provider answers with a normal market id.
        poolReplier.stageReturn(abi.encode(address(providerReplier)));
        providerReplier.stageReturn(RawReplyLib.canonicalString("Aave V3 Test Instance"));
    }

    function _labelsFor(address pool) internal view returns (string[] memory) {
        return adapter.positionLabels(abi.encode(pool));
    }

    function _assertCollapsed(address pool, string memory why) internal view {
        string[] memory l = _labelsFor(pool);
        assertEq(l.length, 1, why);
        assertEq(l[0], "Market", why);
    }

    // ----- control: the chain works, so every "collapsed" assertion below is about the staged failure -----

    function test_labels_canonicalChain_returnsMarketId() public view {
        string[] memory l = _labelsFor(address(poolReplier));
        assertEq(l.length, 2);
        assertEq(l[0], "Market");
        assertEq(l[1], "Aave V3 Test Instance");
    }

    function test_labels_shortPositionId_empty() public view {
        assertEq(adapter.positionLabels(hex"1234").length, 0);
    }

    // ----- hop 1: pool.ADDRESSES_PROVIDER() -----

    /// @dev Class 1 — no code at all. The `extcodesize` precheck reverts in this frame, before the call.
    function test_labels_codelessPool_collapses() public view {
        _assertCollapsed(CODELESS, "a code-less pool must not revert the label");
    }

    /// @dev Class 2 — the one a `catch` would have covered. Kept so the rewrite is proven not to have lost it.
    function test_labels_revertingPool_collapses() public {
        poolReplier.stageRevert(4);
        _assertCollapsed(address(poolReplier), "a reverting pool must not revert the label");
    }

    /// @dev Class 3 — succeeds, but with fewer than 32 bytes. `abi.decode(…, (address))` would revert here.
    function test_labels_poolReturnsShortWord_collapses() public {
        poolReplier.stageReturn(hex"1234");
        _assertCollapsed(address(poolReplier), "an 8-byte ADDRESSES_PROVIDER reply must not revert the label");
    }

    /// @dev Class 3 — succeeds with empty returndata (the ERC-1967-proxy-to-code-less-implementation shape).
    function test_labels_poolReturnsNothing_collapses() public {
        poolReplier.stageReturn("");
        _assertCollapsed(address(poolReplier), "an empty ADDRESSES_PROVIDER reply must not revert the label");
    }

    /// @dev Class 3, tolerated rather than rejected: a full word whose bits above 160 are dirty. `abi.decode` would
    ///      revert on the cleanup check; the reader masks instead, matching `_hasUnreportableDebt`'s precedent in the
    ///      same contract — so the label still resolves rather than silently dropping a legitimate provider.
    function test_labels_poolReturnsDirtyAddressWord_stillResolves() public {
        poolReplier.stageReturn(RawReplyLib.dirtyAddress(address(providerReplier)));
        string[] memory l = _labelsFor(address(poolReplier));
        assertEq(l.length, 2, "dirty upper bits must be masked off, not reverted on");
        assertEq(l[1], "Aave V3 Test Instance");
    }

    /// @dev The provider resolved from the pool is itself code-less.
    function test_labels_codelessProvider_collapses() public {
        poolReplier.stageReturn(abi.encode(CODELESS));
        _assertCollapsed(address(poolReplier), "a code-less addresses provider must not revert the label");
    }

    // ----- hop 2: addressesProvider.getMarketId() -----

    function test_labels_revertingProvider_collapses() public {
        providerReplier.stageRevert(4);
        _assertCollapsed(address(poolReplier), "a reverting getMarketId must not revert the label");
    }

    /// @dev MKR-era shape: `getMarketId()` answers with a single `bytes32` word.
    function test_labels_bytes32MarketId_collapses() public {
        providerReplier.stageReturn(RawReplyLib.bytes32String("Aave Ethereum Market"));
        _assertCollapsed(address(poolReplier), "a bytes32-shaped market id must not revert the label");
    }

    /// @dev The proxy-with-code-less-implementation shape: `delegatecall` succeeds and returns nothing.
    function test_labels_emptyReturndataMarketId_collapses() public {
        providerReplier.stageReturn("");
        _assertCollapsed(address(poolReplier), "empty returndata must not revert the label");
    }

    /// @dev A dynamic-type head with an offset word but no length word.
    function test_labels_offsetOnlyMarketId_collapses() public {
        providerReplier.stageReturn(RawReplyLib.offsetOnly());
        _assertCollapsed(address(poolReplier), "a head with no length word must not revert the label");
    }

    /// @dev The offset points past the head. Real decoders follow it into unallocated returndata.
    function test_labels_badOffsetMarketId_collapses() public {
        providerReplier.stageReturn(RawReplyLib.badOffset(0x40, "Aave Ethereum Market"));
        _assertCollapsed(address(poolReplier), "a non-0x20 offset must not revert the label");
    }

    /// @dev A declared length far beyond the returndata.
    function test_labels_absurdLengthMarketId_collapses() public {
        providerReplier.stageReturn(RawReplyLib.declaredLength(type(uint256).max, "x"));
        _assertCollapsed(address(poolReplier), "an absurd declared length must not revert the label");
    }

    /// @dev The bound is `len <= size - 64` on the RAW declared length, not on `ceil32(len)`. Pin that: a reply
    ///      whose payload is in-bounds but NOT padded to a 32-byte boundary must still decode. Verified on solc
    ///      0.8.34 that a memory-source `abi.decode` bounds on the raw length; if a future compiler tightened it to
    ///      the padded bound, `_safeStringRead` would start reverting on unpadded replies and this test would catch
    ///      it. (`NAVCalculator._safeString` carries a comment asserting the opposite and uses a ceil32 bound — it
    ///      is merely stricter, not safer, and is outside this PR.)
    function test_labels_unpaddedPayload_stillDecodes() public {
        // offset 0x20, len 5, exactly 5 bytes of payload => returndatasize 69, not a multiple of 32.
        providerReplier.stageReturn(RawReplyLib.declaredLength(5, "short"));
        string[] memory l = _labelsFor(address(poolReplier));
        assertEq(l.length, 2, "an unpadded but in-bounds payload must decode, not degrade");
        assertEq(l[1], "short");
    }

    /// @dev A plausible length whose payload is truncated — the classic partial-returndata shape.
    function test_labels_truncatedPayloadMarketId_collapses() public {
        providerReplier.stageReturn(RawReplyLib.declaredLength(100, "short"));
        _assertCollapsed(address(poolReplier), "a truncated payload must not revert the label");
    }

    // ----- bounds -----

    /// @dev The length cap is a deliberate NEW constraint: a 256-byte market id still renders, 257 degrades.
    /// @dev Note which clause actually fires. 257 bytes encodes to 64 + ceil32(257) = 352, so it is rejected by
    ///      `size > MAX_RETURN_BYTES`, NOT by `len > MAX_LABEL_BYTES` — that clause is currently unreachable (see
    ///      the {MAX_LABEL_BYTES} docstring). What this pins is the *observable* cap and, more usefully, that 256 is
    ///      genuinely accepted: the two constants are exactly one head apart, so a valid maximum-length label must
    ///      not be rejected by an off-by-one.
    function test_labels_lengthCapBoundary() public {
        providerReplier.stageReturn(RawReplyLib.stringOfLength(256));
        assertEq(_labelsFor(address(poolReplier)).length, 2, "256 bytes is inside the cap");

        providerReplier.stageReturn(RawReplyLib.stringOfLength(257));
        _assertCollapsed(address(poolReplier), "past the cap the label degrades rather than rendering");
    }

    /// @notice A reply with a large zero-padded tail BEHIND a short, in-cap market id must still render.
    /// @dev **This is a deliberate widening**, inherited by routing through {LabelLib}. The hand-rolled
    ///      `_safeStringRead` this replaced rejected any reply larger than its 320-byte window outright, so it
    ///      dropped the leaf here. LabelLib bounds on what was COPIED instead, which PR #165 changed precisely
    ///      because the shape is real: Curve's USD-metapool factory LP tokens return a fixed 4096-byte buffer
    ///      behind a canonical head, carrying strings of only 10-57 bytes.
    ///
    ///      Note this does NOT loosen the length cap — {test_labels_oversizedReply_collapses} still collapses,
    ///      because there the declared STRING is 2048 bytes. The distinction is reply size vs. content size.
    function test_labels_paddedBufferMarketId_renders() public {
        bytes memory tail = new bytes(4096 - 64);
        bytes memory id = bytes("Aave V3 Padded");
        for (uint256 i = 0; i < id.length; i++) {
            tail[i] = id[i];
        }
        providerReplier.stageReturn(abi.encodePacked(uint256(0x20), id.length, tail));

        string[] memory l = _labelsFor(address(poolReplier));
        assertEq(l.length, 2, "an in-cap market id must survive a large zero-padded tail");
        assertEq(l[1], "Aave V3 Padded", "the market id must decode verbatim");
    }

    /// @dev Collapses because of the declared STRING length, not the reply size — `stringOfLength(2048)` puts
    ///      2048 bytes past the two head words, well past the 256-byte cap. Reply size alone no longer rejects
    ///      anything (see the padded-buffer test above), so this pins the CONTENT cap; the two are independent.
    function test_labels_oversizedReply_collapses() public {
        providerReplier.stageReturn(RawReplyLib.stringOfLength(2048));
        _assertCollapsed(address(poolReplier), "a string past the cap must not revert or truncate");
    }

    /// @dev Exercises the GAS STIPEND, not the output cap. A 3 MB revert payload costs the callee ~17.4M gas in
    ///      memory expansion alone, so under a 100k stipend it halts exceptionally *before* the REVERT executes:
    ///      `ok` is false and `returndatasize()` is 0. That is exactly the protection being asserted — but it means
    ///      this test would still pass if the explicit staticcall output size were removed, which is why
    ///      {test_labels_affordableRevertPayload_isOutputCapped} exists alongside it.
    function test_labels_giantRevertPayload_isGasBounded() public {
        providerReplier.stageRevert(3_000_000);
        uint256 before = gasleft();
        _assertCollapsed(address(poolReplier), "a giant revert payload must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the probe must be gas-capped");
    }

    /// @dev Exercises the OUTPUT CAP. A revert payload the callee can actually afford inside its stipend (150 KB
    ///      costs it ~57k of memory expansion) genuinely reaches the caller, so `returndatasize()` really is 150,000.
    ///      A raw `staticcall` assigning `(bool, bytes memory)` would `returndatacopy` all of it — the parameterless
    ///      `catch {}` this replaced never did, which is why an uncapped rewrite would be worse than the bug. The
    ///      explicit output size keeps the copy at 320 bytes no matter what came back.
    function test_labels_affordableRevertPayload_isOutputCapped() public {
        providerReplier.stageRevert(150_000);
        uint256 before = gasleft();
        _assertCollapsed(address(poolReplier), "an affordable revert payload must not revert the label");
        assertLt(before - gasleft(), OUTPUT_CAP_CEILING, "the copied returndata must be capped, not the full payload");
    }

    /// @dev Same cap, other direction: a callee that simply never returns.
    function test_labels_gasBurningProvider_isGasBounded() public {
        providerReplier.stageBurnGas();
        uint256 before = gasleft();
        _assertCollapsed(address(poolReplier), "a gas-burning provider must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the probe must be gas-capped");
    }

    /// @dev The FIRST hop, gas-burning. Deliberately named for hop 1 only: a pool that burns its stipend fails, so
    ///      `ap` is `address(0)` and `_safeStringRead` is never reached. "Both hops burn" is not constructible —
    ///      a hop that consumes its whole stipend is by definition a hop that failed, which short-circuits the next
    ///      one. The per-hop bound is what is testable, and it is what {test_labels_gasBurningProvider_isGasBounded}
    ///      covers for hop 2.
    function test_labels_gasBurningPool_isGasBounded() public {
        poolReplier.stageBurnGas();
        uint256 before = gasleft();
        _assertCollapsed(address(poolReplier), "a gas-burning pool must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the probe must be gas-capped");
    }

    /// @dev Both hops reached, the second hostile — the only shape where two probes actually run in one call. Pins
    ///      that the stipends compose rather than the second one being unbounded.
    function test_labels_bothHopsReached_secondHostile_isGasBounded() public {
        providerReplier.stageBurnGas();
        uint256 before = gasleft();
        _assertCollapsed(address(poolReplier), "hop 1 succeeding must not un-bound hop 2");
        uint256 used = before - gasleft();
        assertLt(used, GAS_CEILING, "two hops must stay inside one ceiling");
        assertGt(used, LABEL_READ_GAS, "hop 2 must genuinely have been reached and burned its stipend");
    }
}
