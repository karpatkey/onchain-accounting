// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/protocols/EulerVaultsMeta.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}

/// @title EulerVaultsMetaBalanceAdapter unit tests (no fork)
/// @notice Mirrors the MorphoVaultsMeta unit suite — same MetaBalanceAdapter base + ERC4626 convertToAssets shape —
///         plus Euler-specific identity asserts (protocolId = euler-vaults, positionKind = Supplied).
contract EulerVaultsMetaBalanceAdapterTest is Test {
    using Strings for address;

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
        assertEq(pos[0].protocolId, ProtocolIds.EULER_VAULTS);
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

    function test_describePosition_returnsVaultName() public view {
        assertEq(adapter.describePosition(abi.encode(address(vaultB))), "KPK ETH Yield Term");
        assertEq(adapter.describePosition(abi.encode(address(vaultA))), "KPK RWA USDC");
    }
}
