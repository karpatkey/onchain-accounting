// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {YoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/YoVaultsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @notice Minimal YoVault mock: price in assets per 1e6 shares, fee on a 1e18 scale, `previewRedeem` net of the fee
///         with YoVault's exact `_feeOnTotal` rounding, a pending-redeem map, and per-read revert switches.
contract MockYoVault {
    string public name = "yoUSD Edge";
    address public asset;
    uint256 public price = 1_026_456;
    uint256 internal _fee = 1e13;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) internal _pAssets;
    mapping(address => uint256) internal _pShares;
    bool public revertPending;
    bool public revertFee;
    bool public revertPreview;
    bool public shortPending;

    constructor(address asset_) {
        asset = asset_;
    }

    function setBalance(address a, uint256 s) external {
        balanceOf[a] = s;
    }

    function setPending(address user, uint256 assets, uint256 shares) external {
        _pAssets[user] = assets;
        _pShares[user] = shares;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setFee(uint256 f) external {
        _fee = f;
    }

    function setReverts(bool p, bool f, bool r) external {
        revertPending = p;
        revertFee = f;
        revertPreview = r;
    }

    function setShortPending(bool s) external {
        shortPending = s;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, price, 1e6);
    }

    function pendingRedeemRequest(address user) external view returns (uint256, uint256) {
        require(!revertPending, "pending");
        if (shortPending) {
            uint256 a = _pAssets[user];
            assembly {
                mstore(0, a)
                return(0, 0x20)
            }
        }
        return (_pAssets[user], _pShares[user]);
    }

    function feeOnWithdraw() external view returns (uint256) {
        require(!revertFee, "fee");
        return _fee;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        require(!revertPreview, "preview");
        uint256 a = convertToAssets(shares);
        return a - Math.mulDiv(a, _fee, _fee + 1e18, Math.Rounding.Ceil);
    }
}

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}

