// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {LidoStVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/LidoStVaultsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal ERC20-ish token used only as a registry address.
contract MockToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Lido `VaultHub` mock. Each read can be made to REVERT or to answer with ZERO BYTES independently —
///         the two failure shapes the adapter must treat identically (as "no value"), and which a bare staticcall
///         success flag cannot tell apart.
contract MockVaultHub {
    mapping(address => address) public connOwner;
    mapping(address => uint256) public tv;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public feesToSettle;
    mapping(address => uint256) public sharesToBurn;

    bool public revertShares;
    bool public revertObligations;
    bool public revertTotalValue;
    bool public emptyShares; // succeed but return 0 bytes

    function setConn(address vault, address owner_) external {
        connOwner[vault] = owner_;
    }

    function set(address vault, uint256 tv_, uint256 shares_, uint256 burn_, uint256 fees_) external {
        tv[vault] = tv_;
        shares[vault] = shares_;
        sharesToBurn[vault] = burn_;
        feesToSettle[vault] = fees_;
    }

    function setRevertShares(bool v) external {
        revertShares = v;
    }

    function setRevertObligations(bool v) external {
        revertObligations = v;
    }

    function setRevertTotalValue(bool v) external {
        revertTotalValue = v;
    }

    function setEmptyShares(bool v) external {
        emptyShares = v;
    }

    /// @dev Returns ONLY the owner word. The real struct has more fields, but the adapter reads the first word by
    ///      design, so a one-word reply is the shape it is written against.
    function vaultConnection(address vault) external view returns (address) {
        return connOwner[vault];
    }

    function totalValue(address vault) external view returns (uint256) {
        require(!revertTotalValue, "totalValue");
        return tv[vault];
    }

    function liabilityShares(address vault) external view returns (uint256) {
        require(!revertShares, "liabilityShares");
        if (emptyShares) {
            assembly {
                return(0, 0)
            }
        }
        return shares[vault];
    }

    function obligations(address vault) external view returns (uint256, uint256) {
        require(!revertObligations, "obligations");
        return (sharesToBurn[vault], feesToSettle[vault]);
    }
}

/// @notice stETH mock — shares→ether at a settable rate, so the test can prove the Borrowed leg routes through it.
contract MockStETH {
    uint256 public rate; // ether per share, 1e18-scaled
    bool public brokenRate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setBrokenRate(bool v) external {
        brokenRate = v;
    }

    function getPooledEthByShares(uint256 s) external view returns (uint256) {
        require(!brokenRate, "rate");
        return (s * rate) / 1e18;
    }
}

/// @notice Dashboard mock — OZ-style `hasRole` plus `accruedFee()`, either of which can be made to revert.
contract MockDashboard {
    mapping(address => bool) public admin;
    uint256 public fee;
    bool public revertFee;
    bool public revertRole;

    function setAdmin(address a, bool v) external {
        admin[a] = v;
    }

    function setFee(uint256 v) external {
        fee = v;
    }

    function setRevertFee(bool v) external {
        revertFee = v;
    }

    function setRevertRole(bool v) external {
        revertRole = v;
    }

    function hasRole(bytes32 role, address a) external view returns (bool) {
        require(!revertRole, "role");
        return role == bytes32(0) && admin[a];
    }

    function accruedFee() external view returns (uint256) {
        require(!revertFee, "fee");
        return fee;
    }
}

