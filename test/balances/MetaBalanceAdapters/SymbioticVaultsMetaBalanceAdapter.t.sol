// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal ERC4626-shaped Symbiotic vault mock: configurable share→asset rate and an on-chain name.
/// @dev Implements `previewRedeem` because it is MANDATORY in ERC-4626 and is the accessor the adapter
///      actually values through ({ERC4626RedeemLib.redeemValue}); a mock lacking it would silently
///      exercise the fallback instead of the real path.
contract MockSymbioticVault {
    string public name;
    address private _asset;
    uint256 private _rate; // assets per share, 1e18-scaled
    uint256 private _exitFeeBps;
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

    /// @notice Fee-aware preview — the accessor the adapter prefers.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        uint256 gross = (shares * _rate) / 1e18;
        return gross - ((gross * _exitFeeBps) / 10_000);
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setExitFeeBps(uint256 bps) external {
        _exitFeeBps = bps;
    }
}

/// @notice A Symbiotic CORE vault: epoch/stake accounting, NO ERC-4626 share surface.
/// @dev Models what the adapter must NOT mis-value. `activeBalanceOf` is the core vault's accounting
///      unit; `balanceOf`/`previewRedeem` do not exist.
contract MockSymbioticCoreVault {
    address public collateral;
    uint256 public epochDuration = 7 days;
    mapping(address => uint256) public activeBalanceOf;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    function setActiveBalance(address account, uint256 amount) external {
        activeBalanceOf[account] = amount;
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

/// @title SymbioticVaultsMetaBalanceAdapter unit tests (no fork)
contract SymbioticVaultsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    SymbioticVaultsMetaBalanceAdapter adapter;

    MockToken usdc;
    MockToken weth;
    MockSymbioticVault vaultA; // USDC, 1:1
    MockSymbioticVault vaultB; // WETH, 2:1

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        vaultA = new MockSymbioticVault("KPK USDC LiquidLane", address(usdc), 1e18);
        vaultB = new MockSymbioticVault("KPK ETH LiquidLane", address(weth), 2e18);

        adapter = new SymbioticVaultsMetaBalanceAdapter(address(nav));
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

    // ----- no-arg base methods return empty -----

    function test_noArgMethods_returnEmpty() public {
        vaultA.setBalance(alice, 1000);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        (address[] memory a, uint256[] memory amt, bool[] memory d) = adapter.getAdapterBalances(alice);
        assertEq(a.length, 0);
        assertEq(amt.length, 0);
        assertEq(d.length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    // ----- identity: the whole reason this is not a Morpho instance -----

    /// @dev The position must be stamped `symbiotic` / `symbiotic-vaults`, never `morpho`. Registering
    ///      these vaults on {MorphoVaultsMetaBalanceAdapter} would value them correctly but label them
    ///      wrongly, which is exactly what this separate contract exists to prevent.
    function test_identity_isSymbioticNotMorpho() public {
        vaultA.setBalance(alice, 1_000_000);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].protocolBrand, ProtocolIds.SYMBIOTIC, "brand == symbiotic");
        assertEq(pos[0].protocolId, ProtocolIds.SYMBIOTIC, "id == symbiotic");
        assertEq(pos[0].protocolSubId, ProtocolIds.SYMBIOTIC_VAULTS, "subId == symbiotic-vaults");
        assertTrue(pos[0].protocolBrand != ProtocolIds.MORPHO, "must not be morpho");
        assertTrue(pos[0].protocolSubId != ProtocolIds.MORPHO_VAULTS, "must not be morpho-vaults");
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Supplied), "single Supplied leg");
        assertFalse(pos[0].isLocked, "synchronous vault: not locked");
    }

    // ----- instance fan-out -----

    function test_positionsForInstances_aggregatesAcrossVaults() public {
        vaultA.setBalance(alice, 1_000_000); // 1.0 USDC at 1:1
        vaultB.setBalance(alice, 5e17); // 0.5 shares * 2 = 1.0 WETH

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "two positions");

        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1_000_000);
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].balanceAdapter, address(adapter), "balanceAdapter is always address(this)");
        assertEq(pos[0].positionId, abi.encode(address(vaultA)));

        assertEq(pos[1].balanceAsset.asset, address(weth));
        assertEq(pos[1].amount, 1e18);
        assertEq(pos[1].positionId, abi.encode(address(vaultB)));
    }

    /// @dev An EIP-4626 §4.3 exit fee must reduce the reported amount — the adapter values through the
    ///      fee-aware accessor, so it can never report the gross (upward) figure.
    function test_exitFee_reducesReportedAmount() public {
        vaultA.setBalance(alice, 1_000_000);
        vaultA.setExitFeeBps(100); // 1%
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].amount, 990_000, "net of the 1% exit fee, not the gross 1_000_000");
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
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_unregisteredAsset_skipped_othersSurvive() public {
        MockToken dai = new MockToken("DAI", 18); // not registered on NAV
        MockSymbioticVault vaultC = new MockSymbioticVault("Unregistered DAI", address(dai), 1e18);
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

    /// @dev A Symbiotic CORE vault has no ERC-4626 surface. It must be ISOLATED (contributing nothing)
    ///      rather than reverting the whole fan-out or inventing a number — an under-report, never an
    ///      over-report. Documents the adapter's stated scope boundary as executable behaviour.
    function test_coreVaultInstance_isIsolatedNotMisvalued() public {
        MockSymbioticCoreVault core = new MockSymbioticCoreVault(address(usdc));
        core.setActiveBalance(alice, 500_000);
        vaultA.setBalance(alice, 1_000_000);

        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(core))));
        ins[1] = bytes32(uint256(uint160(address(vaultA))));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "core vault contributes nothing; the 4626 vault still reports");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1_000_000, "and its value is untouched by the core vault's presence");
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

    function test_positionLabels_vaultName() public view {
        string[] memory labels = adapter.positionLabels(abi.encode(address(vaultA)));
        assertGt(labels.length, 0, "labelled");
        assertEq(labels[0], "Vault", "category leaf");
    }

    /// @dev Pins that THIS adapter routes its positionId through the shared guard. `positionLabels` is
    ///      display-only and must never revert, and must never label a coordinate the adapter never
    ///      emitted. The accept window itself is pinned exhaustively in
    ///      `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case exists because that harness
    ///      cannot catch an adapter re-inlining the old `abi.decode(pid, (address))` idiom.
    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        address coord = address(0xBEEF);

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one clean word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(coord)) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }
}