/// @title YoVaultsMetaBalanceAdapter unit tests (mock-only)
contract YoVaultsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    YoVaultsMetaBalanceAdapter adapter;
    MockToken usdc;
    MockYoVault vault;
    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockToken("USDC", 6);
        nav.registerAsset(address(usdc), 6, "USDC");
        vault = new MockYoVault(address(usdc));
        adapter = new YoVaultsMetaBalanceAdapter(address(nav));
    }

    function _ins() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vault))));
    }

    function _positions() internal view returns (INAVCalculator.PositionBalance[] memory) {
        return adapter.getAdapterPositionsForInstances(alice, _ins(), address(0));
    }

    function _net(uint256 gross, uint256 fee) internal pure returns (uint256) {
        return gross - Math.mulDiv(gross, fee, fee + 1e18, Math.Rounding.Ceil);
    }

    // ---- interfaces / identity ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_protocolName_isYO() public view {
        assertEq(adapter.protocolName(), ProtocolNames.YO);
        assertEq(adapter.protocolName(), "YO");
    }

    function test_positionLabels_vaultName() public view {
        string[] memory l = adapter.positionLabels(abi.encode(address(vault)));
        assertEq(l.length, 2);
        assertEq(l[0], "Vault");
        assertEq(l[1], "yoUSD Edge");
    }

    function test_instanceAssets() public view {
        address[] memory a = adapter.underlyingAssetsSupportedForInstances(_ins());
        assertEq(a.length, 1);
        assertEq(a[0], address(usdc));
    }

    // ---- held leg ----

    function test_heldOnly_oneUnlockedLeg_yoIdentity() public {
        vault.setBalance(alice, 50_000e6);
        INAVCalculator.PositionBalance[] memory p = _positions();
        assertEq(p.length, 1);
        assertEq(p[0].amount, vault.previewRedeem(50_000e6));
        assertFalse(p[0].isLocked);
        assertFalse(p[0].isDebt);
        assertEq(p[0].balanceAsset.asset, address(usdc));
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].protocolBrand, ProtocolIds.YO);
        assertEq(p[0].protocolId, ProtocolIds.YO);
        assertEq(p[0].protocolSubId, ProtocolIds.YO_VAULTS);
        assertTrue(p[0].protocolSubId != ProtocolIds.MORPHO_VAULTS, "must not be stamped morpho");
        assertEq(p[0].positionId, abi.encode(address(vault)));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertEq(p[0].positionInstanceId, bytes32(0));
    }

    // ---- pending leg ----

    function test_pendingOnly_oneLockedLeg() public {
        uint256 shares = 97_423e6;
        uint256 gross = vault.convertToAssets(shares);
        vault.setPending(alice, gross, shares);
        INAVCalculator.PositionBalance[] memory p = _positions();
        assertEq(p.length, 1);
        assertTrue(p[0].isLocked);
        assertEq(p[0].amount, _net(gross, 1e13));
        assertEq(p[0].amount, vault.previewRedeem(shares));
        assertEq(p[0].positionId, abi.encode(address(vault)));
        assertEq(p[0].protocolSubId, ProtocolIds.YO_VAULTS);
    }

    function test_heldAndPending_twoLegsSharePositionId() public {
        vault.setBalance(alice, 10_000e6);
        vault.setPending(alice, vault.convertToAssets(5_000e6), 5_000e6);
        INAVCalculator.PositionBalance[] memory p = _positions();
        assertEq(p.length, 2);
        assertFalse(p[0].isLocked);
        assertTrue(p[1].isLocked);
        assertEq(p[0].positionId, p[1].positionId);
        assertEq(p[0].amount, vault.previewRedeem(10_000e6));
        assertEq(p[1].amount, vault.previewRedeem(5_000e6));
    }

    function test_pending_lowerPrice_takesCurrent() public {
        uint256 shares = 1_000e6;
        vault.setPending(alice, vault.convertToAssets(shares), shares);
        vault.setPrice(900_000);
        assertEq(adapter.pendingValue(address(vault), alice), vault.previewRedeem(shares));
    }

    function test_pending_higherPrice_cappedAtReservation() public {
        uint256 shares = 1_000e6;
        uint256 gross = vault.convertToAssets(shares);
        vault.setPending(alice, gross, shares);
        vault.setPrice(1_200_000);
        assertEq(adapter.pendingValue(address(vault), alice), _net(gross, 1e13));
        assertLt(adapter.pendingValue(address(vault), alice), vault.previewRedeem(shares));
    }

    function test_highFee_appliedOnce_bothLegs() public {
        uint256 fee = 999e14;
        vault.setFee(fee);
        uint256 shares = 1_000e6;
        uint256 gross = vault.convertToAssets(shares);
        vault.setBalance(alice, shares);
        vault.setPending(alice, gross, shares);
        assertApproxEqAbs(adapter.heldValue(address(vault), alice), gross * 1e18 / (1e18 + fee), 1);
        assertApproxEqAbs(adapter.pendingValue(address(vault), alice), gross * 1e18 / (1e18 + fee), 1);
    }

    function testFuzz_pending_neverAboveEitherBound(uint96 shares, uint64 newPrice, uint64 fee) public {
        vm.assume(shares > 0 && newPrice > 0);
        fee = uint64(bound(fee, 0, 1e17 - 1));
        vault.setFee(fee);
        uint256 gross = vault.convertToAssets(shares);
        vm.assume(gross > 0);
        vault.setPending(alice, gross, shares);
        vault.setPrice(newPrice);
        uint256 v = adapter.pendingValue(address(vault), alice);
        assertLe(v, _net(gross, fee));
        assertLe(v, vault.previewRedeem(shares));
    }

    // ---- fail closed ----

    /// @dev A broken pending read reverts the instance; the base's isolation drops it (under-report, never a
    ///      substituted value).
    function test_failClosed_pendingRead_dropsInstance() public {
        vault.setBalance(alice, 10_000e6);
        vault.setPending(alice, vault.convertToAssets(5_000e6), 5_000e6);
        vault.setReverts(true, false, false);
        assertEq(_positions().length, 0);
        vm.expectRevert();
        adapter.pendingValue(address(vault), alice);
    }

    function test_failClosed_shortPendingReturn_dropsInstance() public {
        vault.setBalance(alice, 10_000e6);
        vault.setPending(alice, 1_026_446, 1e6);
        vault.setShortPending(true);
        assertEq(_positions().length, 0);
    }

    function test_failClosed_feeRead_dropsInstance() public {
        vault.setBalance(alice, 10_000e6);
        vault.setPending(alice, 1_026_446, 1e6);
        vault.setReverts(false, true, false);
        assertEq(_positions().length, 0);
    }

    function test_noPending_feeReadNotNeeded() public {
        vault.setBalance(alice, 10_000e6);
        vault.setReverts(false, true, false);
        INAVCalculator.PositionBalance[] memory p = _positions();
        assertEq(p.length, 1, "held leg does not depend on the fee read when nothing is pending");
        assertFalse(p[0].isLocked);
    }

    function test_failClosed_previewRevert_dropsBothLegs() public {
        vault.setBalance(alice, 10_000e6);
        vault.setPending(alice, vault.convertToAssets(5_000e6), 5_000e6);
        vault.setReverts(false, false, true);
        assertEq(_positions().length, 0);
    }

    // ---- filters / edge cases ----

    function test_zeroAccount_andZeroFields() public {
        assertEq(adapter.pendingValue(address(vault), address(0)), 0);
        assertEq(adapter.heldValue(address(vault), address(0)), 0);
        vault.setPending(alice, 1_026_446, 0);
        assertEq(adapter.pendingValue(address(vault), alice), 0);
        vault.setPending(alice, 0, 1e6);
        assertEq(adapter.pendingValue(address(vault), alice), 0);
    }

    function test_assetFilter() public {
        vault.setBalance(alice, 1_000e6);
        assertEq(adapter.getAdapterPositionsForInstances(alice, _ins(), address(usdc)).length, 1);
        assertEq(adapter.getAdapterPositionsForInstances(alice, _ins(), makeAddr("other")).length, 0);
    }

    function test_unregisteredAsset_dropped() public {
        MockToken other = new MockToken("OTHER", 6);
        MockYoVault v2 = new MockYoVault(address(other));
        v2.setBalance(alice, 1_000e6);
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(v2))));
        assertEq(adapter.getAdapterPositionsForInstances(alice, ins, address(0)).length, 0);
    }
}
