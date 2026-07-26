// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Minimal ERC4626-shaped eVault mock with a configurable share→asset rate and an on-chain name.
contract MockEVault {
    string public name;
    address private _asset;
    uint256 private _rate; // assets per share, 1e18-scaled
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, address asset_, uint256 rate_) {
        name = name_;
        _asset = asset_;
        _rate = rate_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _rate) / 1e18;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }
}

/// @notice Mock Ethereum Vault Connector — returns a settable per-account collateral list.
contract MockEVC {
    mapping(address => address[]) private _collaterals;

    function setCollaterals(address account, address[] calldata vaults) external {
        _collaterals[account] = vaults;
    }

    function getCollaterals(address account) external view returns (address[] memory) {
        return _collaterals[account];
    }
}

/// @notice Core-eVault-shaped mock: ERC4626 + a `debtOf` borrow accessor (which EulerEarn vaults lack) + an `EVC()`
///         pointer, so the adapter emits a Borrowed leg and can classify supply as Collateral vs Supplied.
contract MockCoreEVault {
    string public name;
    address private _asset;
    uint256 private _rate; // assets per share, 1e18-scaled
    address public EVC;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _debt;

    constructor(string memory name_, address asset_, uint256 rate_) {
        name = name_;
        _asset = asset_;
        _rate = rate_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _rate) / 1e18;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setDebt(address account, uint256 amount) external {
        _debt[account] = amount;
    }

    function debtOf(address account) external view returns (uint256) {
        return _debt[account];
    }

    function setEVC(address evc) external {
        EVC = evc;
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

/// @notice Core-eVault-shaped mock whose `EVC()` returns an ARBITRARY raw byte string, so a test can hand the
///         adapter returndata that succeeds but cannot be ABI-decoded as an `address` (empty returndata, a
///         `bytes32`-shaped word with dirty high bits, a short word). `debtOf` is real so the debt leg can be
///         observed surviving — or not — alongside the supply leg.
contract MockRawEvcVault {
    string public name = "Raw EVC Vault";
    address private _asset;
    bytes private _evcReturndata;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _debt;

    constructor(address asset_, bytes memory evcReturndata_) {
        _asset = asset_;
        _evcReturndata = evcReturndata_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setDebt(address account, uint256 amount) external {
        _debt[account] = amount;
    }

    function debtOf(address account) external view returns (uint256) {
        return _debt[account];
    }

    // `EVC()` is served from the fallback so the mock can return non-conforming bytes.
    fallback(bytes calldata data) external returns (bytes memory) {
        if (bytes4(data) == bytes4(keccak256("EVC()"))) return _evcReturndata;
        revert("unsupported");
    }
}

/// @notice EVC-shaped mock returning an ARBITRARY raw byte string for `getCollaterals`, so a test can hand the
///         adapter a malformed `address[]` (bad offset, absurd length, truncated payload).
contract MockRawEVC {
    bytes private _returndata;

    constructor(bytes memory returndata_) {
        _returndata = returndata_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return _returndata;
    }
}

/// @notice EVC-shaped mock that burns gas and then reverts with a large payload — the shape that makes an
///         *unbounded* raw staticcall (which always `returndatacopy`s, including revert data) worse than the
///         `try`/`catch` it replaces.
contract MockHostileEVC {
    // Always reverts, so the declared return value is never produced (left unnamed to silence solc).
    fallback(bytes calldata) external returns (bytes memory) {
        assembly {
            // Burn whatever stipend we were given, then revert with a 3MB payload.
            for {} 1 {} { if lt(gas(), 5000) { revert(0, 3000000) } }
        }
        revert("unreachable");
    }
}

/// @title EulerVaultsMetaBalanceAdapter unit tests (no fork)
/// @notice Mirrors the MorphoVaultsMeta unit suite — same MetaBalanceAdapter base + ERC4626 convertToAssets shape —
///         plus Euler-specific asserts (protocolId = euler-vaults; positionKind Supplied / Collateral when EVC-enabled /
///         Borrowed for the debt leg).
contract EulerVaultsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    EulerVaultsMetaBalanceAdapter adapter;

    MockToken usdc;
    MockToken weth;
    MockEVault vaultA; // USDC, 1:1  (kpk_RWA_USDC-shaped)
    MockEVault vaultB; // WETH, ~1.001:1 (KPK_ETH_Term-shaped, accrued)

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        vaultA = new MockEVault("KPK RWA USDC", address(usdc), 1e18);
        vaultB = new MockEVault("KPK ETH Yield Term", address(weth), 1.001e18);

        adapter = new EulerVaultsMetaBalanceAdapter("Euler", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
    }

    // ----- ERC165 -----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    // ----- no-arg base methods return empty (instance set lives on NAV) -----

    function test_noArgMethods_returnEmpty() public {
        vaultA.setBalance(alice, 1000);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        (address[] memory a, uint256[] memory amt, bool[] memory d) = adapter.getAdapterBalances(alice);
        assertEq(a.length, 0);
        assertEq(amt.length, 0);
        assertEq(d.length, 0);
        (uint256 bal, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(bal, 0);
        assertFalse(isDebt);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    // ----- instance fan-out -----

    function test_positionsForInstances_aggregatesAcrossVaults() public {
        vaultA.setBalance(alice, 1_000_000); // 1.0 USDC at 1:1
        vaultB.setBalance(alice, 1e18); // 1 share * 1.001 = 1.001 WETH

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "two positions");

        // vaultA position — USDC, supply leg, on-chain-derived identity
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1_000_000);
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].balanceAdapter, address(adapter));
        assertEq(pos[0].positionId, abi.encode(address(vaultA)));
        assertEq(pos[0].protocolSubId, ProtocolIds.EULER_VAULTS);
        assertEq(pos[0].protocolId, ProtocolIds.EULER);
        assertTrue(pos[0].positionKind == PositionKind.Supplied);

        // vaultB position (rate applied)
        assertEq(pos[1].balanceAsset.asset, address(weth));
        assertEq(pos[1].amount, 1.001e18);
        assertEq(pos[1].positionId, abi.encode(address(vaultB)));
        assertTrue(pos[1].positionKind == PositionKind.Supplied);
    }

    function test_assetFilter_returnsOnlyMatchingVault() public {
        vaultA.setBalance(alice, 1_000_000);
        vaultB.setBalance(alice, 1e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(usdc));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_zeroBalance_skipped() public {
        vaultA.setBalance(alice, 1_000_000);
        // vaultB balance left at 0
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_unregisteredAsset_skipped_othersSurvive() public {
        MockToken dai = new MockToken("DAI", 18); // not registered on NAV
        MockEVault vaultC = new MockEVault("Unregistered DAI", address(dai), 1e18);
        vaultA.setBalance(alice, 1_000_000);
        vaultC.setBalance(alice, 5_000);

        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultC))));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "unregistered vault skipped, registered one survives");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_badInstance_isolated() public {
        vaultA.setBalance(alice, 1_000_000);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(vaultA))));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "bad instance isolated, good one returned");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_emptyInstances_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }

    function test_positionLabels_returnsVaultName() public {
        vaultA.setBalance(alice, 1_000_000);
        vaultB.setBalance(alice, 1e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2);

        // pos[0] = vaultA, pos[1] = vaultB
        assertEq(pos[0].positionId, abi.encode(address(vaultA)));
        string[] memory labelsA = adapter.positionLabels(pos[0].positionId);
        assertEq(labelsA.length, 2);
        assertEq(labelsA[0], "Vault");
        assertEq(labelsA[1], "KPK RWA USDC");

        assertEq(pos[1].positionId, abi.encode(address(vaultB)));
        string[] memory labelsB = adapter.positionLabels(pos[1].positionId);
        assertEq(labelsB.length, 2);
        assertEq(labelsB[0], "Vault");
        assertEq(labelsB[1], "KPK ETH Yield Term");
    }

    // ----- borrow (debt) leg, core eVaults -----

    function test_borrowLeg_emittedAlongsideSupply() public {
        // Core eVault where alice both supplies (collateral) and borrows.
        MockCoreEVault core = new MockCoreEVault("EVK Vault eWETH-2", address(weth), 1e18);
        core.setBalance(alice, 2e18); // 2 WETH supplied
        core.setDebt(alice, 5e17); // 0.5 WETH borrowed

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 2, "supply + borrow legs");

        // Supply leg first.
        assertEq(pos[0].amount, 2e18);
        assertFalse(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        // Borrow leg second.
        assertEq(pos[1].amount, 5e17);
        assertTrue(pos[1].isDebt, "borrow leg flagged as debt");
        assertTrue(pos[1].positionKind == PositionKind.Borrowed);

        // Same asset, same on-chain-derived positionId, distinguished only by positionKind.
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[1].balanceAsset.asset, address(weth));
        assertEq(pos[0].positionId, abi.encode(address(core)));
        assertEq(pos[1].positionId, abi.encode(address(core)));
        assertEq(pos[0].protocolSubId, ProtocolIds.EULER_VAULTS);
        assertEq(pos[0].protocolId, ProtocolIds.EULER);
        assertEq(pos[1].protocolSubId, ProtocolIds.EULER_VAULTS);
        assertEq(pos[1].protocolId, ProtocolIds.EULER);
    }

    function test_borrowOnly_noSupplyLeg() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eWETH-2", address(weth), 1e18);
        core.setDebt(alice, 1e18); // borrow only, no shares

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 1, "only the borrow leg");
        assertEq(pos[0].amount, 1e18);
        assertTrue(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Borrowed);
    }

    function test_earnVault_withoutDebtOf_supplyOnly_noRevert() public {
        // EulerEarn-shaped mock (vaultA) has no debtOf; the try/catch must not drop the supply leg.
        vaultA.setBalance(alice, 1_000_000);
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 1, "supply leg survives a vault without debtOf");
        assertFalse(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
    }

    function test_supplyKind_collateralWhenEvcEnabled() public {
        MockEVC evc = new MockEVC();
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        core.setEVC(address(evc));
        core.setBalance(alice, 1_000_000); // 1 USDC supplied

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));

        // Not enabled as collateral → Supplied.
        INAVCalculator.PositionBalance[] memory s = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(s.length, 1);
        assertTrue(s[0].positionKind == PositionKind.Supplied, "unencumbered supply is Supplied");

        // Enabled as collateral on the EVC → Collateral.
        address[] memory cols = new address[](1);
        cols[0] = address(core);
        evc.setCollaterals(alice, cols);
        INAVCalculator.PositionBalance[] memory c = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(c.length, 1);
        assertTrue(c[0].positionKind == PositionKind.Collateral, "EVC-enabled supply is Collateral");
        assertFalse(c[0].isDebt);
    }

    function test_supplyKind_earnVaultWithoutEvc_isSupplied() public {
        // vaultA (EulerEarn-shaped mock) has no EVC() → _supplyKind try/catch → Supplied.
        vaultA.setBalance(alice, 1_000_000);
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1);
        assertTrue(pos[0].positionKind == PositionKind.Supplied, "vault without EVC() degrades to Supplied");
    }

    // ----- _supplyKind is genuinely fail-open -----
    //
    // Every test below hands _supplyKind a failure mode that the previous `try`/`catch` form did NOT catch —
    // Solidity routes neither a return-data decode failure nor the `extcodesize` precheck into `catch`, so the
    // revert propagated out of `_instancePositions` and the base fan-out's per-instance `catch` dropped the WHOLE
    // instance. Each test therefore asserts the two things that were actually lost, not just "no revert":
    //   (a) the supply leg is still reported, with its amount intact, classified `Supplied`; and
    //   (b) the debt leg is still reported — the sharp end, since a suppressed debt OVER-reports NAV.
    // Reverting either guard in _supplyKind turns every one of these red (they return 0 legs).

    /// @dev Helper: assert the vault still yields an intact supply leg + debt leg, with the supply classified
    ///      `Supplied` (the fail-open default).
    function _assertFailOpen(address vault, uint256 expectedSupply, uint256 expectedDebt) internal view {
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(vault)));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 2, "supply + debt legs both survive a broken EVC read");
        assertEq(pos[0].amount, expectedSupply, "supply amount untouched by the classification failure");
        assertFalse(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Supplied, "degrades to Supplied");
        assertEq(pos[1].amount, expectedDebt, "debt leg not suppressed (suppressing it would over-report NAV)");
        assertTrue(pos[1].isDebt);
        assertTrue(pos[1].positionKind == PositionKind.Borrowed);
    }

    /// @dev Mode 2 (no-code address): the vault names an `evc` that has no code. A high-level call would revert on
    ///      Solidity's `extcodesize` precheck, BEFORE the call, which `try`/`catch` cannot intercept.
    function test_supplyKind_noCodeEvc_degradesToSupplied() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        core.setEVC(address(0xBEEF)); // no code
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `EVC()` SUCCEEDS but returns nothing — the ERC-1967 shape where the
    ///      implementation slot points at a code-less address, so the `delegatecall` succeeds and returns empty.
    ///      `abi.decode(…, (address))` then reverts in the CALLING frame, past `catch`.
    function test_supplyKind_evcEmptyReturndata_degradesToSupplied() public {
        MockRawEvcVault v = new MockRawEvcVault(address(usdc), "");
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);
        _assertFailOpen(address(v), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `EVC()` returns a `bytes32`-shaped word whose high 96 bits are non-zero, which
    ///      is not a valid `address` encoding.
    function test_supplyKind_evcBytes32Shaped_degradesToSupplied() public {
        MockRawEvcVault v = new MockRawEvcVault(address(usdc), abi.encode(bytes32(type(uint256).max)));
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);
        _assertFailOpen(address(v), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `EVC()` returns fewer than 32 bytes.
    function test_supplyKind_evcShortReturndata_degradesToSupplied() public {
        MockRawEvcVault v = new MockRawEvcVault(address(usdc), hex"deadbeef");
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);
        _assertFailOpen(address(v), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `getCollaterals` returns a single word — too short to be an `address[]` head.
    function test_supplyKind_collateralsShortHead_degradesToSupplied() public {
        MockCoreEVault core = _coreWithRawEvc(abi.encode(uint256(0x20)));
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `getCollaterals` returns a non-canonical offset.
    function test_supplyKind_collateralsBadOffset_degradesToSupplied() public {
        MockCoreEVault core = _coreWithRawEvc(abi.encode(uint256(0x40), uint256(0)));
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): `getCollaterals` declares an absurd length the payload cannot back.
    function test_supplyKind_collateralsAbsurdLength_degradesToSupplied() public {
        MockCoreEVault core = _coreWithRawEvc(abi.encode(uint256(0x20), uint256(type(uint128).max)));
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev Mode 1 (decode failure): a canonical head whose declared length overruns the actual payload.
    function test_supplyKind_collateralsTruncatedPayload_degradesToSupplied() public {
        // offset 0x20, length 3, but only one element word follows.
        MockCoreEVault core = _coreWithRawEvc(abi.encode(uint256(0x20), uint256(3), uint256(0)));
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev A hostile EVC that burns its whole stipend and reverts with a 3MB payload. The raw staticcall form
    ///      always `returndatacopy`s the response — including revert data — so without {EVC_PROBE_GAS} this read
    ///      would be worse than the `try`/`catch` it replaces. Asserts both fail-open behaviour AND that the whole
    ///      account read stays cheap.
    function test_supplyKind_hostileEvcGasBomb_boundedAndFailsOpen() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        core.setEVC(address(new MockHostileEVC()));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        uint256 used = before - gasleft();

        assertEq(pos.length, 2, "hostile EVC cannot drop the legs");
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        assertLt(used, 1_000_000, "hostile EVC's cost is bounded by the probe stipend");
    }

    /// @dev The membership scan compares FULL words, so a collateral entry whose high 96 bits are dirty never
    ///      matches even when its low 160 bits are the vault — strictly under-classifying, per the fail-open
    ///      contract, rather than reverting or trusting a malformed element.
    function test_supplyKind_collateralsDirtyElement_degradesToSupplied() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        // Placeholder EVC; replaced below once the vault address is known.
        uint256 dirty = (uint256(1) << 200) | uint256(uint160(address(core)));
        core.setEVC(address(new MockRawEVC(abi.encode(uint256(0x20), uint256(1), dirty))));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev A well-formed list longer than {MAX_COLLATERALS} is refused rather than scanned, even though it does
    ///      contain the vault. Bounds the work a hostile EVC can impose; the EVC's own cap is 10.
    function test_supplyKind_collateralsOverCap_degradesToSupplied() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        uint256 n = 33; // MAX_COLLATERALS is 32
        uint256[] memory els = new uint256[](n);
        els[n - 1] = uint256(uint160(address(core)));
        core.setEVC(address(new MockRawEVC(abi.encodePacked(abi.encode(uint256(0x20), n), abi.encodePacked(els)))));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev Positive control: a canonical list at the EVC's real cap (10) that contains the vault still classifies
    ///      as `Collateral`. Guards against the hardening silently disabling classification altogether.
    function test_supplyKind_canonicalListAtEvcCap_stillCollateral() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        uint256[] memory els = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            els[i] = uint256(uint160(address(uint160(0x1000 + i))));
        }
        els[9] = uint256(uint160(address(core)));
        core.setEVC(
            address(new MockRawEVC(abi.encodePacked(abi.encode(uint256(0x20), uint256(10)), abi.encodePacked(els))))
        );
        core.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1);
        assertTrue(pos[0].positionKind == PositionKind.Collateral, "canonical EVC list still classifies Collateral");
    }

    /// @dev Mode 2 (no-code address), vault side. `_safeEvc`'s `vaultAddr.code.length` guard is defensive only:
    ///      `_instancePositions` already reverts at `asset()` on a code-less vault, long before `_supplyKind` runs,
    ///      and the base fan-out isolates it. Pinned here so the reasoning is not lost.
    function test_supplyKind_noCodeVault_isolatedBeforeSupplyKind() public {
        vaultA.setBalance(alice, 1_000_000);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code: reverts at asset()
        ins[1] = bytes32(uint256(uint160(address(vaultA))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "code-less vault isolated by the fan-out, healthy instance survives");
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
    }

    /// @dev Builds a core eVault whose EVC returns `raw` for `getCollaterals`, pre-seeded with supply + debt.
    function _coreWithRawEvc(bytes memory raw) internal returns (MockCoreEVault core) {
        core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        core.setEVC(address(new MockRawEVC(raw)));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
    }

    function test_debtLeg_respectsAssetFilter() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eWETH-2", address(weth), 1e18);
        core.setBalance(alice, 1e18);
        core.setDebt(alice, 5e17);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));

        // Filtering to USDC drops the WETH vault entirely (both legs).
        assertEq(adapter.getAdapterPositionsForInstances(alice, ins, address(usdc)).length, 0);
        // Filtering to WETH keeps both legs.
        assertEq(adapter.getAdapterPositionsForInstances(alice, ins, address(weth)).length, 2);
    }
}
