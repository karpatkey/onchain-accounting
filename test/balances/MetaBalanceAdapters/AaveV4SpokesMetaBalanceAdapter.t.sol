// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {
    AaveV4SpokesMetaBalanceAdapter,
    ISpoke
} from "src/balances/MetaBalanceAdapters/AaveV4SpokesMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal Spoke stand-in: reserves by numeric id, per-(reserve, user) share counters, and the
///         assets/status views the adapter reads. Shares and assets are set INDEPENDENTLY so a test can pin
///         the gate's contract (`zero shares ⇒ no read`) without the mock quietly deriving one from the other.
contract MockSpoke {
    ISpoke.Reserve[] private _reserves;
    ISpoke.ReserveConfig[] private _configs;

    mapping(uint256 => mapping(address => ISpoke.UserPosition)) private _pos;
    mapping(uint256 => mapping(address => uint256)) private _supplied;
    mapping(uint256 => mapping(address => uint256)) private _debt;
    mapping(uint256 => mapping(address => bool)) private _asCollateral;

    function addReserve(address underlying, uint8 decimals, bool borrowable) external returns (uint256 id) {
        id = _reserves.length;
        _reserves.push(
            ISpoke.Reserve({
                underlying: underlying,
                hub: address(0),
                assetId: uint16(id),
                decimals: decimals,
                collateralRisk: 0,
                flags: 0,
                dynamicConfigKey: 0
            })
        );
        _configs.push(
            ISpoke.ReserveConfig({
                collateralRisk: 0,
                paused: false,
                frozen: false,
                borrowable: borrowable,
                receiveSharesEnabled: true
            })
        );
    }

    function setSupply(uint256 id, address user, uint120 shares, uint256 assets, bool usingAsCollateral) external {
        _pos[id][user].suppliedShares = shares;
        _supplied[id][user] = assets;
        _asCollateral[id][user] = usingAsCollateral;
    }

    function setDebt(uint256 id, address user, uint120 drawnShares, uint256 assets) external {
        _pos[id][user].drawnShares = drawnShares;
        _debt[id][user] = assets;
    }

    function getReserveCount() external view returns (uint256) {
        return _reserves.length;
    }

    function getReserve(uint256 id) external view returns (ISpoke.Reserve memory) {
        return _reserves[id];
    }

    function getReserveConfig(uint256 id) external view returns (ISpoke.ReserveConfig memory) {
        return _configs[id];
    }

    function getUserPosition(uint256 id, address user) external view returns (ISpoke.UserPosition memory) {
        return _pos[id][user];
    }

    function getUserSuppliedAssets(uint256 id, address user) external view returns (uint256) {
        return _supplied[id][user];
    }

    function getUserTotalDebt(uint256 id, address user) external view returns (uint256) {
        return _debt[id][user];
    }

    function getUserReserveStatus(uint256 id, address user) external view returns (bool, bool) {
        return (_asCollateral[id][user], _debt[id][user] > 0);
    }
}

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title AaveV4SpokesMetaBalanceAdapter unit tests (no fork)
/// @notice Mirrors the mainnet Gold Spoke's shape — one collateral-only reserve (XAUt) plus borrowable
///         stablecoins — because the adapter's two most consequential behaviours are shaped by exactly that:
///         `Collateral` vs `Supplied` is decided by `getUserReserveStatus` (NOT by `suppliedShares > 0`), and
///         the label leaf is the Spoke's collateral-only reserves.
contract AaveV4SpokesMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    AaveV4SpokesMetaBalanceAdapter meta;
    MockSpoke spoke;

    MockToken xaut;
    MockToken usdc;
    MockToken usdt;

    uint256 constant XAUT_ID = 0;
    uint256 constant USDC_ID = 1;
    uint256 constant USDT_ID = 2;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        xaut = new MockToken("XAUt", 6);
        usdc = new MockToken("USDC", 6);
        usdt = new MockToken("USDT", 6);
        nav.registerAsset(address(xaut), 6, "XAUt");
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(usdt), 6, "USDT");

        spoke = new MockSpoke();
        spoke.addReserve(address(xaut), 6, false); // collateral-only, like the Gold Spoke's reserve 0
        spoke.addReserve(address(usdc), 6, true);
        spoke.addReserve(address(usdt), 6, true);

        // The mainnet fixture this mirrors: XAUt supplied AND enabled as collateral, USDC + USDT borrowed.
        spoke.setSupply(XAUT_ID, alice, 1_717_224, 1_717_224, true);
        spoke.setDebt(USDC_ID, alice, 2_359_997_132, 2_408_081_933);
        spoke.setDebt(USDT_ID, alice, 1_983_725_720, 2_016_416_799);

        meta = new AaveV4SpokesMetaBalanceAdapter(address(nav));
    }

    function _instance() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(spoke))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_protocolName_isAaveV4_notV3() public view {
        assertEq(meta.protocolName(), ProtocolNames.AAVE_V4);
    }

    /// @dev The whole taxonomy, asserted together: a copy-pasted `_protocolId()` from the V3 adapter would still
    ///      produce a plausible non-empty name, so the ids are what pin the identity.
    function test_identity_taxonomy() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p[0].protocolBrand, ProtocolIds.AAVE, "brand rolls V3 and V4 together");
        assertEq(p[0].protocolId, ProtocolIds.AAVE_V4, "ecosystem id must be v4, not v3");
        assertEq(p[0].protocolSubId, ProtocolIds.AAVE_V4_LENDING);
        assertEq(p[0].positionId, abi.encode(address(spoke)), "positionId is the Spoke, not the reserve");
        assertEq(p[0].balanceAdapter, address(meta));
        assertEq(p[0].positionInstanceId, bytes32(0));
        assertFalse(p[0].isLocked);
    }

    function test_legs_collateralAndTwoBorrows() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 3);

        assertEq(p[0].balanceAsset.asset, address(xaut));
        assertEq(p[0].amount, 1_717_224);
        assertFalse(p[0].isDebt);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Collateral));

        assertEq(p[1].balanceAsset.asset, address(usdc));
        assertEq(p[1].amount, 2_408_081_933, "amount is always positive; isDebt carries the sign");
        assertTrue(p[1].isDebt);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Borrowed));

        assertEq(p[2].balanceAsset.asset, address(usdt));
        assertEq(p[2].amount, 2_016_416_799);
        assertTrue(p[2].isDebt);
    }

    /// @dev The v4 trap the adapter exists to survive: `supply` does not auto-enable collateral, so a real
    ///      supply can sit with `usingAsCollateral == false`. Those tokens are really there and NAV must count
    ///      them — as `Supplied`, not `Collateral`, and never dropped.
    function test_supplyNotEnabledAsCollateral_isSuppliedNotDropped() public {
        spoke.setSupply(XAUT_ID, alice, 1_717_224, 1_717_224, false);
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 3);
        assertEq(p[0].amount, 1_717_224, "an unenabled supply is still a real balance");
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
    }

    function test_untouchedReserves_emitNothing() public {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(makeAddr("nobody"), _instance(), address(0));
        assertEq(p.length, 0);
    }

    /// @dev An unregistered reserve the account BORROWS suppresses the whole Spoke. Reporting the supplies alone
    ///      would overstate the position by the entire borrow, and no consumer could offset it.
    function test_unregisteredBorrowedReserve_dropsWholeSpoke() public {
        nav.unregisterAssetHelper(address(usdt));
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 0, "an unreportable debt must never leave the supplies standing alone");
    }

    /// @dev The opposite direction: an unregistered SUPPLY is merely skipped. Omitting credit understates NAV,
    ///      which is the safe direction.
    function test_unregisteredSuppliedReserve_isSkipped() public {
        nav.unregisterAssetHelper(address(xaut));
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 2);
        assertTrue(p[0].isDebt);
        assertTrue(p[1].isDebt);
    }

    /// @dev A per-asset read is a PROJECTION, not a sub-portfolio valuation: asking for XAUt returns the XAUt leg
    ///      and omits the priceable borrows, which is the requested answer (no NAV entrypoint passes a filter).
    function test_assetFilter_projectsOneLeg() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instance(), address(xaut));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(xaut));
    }

    /// @dev The gate is `getUserPosition`'s three share counters. Zero of each means the adapter must not spend
    ///      a balance read — asserted here by leaving non-zero ASSETS behind a zero share count, which only a
    ///      gate-respecting implementation reports as nothing.
    function test_zeroShares_gatesTheBalanceReads() public {
        spoke.setSupply(XAUT_ID, alice, 0, 999_999, false);
        spoke.setDebt(USDC_ID, alice, 0, 999_999);
        spoke.setDebt(USDT_ID, alice, 0, 999_999);
        assertEq(meta.getAdapterPositionsForInstances(alice, _instance(), address(0)).length, 0);
    }

    function test_unpopulatedReserve_isNeverPublishedAsAsset() public {
        spoke.addReserve(address(0), 0, false);
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instance());
        assertEq(a.length, 3);
        assertEq(a[0], address(xaut));
        assertEq(a[2], address(usdt));
    }

    /// @dev Labels name the Spoke by its risk perimeter — its collateral-only reserves — because every Spoke
    ///      answers `eip712Domain()` with the generic "Spoke" and has no on-chain name of its own.
    function test_positionLabels_collateralOnlyReserves() public view {
        string[] memory l = meta.positionLabels(abi.encode(address(spoke)));
        assertEq(l.length, 2);
        assertEq(l[0], "Spoke");
        assertEq(l[1], "XAUt");
    }

    function test_positionLabels_noCollateralOnlyReserve_collapsesToCategory() public {
        MockSpoke bare = new MockSpoke();
        bare.addReserve(address(usdc), 6, true);
        string[] memory l = meta.positionLabels(abi.encode(address(bare)));
        assertEq(l.length, 1);
        assertEq(l[0], "Spoke");
    }

    /// @dev Pins that this adapter routes its positionId through the shared guard rather than re-inlining
    ///      `abi.decode(pid, (address))` — display-only labels must never revert and never label a coordinate
    ///      the adapter could not have emitted.
    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        assertGt(meta.positionLabels(abi.encode(address(spoke))).length, 0, "one clean word is the accepted shape");
        assertEq(meta.positionLabels("").length, 0, "empty");
        assertEq(meta.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(address(spoke))) | (uint256(1) << 255);
        assertEq(meta.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(meta.positionLabels(abi.encode(address(spoke), uint256(1))).length, 0, "over-long");
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(spoke))));
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 3, "a dud Spoke must not take the good one down with it");
    }
}
