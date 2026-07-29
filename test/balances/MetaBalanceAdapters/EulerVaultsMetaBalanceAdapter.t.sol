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

/// @notice A vault whose `debtOf` does real work and THEN reverts — expensive, but finite and legitimate.
/// @dev The shape a proxy/dispatcher hop or an upgraded vault produces. It is the far side of the classifier
///      from a gas bomb, and the two must land on opposite verdicts: this one has ANSWERED (with a revert), so
///      the supply leg must survive. `MockEVault`'s bare dispatch-fallthrough revert is the cheapest possible
///      case and brackets the classifier only where it cannot plausibly bind; this brackets it where it can.
contract MockExpensiveRevertVault {
    string public name = "EVK Vault eUSDC-slow";
    address private _asset;
    address public EVC;
    mapping(address => uint256) public balanceOf;
    uint256 private immutable BURN;

    constructor(address asset_, uint256 burn_) {
        _asset = asset_;
        BURN = burn_;
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

    function debtOf(address) external view returns (uint256) {
        uint256 start = gasleft();
        while (start - gasleft() < BURN) {
            assembly {
                mstore(0x00, keccak256(0x00, 0x20))
            }
        }
        revert("no debtOf on this vault");
    }
}

/// @notice A core-eVault shape whose `debtOf` consumes every unit of gas it is forwarded instead of answering.
/// @dev The failure `_safeDebt` must NOT read as "no debt". A vault can reach this by being upgraded, by an
///      unbounded internal loop, or by being hostile — the instance set is governed, but a vault's code is not
///      frozen by being registered. `balanceOf` is settable so the test can build the topology that actually
///      over-reports: a controller vault holding only debt, whose siblings hold the collateral.
contract MockDebtGasBombVault {
    string public name = "EVK Vault eUSDC-bomb";
    address private _asset;
    address public EVC;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = asset_;
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

    function debtOf(address) external pure returns (uint256) {
        // Hash one word forever: grows no memory, so it spends the stipend steadily rather than
        // out-of-gassing early on memory expansion.
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
        return 0; // unreachable; present only to silence solc 6321 on every build
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

/// @notice EVC-shaped mock that burns its entire stipend and then reverts. Exercises the gas-burn half of the
///         hazard only: it OOGs on the 3MB memory expansion before `revert(0, …)` can execute, so the caller
///         copies ZERO bytes. Returndata-copy bounding is covered by {MockReturndataBombEVC} instead.
contract MockHostileEVC {
    // Always reverts, so the declared return value is never produced.
    fallback(bytes calldata) external returns (bytes memory) {
        assembly {
            // Burn whatever stipend we were given, then attempt a 3MB revert payload.
            for {} 1 {} { if lt(gas(), 5000) { revert(0, 3000000) } }
        }
        revert("unreachable");
    }
}

/// @notice EVC-shaped mock that SUCCEEDS while returning a huge payload. This is the real returndata-copy hazard:
///         a raw staticcall assigning `(bool, bytes memory)` always `returndatacopy`s the response, so the caller
///         pays quadratic memory-expansion cost on whatever the callee can afford to emit. A success-path
///         `return(0, N)` costs the callee only its own memory expansion, so it maximises what actually reaches
///         the caller — unlike a revert bomb, which OOGs first. Bounded solely by {PROBE_GAS}.
contract MockReturndataBombEVC {
    uint256 private immutable PAD;

    constructor(uint256 pad_) {
        PAD = pad_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 pad = PAD;
        assembly {
            return(0, pad)
        }
    }
}

/// @notice Vault whose own `EVC()` succeeds with a huge payload, so the FIRST probe carries the bomb. Emits it
///         straight from memory (not storage) — a storage-backed payload would cost the test ~20M gas to set up
///         and measure nothing extra.
///
///         `evc_` sets the payload's FIRST word. With `address(0)` the read is undecodable-as-nonzero and
///         `_supplyKind` short-circuits, so only this probe bombs. With a real address the payload is a *valid*
///         address encoding with trailing junk — which correctly passes `_safeEvc` — so the second probe fires
///         too and both can bomb in one read. That is the true worst case.
contract MockBombEvcVault {
    address private _asset;
    uint256 private immutable PAD;
    address private immutable EVC_ADDR;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _debt;

    constructor(address asset_, uint256 pad_, address evc_) {
        _asset = asset_;
        PAD = pad_;
        EVC_ADDR = evc_;
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

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 pad = PAD;
        address evc = EVC_ADDR;
        assembly {
            mstore(0, evc)
            return(0, pad)
        }
    }
}

/// @notice Vault whose `debtOf` SUCCEEDS but returns empty returndata — the ERC-1967 shape (implementation slot
///         points at a code-less address, so the `delegatecall` succeeds and returns nothing) and the EVK
///         dispatcher-with-unset-module shape. `abi.decode(…, (uint256))` on that reverts in the CALLING frame,
///         which `try`/`catch` does not intercept. `asset`/`balanceOf`/`convertToAssets` are real; every other
///         selector falls through to the empty fallback.
contract MockEmptyDebtOfVault {
    address private _asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = asset_;
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

    fallback() external {}
}

/// @notice Plain supply-only vault with no `debtOf` at all, so the call genuinely reverts. Used as the sibling
///         collateral vault in the cross-vault unoffset-collateral test.
contract MockSupplyOnlyVault {
    address private _asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = asset_;
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
}

/// @title EulerVaultsMetaBalanceAdapter unit tests (no fork)
/// @notice Mirrors the MorphoVaultsMeta unit suite — same MetaBalanceAdapter base + ERC4626 convertToAssets shape —
///         plus Euler-specific asserts (protocolId = euler-vaults; positionKind Supplied / Collateral when EVC-enabled /
///         Borrowed for the debt leg).
contract EulerVaultsMetaBalanceAdapterTest is Test {
    /// @dev Payload size for a bomb served through the VAULT-side `EVC()` probe, which is bounded by
    ///      `StaticCallLib.PROBE_GAS` (100_000) rather than this file's `PROBE_GAS` (150_000).
    ///
    ///      The size is load-bearing and must stay AFFORDABLE to the callee. `return(0, N)` costs the callee
    ///      `3w + w^2/512` for `w = N/32`: 256_000 bytes costs ~149k and simply MemoryOOGs under a 100k stipend,
    ///      so the callee returns nothing, the probe fails for the wrong reason, and the test passes while
    ///      exercising none of the hazard it names. (That is exactly what happened when the stipend moved from
    ///      150_000 to 100_000 — the payload had been sized for the old value.) 160_000 bytes costs ~64k, which
    ///      the callee can afford, so a genuinely large reply reaches the probe.
    uint256 internal constant VAULT_BOMB_BYTES = 160_000;

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

        adapter = new EulerVaultsMetaBalanceAdapter(address(nav));
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
    ///      Solidity's `extcodesize` precheck, BEFORE the call, which `try`/`catch` cannot intercept. Note it is
    ///      the switch to a low-level `staticcall` that fixes this — such a call returns `(true, "")`, which the
    ///      returndata-length check rejects — not the explicit `code.length` guard, which is only a short-circuit.
    ///      So this test stays green if that guard alone is removed; it goes red if the `try`/`catch` returns.
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

    /// @dev The case that makes {StaticCallLib.safeAddrStrict} load-bearing here rather than merely tidy: a dirty
    ///      word whose LOW 160 bits are a real, working EVC that would classify this vault as collateral.
    ///
    ///      The sibling `bytes32`-shaped test above does NOT discriminate — its low bits are `type(uint160).max`,
    ///      a code-less address, so masking and rejecting both fall through to `Supplied` by different routes.
    ///      Swap `safeAddrStrict` for `safeAddr` in `_safeEvc` and only THIS test goes red: masking hands
    ///      `_supplyKind` an EVC the vault never validly named, and the supply is classified `Collateral` off an
    ///      attacker-chosen contract. Rejecting keeps the "cannot classify" sentinel meaningful.
    function test_supplyKind_dirtyEvcWordOverRealEvc_degradesToSupplied() public {
        MockEVC evc = new MockEVC();
        // Low 160 bits = the real EVC; bit 200 set, so the word is not a valid `address` encoding.
        uint256 dirty = uint256(uint160(address(evc))) | (uint256(1) << 200);
        MockRawEvcVault v = new MockRawEvcVault(address(usdc), abi.encode(dirty));
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);

        // That EVC really would report this vault as enabled collateral, so a masking reader classifies it.
        address[] memory cols = new address[](1);
        cols[0] = address(v);
        evc.setCollaterals(alice, cols);

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

    /// @dev A hostile EVC that burns its whole stipend and then reverts. Covers the gas-burn half of the hazard.
    ///      Note this mock OOGs on its 3MB memory expansion before the `revert` executes, so the caller copies
    ///      nothing — returndata-copy bounding is covered separately by
    ///      test_supplyKind_returndataBomb_boundedAndFailsOpen. The assertion is pinned just above the measured
    ///      cost so a regression in {PROBE_GAS} actually trips it.
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
        assertLt(used, 300_000, "gas-burn cost bounded by the probe stipend");
    }

    /// @dev The returndata-copy hazard the {PROBE_GAS} docstring is actually about. A raw staticcall assigning
    ///      `(bool, bytes memory)` always `returndatacopy`s the response, so an EVC that SUCCEEDS while emitting a
    ///      huge payload makes the CALLER pay quadratic memory-expansion cost. A success-path `return(0, N)` is the
    ///      maximising shape — a revert bomb OOGs on its own expansion first and delivers nothing.
    ///
    ///      256 KB is roughly the largest payload a callee can afford inside a 150k stipend (memory cost is
    ///      `3w + w²/512`), so this is close to the worst case an attacker can actually reach. Asserts fail-open
    ///      behaviour AND that the copy stays bounded — an unbounded version of this read measured ~52.6M gas.
    function test_supplyKind_returndataBomb_boundedAndFailsOpen() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        core.setEVC(address(new MockReturndataBombEVC(256_000)));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        uint256 used = before - gasleft();

        assertEq(pos.length, 2, "returndata bomb cannot drop the legs");
        assertEq(pos[0].amount, 1_000_000, "supply amount intact");
        assertEq(pos[1].amount, 400_000, "debt leg not suppressed");
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        assertLt(used, 500_000, "returndata copy bounded by the probe stipend");
    }

    /// @dev A bomb on the FIRST probe (`EVC()` on the vault itself), not just the second. Both reads carry the
    ///      stipend; this pins that the vault-side one does too.
    function test_safeEvc_returndataBomb_boundedAndFailsOpen() public {
        // The vault's own EVC() returns a huge payload whose first word is zero, so it is also unusable.
        MockBombEvcVault v = new MockBombEvcVault(address(usdc), VAULT_BOMB_BYTES, address(0));
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(v))));
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        uint256 used = before - gasleft();

        assertEq(pos.length, 2, "vault-side bomb cannot drop the legs");
        assertEq(pos[0].amount, 1_000_000, "supply amount intact");
        assertEq(pos[1].amount, 400_000, "debt leg not suppressed");
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        // Measured 117,299 on this branch; 199,716 with `probeWord`'s fixed output window replaced by a
        // `(bool, bytes memory)` assignment. The ceiling sits between the two deliberately — a loose bound
        // would pass in BOTH cases and assert nothing.
        assertLt(used, 150_000, "vault-side returndata copy bounded too");
    }

    /// @dev The true worst case: BOTH probes bomb in a single read. A payload whose first word is a clean address
    ///      is a *valid* address encoding with trailing junk, so it correctly passes `_safeEvc` (extra returndata
    ///      is legal ABI) and the second probe then fires against an EVC that bombs as well.
    ///
    ///      The vault-side payload is {VAULT_BOMB_BYTES}, not 256 KB, because that probe is now bounded by
    ///      `StaticCallLib.PROBE_GAS` (100_000): at 256 KB the callee MemoryOOGs, `_safeEvc` yields address(0),
    ///      `_supplyKind` short-circuits, and the SECOND probe never fires — "both probes bomb" would bomb
    ///      neither. The EVC-side payload stays at 256 KB because `_isEnabledCollateral` still carries this
    ///      file's own 150_000 stipend.
    function test_bothProbesBomb_worstCase_stillBounded() public {
        address bombEvc = address(new MockReturndataBombEVC(256_000));
        MockBombEvcVault v = new MockBombEvcVault(address(usdc), VAULT_BOMB_BYTES, bombEvc);
        v.setBalance(alice, 1_000_000);
        v.setDebt(alice, 400_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(v))));
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        uint256 used = before - gasleft();

        assertEq(pos.length, 2, "double bomb cannot drop the legs");
        assertEq(pos[0].amount, 1_000_000, "supply amount intact");
        assertEq(pos[1].amount, 400_000, "debt leg not suppressed");
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        // Measured 958,612 here; an independent audit measured 926,673 for the same shape. Pinned just above so a
        // regression in PROBE_GAS trips it. Per-instance: the base fan-out gives each instance a fresh memory
        // frame via `try this.instancePositions(...)`, so this cost scales linearly, not quadratically.
        assertLt(
            // Measured 444,913 on this branch; 683,778 with the fixed output window replaced by a
            // `(bool, bytes memory)` assignment on the vault-side probe.
            used,
            550_000,
            "both probes bombing must stay bounded"
        );
    }

    /// @dev The membership scan compares FULL words, so a collateral entry whose high 96 bits are dirty never
    ///      matches even when its low 160 bits are the vault — strictly under-classifying, per the fail-open
    ///      contract, rather than reverting or trusting a malformed element.
    function test_supplyKind_collateralsDirtyElement_degradesToSupplied() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        // The single collateral entry carries the vault's address in its low 160 bits but a non-zero bit at 200,
        // so a masked comparison would match it and the full-word comparison must not.
        uint256 dirty = (uint256(1) << 200) | uint256(uint160(address(core)));
        core.setEVC(address(new MockRawEVC(abi.encode(uint256(0x20), uint256(1), dirty))));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev A well-formed list longer than {MAX_COLLATERALS} is scanned as a 32-entry PREFIX, not rejected. An
    ///      entry past the cap is missed, so this degrades to `Supplied` — the safe direction — while the work
    ///      stays bounded.
    function test_supplyKind_collateralsOverCap_beyondPrefix_degradesToSupplied() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        uint256 n = 40; // MAX_COLLATERALS is 32
        uint256[] memory els = new uint256[](n);
        els[n - 1] = uint256(uint160(address(core))); // at index 39, past the 32-entry prefix
        core.setEVC(address(new MockRawEVC(abi.encodePacked(abi.encode(uint256(0x20), n), abi.encodePacked(els)))));
        core.setBalance(alice, 1_000_000);
        core.setDebt(alice, 400_000);
        _assertFailOpen(address(core), 1_000_000, 400_000);
    }

    /// @dev The reason the over-cap list is prefix-scanned rather than discarded: if Euler ever raised
    ///      `SET_MAX_ELEMENTS` past 32, wholesale rejection would silently degrade EVERY classification. An entry
    ///      inside the prefix of an over-long list is still found.
    function test_supplyKind_collateralsOverCap_withinPrefix_stillCollateral() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eUSDC-2", address(usdc), 1e18);
        uint256 n = 40;
        uint256[] memory els = new uint256[](n);
        els[5] = uint256(uint160(address(core))); // inside the 32-entry prefix
        core.setEVC(address(new MockRawEVC(abi.encodePacked(abi.encode(uint256(0x20), n), abi.encodePacked(els)))));
        core.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1);
        assertTrue(pos[0].positionKind == PositionKind.Collateral, "prefix of an over-long list is still scanned");
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

    // ----- `debtOf` is fail-open too (same uncaught class as the EVC reads) -----

    /// @dev `debtOf` succeeding with undecodable returndata reverted `_instancePositions`, so the base fan-out
    ///      dropped the whole instance and a real supply leg silently vanished. Reverting `_safeDebt` to the
    ///      original `try`/`catch` turns this red (0 legs instead of 1).
    function test_safeDebt_emptyReturndata_supplyLegSurvives() public {
        MockEmptyDebtOfVault v = new MockEmptyDebtOfVault(address(usdc));
        v.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(v))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 1, "supply leg survives an undecodable debtOf");
        assertEq(pos[0].amount, 1_000_000, "supply amount intact");
        assertFalse(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
    }

    /// @dev The reason this is worse than a classification failure. Euler's core EVK model puts the debt in a
    ///      controller vault and the collateral in OTHER vaults. If the controller's `debtOf` decode-fails, the
    ///      fan-out drops the controller entirely while the sibling collateral vault still reports — unoffset
    ///      collateral, which OVER-reports NAV (the PR #164 hazard). With `_safeDebt` the controller keeps
    ///      reporting; before it, the credit leg stood alone.
    function test_safeDebt_crossVault_noUnoffsetCollateral() public {
        MockSupplyOnlyVault coll = new MockSupplyOnlyVault(address(usdc));
        coll.setBalance(alice, 1_000_000); // collateral in vault A

        MockEmptyDebtOfVault controller = new MockEmptyDebtOfVault(address(usdc));
        controller.setBalance(alice, 250_000); // supply in the controller vault B

        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(coll))));
        ins[1] = bytes32(uint256(uint160(address(controller))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 2, "both vaults report; the controller is not silently dropped");
        assertEq(pos[0].amount, 1_000_000);
        assertEq(pos[1].amount, 250_000, "controller leg survives its undecodable debtOf");
    }

    /// @dev Positive control: a real `debtOf` still produces the borrow leg, so the hardening did not disable the
    ///      read. Covered more broadly by test_borrowLeg_emittedAlongsideSupply; pinned here next to its guard.
    function test_safeDebt_realDebtStillReported() public {
        MockCoreEVault core = new MockCoreEVault("EVK Vault eWETH-2", address(weth), 1e18);
        core.setBalance(alice, 2e18);
        core.setDebt(alice, 5e17);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(core))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));

        assertEq(pos.length, 2);
        assertEq(pos[1].amount, 5e17, "real debtOf still read through _safeDebt");
        assertTrue(pos[1].isDebt);
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

    /// @dev Pins that THIS adapter routes its positionId through the shared guard. `positionLabels` is display-only
    ///      and must never revert, and must never label a coordinate the adapter never emitted; both were reachable
    ///      before (`abi.decode(pid, (address))` reverts on dirty upper bits, and a `< 32` guard labels a foreign
    ///      multi-word coordinate from its first word). The accept window itself is pinned exhaustively in
    ///      `test/balances/MetaBalanceAdapterPidGuards.t.sol` — this case exists because that harness cannot catch
    ///      an adapter re-inlining the old idiom, which is a one-line regression.
    ///
    ///      The clean-coordinate assertion keeps the rejections load-bearing: a shape-valid but unknown coordinate
    ///      still resolves to the category-only label, so a view that rejected everything would fail here.
    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        address coord = address(0xBEEF);

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one clean word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(coord)) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }

    // ---------------------------------------------------------------------------------------------------------
    // debtOf: fail-open on a revert, fail-CLOSED on an exhausted stipend
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A `debtOf` that burns its stipend must make the read FAIL, not report a supply leg with the debt
    ///         silently missing.
    /// @dev The over-report this closes. Reading a starved `debtOf` as 0 leaves the supply leg standing alone,
    ///      so the position is counted as pure credit and NAV rises by the whole borrow. The failure has to
    ///      leave the adapter: the base fan-out classifies it by gas consumed and re-raises
    ///      `InstanceGasExhausted`, which is why the stipend is frame-derived rather than a fixed 100_000 — a
    ///      fixed ceiling is spent inside the instance's much larger budget and reads as a cheap revert, so the
    ///      instance would be dropped silently instead.
    function test_debtOf_gasBomb_revertsInsteadOfDroppingTheDebtLeg() public {
        MockDebtGasBombVault bomb = new MockDebtGasBombVault(address(usdc));
        bomb.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(bomb))));

        // Selector only: the budget/consumed operands are whatever the enclosing frame happened to hold, so
        // pinning them would pin the test runner's budget rather than the behaviour. The frame IS capped
        // though — uncapped, this burns the whole configured `gas_limit`, which is 1 GiB by default and 16 GiB
        // under FOUNDRY_PROFILE=slow. The verdict is invariant across 60,000 to 550,000,000, so the cap costs
        // the test nothing and saves ~16x the runtime whenever the suite is run under that profile.
        vm.expectPartialRevert(INAVCalculator.InstanceGasExhausted.selector);
        this.callPositions{gas: 30_000_000}(ins);
    }

    /// @notice The controller topology: a vault holding ONLY debt must not answer "no legs" when its `debtOf`
    ///         was starved.
    /// @dev The reason a per-vault view of this is not enough. On a controller `balanceOf == 0`, so a starved
    ///      `debtOf` produces an instance with no legs at all — indistinguishable from an account with no
    ///      position there — while the sibling vaults holding the collateral report it in full. Nothing inside
    ///      this instance can offset that, so refusing to answer is the only safe outcome.
    function test_debtOf_gasBomb_controllerWithNoSupply_stillReverts() public {
        MockDebtGasBombVault controller = new MockDebtGasBombVault(address(usdc));
        // No balance: the account's collateral sits in other vaults, as it does in Euler's core model.

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(controller))));

        vm.expectPartialRevert(INAVCalculator.InstanceGasExhausted.selector);
        this.callPositions{gas: 30_000_000}(ins);
    }

    /// @notice A vault whose `debtOf` genuinely REVERTS still fails open — the EulerEarn case, unchanged.
    /// @dev The distinction the whole change rests on. An aggregator that does not implement `debtOf` has
    ///      answered, and reading 0 is correct; both configured mainnet instances are exactly this. If this
    ///      degrades to a revert the change has broken the live configuration rather than hardened it.
    function test_debtOf_genuineRevert_stillFailsOpen() public {
        // `MockEVault` (vaultA) implements no `debtOf` at all, so the call reverts on a missing selector.
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));

        vaultA.setBalance(alice, 1_000_000);
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "an aggregator with no debtOf still reports its supply leg");
        assertTrue(pos[0].positionKind == PositionKind.Supplied || pos[0].positionKind == PositionKind.Collateral);
        assertFalse(pos[0].isDebt, "and it is a credit leg, not a debt one");
    }

    /// @dev External wrapper so `vm.expectRevert` applies to the adapter call rather than to this test frame.
    function callPositions(bytes32[] memory ins) external view returns (INAVCalculator.PositionBalance[] memory) {
        return adapter.getAdapterPositionsForInstances(alice, ins, address(0));
    }

    /// @notice A burn inside the band the frame-vs-stipend regression reopens must keep its leg.
    /// @dev The only assertion in this suite that fails if `StaticCallLib.probeWordMetered` goes back to
    ///      classifying against the forwarded stipend instead of the frame — the one-token regression this
    ///      adapter's guard was corrected for. Everything else here survives it: the gas-bomb pair cannot see it
    ///      because an infinite bomb lands at ~0.984 of the frame, past both thresholds; the cheap-revert test
    ///      never approaches either; and the bracket below cannot, because the regression shifts the flip frame
    ///      by only ~1.6% and both of its budgets straddle that too.
    ///
    ///      The burn is chosen to sit INSIDE the band the regression reopens. Classifying against the stipend
    ///      tests `7/8 * (63/64) * frame = 0.861 * frame` while `MetaBalanceAdapter` raises at `0.875 * frame`;
    ///      a callee consuming between the two trips the inner guard, and the base then reads the resulting
    ///      revert as an ordinary one and drops the whole instance silently. At frame 8,000,000 that band is
    ///      ~6,666,000-6,769,000 of burn and ~103,000 wide. 6,700,000 is inside it: this returns one leg with
    ///      the fix and ZERO legs without, which is both the over-report the guard exists to close and a fresh
    ///      silent loss of a leg that would otherwise have survived.
    ///
    ///      **What it observes, precisely — the name matters here.** WITH the fix no raise happens at all: at
    ///      frame 8,000,000 the probe's budget is ~7,734,000 and the threshold ~6,767,000, so a 6,700,000 burn
    ///      is correctly read as a genuine revert and `_safeDebt` returns 0. What this pins is the ABSENCE of a
    ///      spurious raise in that range. It is not evidence that a real raise propagates — the two gas-bomb
    ///      tests above cover that, by asserting `InstanceGasExhausted` actually arrives. Anyone later moving
    ///      the inner threshold UP will see this stay green and must not read it as propagation coverage.
    function test_debtOf_burnInsideTheReopenedBand_keepsItsLeg() public {
        MockExpensiveRevertVault slow = new MockExpensiveRevertVault(address(usdc), 6_700_000);
        slow.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(slow))));

        INAVCalculator.PositionBalance[] memory pos = this.callPositions{gas: 8_000_000}(ins);

        assertEq(pos.length, 1, "a burn in this range is a genuine revert, and its leg must survive");
        assertFalse(pos[0].isDebt, "and the surviving leg is the credit one");
    }

    /// @notice A `debtOf` that reverts only after real work brackets the classifier from BOTH sides.
    /// @dev Two assertions straddling a measured boundary, and the VALUES are the test — both were re-derived
    ///      after the classification threshold changed, because a bracket that no longer brackets passes
    ///      silently.
    ///
    ///      The far side is the property that matters in production: an expensive but GENUINE revert — a
    ///      dispatcher hop, or a vault made dearer by an upgrade — must still yield the supply leg. That is the
    ///      path the live EulerEarn configuration takes.
    ///
    ///      The near side pins that the same vault fails CLOSED once the frame is too small to tell its revert
    ///      from starvation. That false positive is documented in {EulerVaultsMetaBalanceAdapter._safeDebt}; it
    ///      is correct given the evidence available, and pinning it is what makes the pair a bracket rather than
    ///      two independent assertions.
    ///
    ///      **Why these numbers.** With a 5,000,000-gas burn the flip sits at a frame of ~5,915,000. To
    ///      re-derive it at a different burn, use `flip ~= (8/7 * burn + 18,600) * (64/63)^2`: the `8/7` is the
    ///      `7/8` threshold inverted, the ~18,600 is what back-solving the measured flip gives for everything
    ///      fixed ahead of the burn — the prologue (`asset()`, the registry fetch, `convertToAssets`,
    ///      `balanceOf`) measured at ~19,500 on its own, net of small call-frame effects — and the two
    ///      `64/63` factors are the EIP-150 reserves
    ///      withheld at `getAdapterPositionsForInstances` and again at `try this.instancePositions{gas: ...}`.
    ///      Do NOT model the gap as a fixed additive constant — those reserves SCALE with the frame, so a
    ///      constant fits only near burn = 5,000,000 and diverges in opposite directions either side of it
    ///      (~150,000 low at burn 1,000,000, ~177,000 high at burn 10,000,000). Getting that wrong de-calibrates
    ///      the sensitivity property below, which is the only reason these two numbers are what they are.
    ///      5,600,000 is ~5% below
    ///      it and 6,300,000 ~6% above: far enough that solc or forge gas drift cannot cross either, close
    ///      enough that a change to the threshold does. That second half is not automatic and was got wrong
    ///      once — an earlier pair of 5,400,000/8,000,000 straddled the flip and still passed, but a
    ///      `SLACK_DIVISOR` move from 8 to 4 shifts the flip to ~6,870,000 and BOTH of those assertions survive
    ///      it. 6,300,000 lies below that, so the same change turns this red. A bracket has to sit inside the
    ///      interval the regression would move the boundary across, not merely on both sides of it today.
    ///
    ///      **Which mutation each side catches — measured, and NOT what an earlier revision of this docstring
    ///      claimed.** It asserted that a return to a fixed `StaticCallLib.PROBE_GAS` ceiling classifies this
    ///      vault as starved and destroys the far side with `0 != 1`. That reasoning silently assumed
    ///      classification against the forwarded STIPEND; against the frame, 100_000 spent inside a multi-megagas
    ///      frame is nowhere near `7/8`, so a fixed ceiling makes the read fail OPEN, not closed. The claim
    ///      described the code as it stood before the frame-vs-stipend correction, and survived a review round.
    ///
    ///      What the four mutations actually do:
    ///
    ///      | mutation | red | signature |
    ///      |---|---|---|
    ///      | discard the flag (plain `safeUint`) | both gas bombs, this test's NEAR side | did not revert |
    ///      | fixed `PROBE_GAS` ceiling, named error kept | the same three | did not revert — INDISTINGUISHABLE |
    ///      | classify against the forwarded stipend | `burnInsideTheReopenedBand` alone | `0 != 1` |
    ///      | `starved = !ok` | `genuineRevert`, this test's FAR side, `burnInsideTheReopenedBand` | `0 != 1` |
    ///
    ///      So the two halves of this bracket pin DIFFERENT properties, which is the reason it is one test. The
    ///      near side pins propagation, alongside the gas bombs. The far side pins fail-open on a genuine revert,
    ///      alongside `genuineRevert_stillFailsOpen` — and that pair is what would go red if a change broke every
    ///      EulerEarn instance on mainnet, since a live aggregator's `debtOf` reverts cheaply and must keep
    ///      reading 0. A fixed ceiling leaves both of them green, which is precisely why attributing that harm
    ///      to it was wrong.
    function test_debtOf_expensiveButGenuineRevert_bracketsTheClassifier() public {
        MockExpensiveRevertVault slow = new MockExpensiveRevertVault(address(usdc), 5_000_000);
        slow.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(slow))));

        // Far side of the boundary (~5,917,000): the revert is genuine and is read as one.
        INAVCalculator.PositionBalance[] memory pos = this.callPositions{gas: 6_300_000}(ins);
        assertEq(pos.length, 1, "an expensive but genuine revert must still yield the supply leg");
        assertFalse(pos[0].isDebt, "and it is the credit leg");

        // Near side: too little frame to tell this revert from starvation, so it fails closed.
        vm.expectPartialRevert(INAVCalculator.InstanceGasExhausted.selector);
        this.callPositions{gas: 5_600_000}(ins);
    }
}