/// @title LidoStVaultsMetaBalanceAdapter unit tests (no fork)
contract LidoStVaultsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    LidoStVaultsMetaBalanceAdapter meta;
    MockVaultHub hub;
    MockStETH steth;
    MockToken eth;
    MockDashboard dash;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address vaultDirect = makeAddr("vaultDirect"); // owned by alice directly
    address vaultDash; // owned by a Dashboard alice administers

    function setUp() public {
        nav = new Mock_NAVCalculator();
        eth = new MockToken();
        steth = new MockStETH(2e18); // 1 share = 2 ether — deliberately NOT 1:1
        hub = new MockVaultHub();
        dash = new MockDashboard();

        nav.registerAsset(address(eth), 18, "ETH");
        nav.registerAsset(address(steth), 18, "stETH");

        meta = new LidoStVaultsMetaBalanceAdapter(address(hub), address(steth), address(eth), address(nav));

        vaultDash = makeAddr("vaultDash");
        hub.setConn(vaultDirect, alice);
        hub.setConn(vaultDash, address(dash));
        dash.setAdmin(alice, true);
        dash.setFee(7);

        // vaultDirect: 100 value, 3 shares of debt (=6 ether), 5 feesToSettle, 11 sharesToBurn (must be IGNORED)
        hub.set(vaultDirect, 100, 3e18, 11, 5);
        // vaultDash:  200 value, 0 debt, 0 feesToSettle -> fee leg is the Dashboard's accruedFee alone
        hub.set(vaultDash, 200, 0, 0, 0);
    }

    function _one(address v) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(v)));
    }

    function _get(address who, address v, address filter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return meta.getAdapterPositionsForInstances(who, _one(v), filter);
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    // ── legs ────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Direct-owner path: no Dashboard in the chain, so `accruedFee` is not part of the obligation.
    function test_directOwner_threeLegs_sharesConvertedThroughStEth() public view {
        INAVCalculator.PositionBalance[] memory p = _get(alice, vaultDirect, address(0));
        assertEq(p.length, 3, "staking + borrowed + fees");

        assertEq(p[0].amount, 100);
        assertFalse(p[0].isDebt);
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Staking));
        assertEq(p[0].balanceAsset.asset, address(eth));

        // 3e18 SHARES at 2e18 ether/share = 6e18 ether. A 1:1 read would give 3e18 — this is the scaling trap.
        assertEq(p[1].amount, 6e18, "liabilityShares must convert through stETH, not 1:1");
        assertTrue(p[1].isDebt);
        assertEq(uint256(p[1].positionKind), uint256(PositionKind.Borrowed));
        assertEq(p[1].balanceAsset.asset, address(steth), "debt is denominated in stETH");

        // feesToSettle only (5); sharesToBurn (11) must NOT be added — it is a subset of liabilityShares.
        assertEq(p[2].amount, 5, "sharesToBurn must not be double-counted into the fee leg");
        assertTrue(p[2].isDebt);
        assertEq(uint256(p[2].positionKind), uint256(PositionKind.Fees));
        assertEq(p[2].balanceAsset.asset, address(eth));

        // identity: all three legs share the vault coordinate
        assertEq(p[0].positionId, abi.encode(vaultDirect));
        assertEq(p[1].positionId, p[0].positionId);
        assertEq(p[2].positionId, p[0].positionId);
        assertEq(p[0].balanceAdapter, address(meta));
    }

    /// @dev Dashboard path: the node-operator `accruedFee()` IS part of the obligation.
    function test_dashboardAdmin_feeLegIsAccruedFee() public view {
        INAVCalculator.PositionBalance[] memory p = _get(alice, vaultDash, address(0));
        assertEq(p.length, 2, "staking + fees (no debt)");
        assertEq(p[0].amount, 200);
        assertEq(p[1].amount, 7, "accruedFee");
        assertEq(uint256(p[1].positionKind), uint256(PositionKind.Fees));
        assertTrue(p[1].isDebt);
    }

    // ── ownership ───────────────────────────────────────────────────────────────────────────────────────────────

    function test_nonOwner_reportsNothing() public view {
        assertEq(_get(bob, vaultDirect, address(0)).length, 0);
        assertEq(_get(bob, vaultDash, address(0)).length, 0);
    }

    function test_unconnectedVault_reportsNothing() public {
        address ghost = makeAddr("ghost");
        hub.set(ghost, 999, 0, 0, 0);
        assertEq(_get(alice, ghost, address(0)).length, 0, "owner == 0 means not connected");
    }

    /// @dev A Dashboard whose `hasRole` reverts must read as NOT controlled, never as controlled.
    function test_roleProbeReverts_failsClosed() public {
        dash.setRevertRole(true);
        assertEq(_get(alice, vaultDash, address(0)).length, 0);
    }

    // ── the whole-drop rule ─────────────────────────────────────────────────────────────────────────────────────

    function test_liabilitySharesReverts_dropsWholeInstance() public {
        hub.setRevertShares(true);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0, "never assets without their debt");
    }

    /// @dev THE FAIL-OPEN THIS ORDERING EXISTS TO PREVENT. A callee returning ZERO BYTES *succeeds*: the raw
    ///      staticcall flag is true. Reading that as `debt == 0` would emit the vault's full value with no debt —
    ///      an over-report that no revert-based test would catch. The adapter requires `hasWord`, so this drops.
    function test_liabilitySharesReturnsNoData_dropsWholeInstance() public {
        hub.setEmptyShares(true);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0, "empty reply is not a zero debt");
    }

    function test_obligationsReverts_dropsWholeInstance() public {
        hub.setRevertObligations(true);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0);
    }

    function test_accruedFeeReverts_dropsWholeInstance() public {
        dash.setRevertFee(true);
        assertEq(_get(alice, vaultDash, address(0)).length, 0);
    }

    function test_stEthRateReverts_dropsWholeInstance() public {
        steth.setBrokenRate(true);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0);
    }

    function test_totalValueReverts_dropsWholeInstance() public {
        hub.setRevertTotalValue(true);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0);
    }

    /// @dev A debt that can be READ but not REPORTED (stETH unregistered) is the same over-report as an unreadable
    ///      one, so it drops too — but only when there IS debt.
    function test_unregisteredStEth_dropsInstanceOnlyWhenThereIsDebt() public {
        Mock_NAVCalculator nav2 = new Mock_NAVCalculator();
        nav2.registerAsset(address(eth), 18, "ETH"); // stETH deliberately NOT registered
        LidoStVaultsMetaBalanceAdapter m2 =
            new LidoStVaultsMetaBalanceAdapter(address(hub), address(steth), address(eth), address(nav2));

        bytes32[] memory withDebt = _one(vaultDirect);
        assertEq(m2.getAdapterPositionsForInstances(alice, withDebt, address(0)).length, 0, "debt unreportable");

        bytes32[] memory noDebt = _one(vaultDash);
        assertEq(m2.getAdapterPositionsForInstances(alice, noDebt, address(0)).length, 2, "no debt -> still reports");
    }

    // ── filter, zeros, labels ───────────────────────────────────────────────────────────────────────────────────

    function test_assetFilter_selectsLegs() public view {
        assertEq(_get(alice, vaultDirect, address(eth)).length, 2, "staking + fees");
        assertEq(_get(alice, vaultDirect, address(steth)).length, 1, "borrowed only");
        assertEq(_get(alice, vaultDirect, address(0xdead)).length, 0, "foreign filter");
    }

    function test_zeroLegsAreDropped() public {
        hub.set(vaultDirect, 0, 0, 0, 0);
        assertEq(_get(alice, vaultDirect, address(0)).length, 0);
    }

    function test_instanceAssets() public view {
        address[] memory a = meta.instanceAssets(bytes32(uint256(uint160(vaultDirect))));
        assertEq(a.length, 2);
        assertEq(a[0], address(eth));
        assertEq(a[1], address(steth));
    }

    function test_positionLabels() public view {
        string[] memory l = meta.positionLabels(abi.encode(vaultDirect));
        assertEq(l.length, 2);
        assertEq(l[0], "stVault");
        assertEq(l[1], string.concat("ETH ", vaultDirect.toHexString()));
    }

    /// @dev Display-only: must never revert, including for a coordinate this adapter never emitted.
    function test_positionLabels_malformedCoordinates() public view {
        assertEq(meta.positionLabels(hex"1234").length, 0, "short pid");
        assertEq(meta.positionLabels(abi.encode(uint256(1), uint256(2))).length, 0, "multi-word pid");
        // dirty upper bits must degrade to the category, not revert
        string[] memory dirty = meta.positionLabels(abi.encode(uint256(type(uint256).max)));
        assertEq(dirty.length, 1);
        assertEq(dirty[0], "stVault");
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }
}
