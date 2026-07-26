// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal StakeWise V3 vault mock: settable shares/osToken positions, 1:1 share→asset, on-chain name.
/// @dev An empty `name_` models the non-ERC20 StakeWise vault variants, whose `name()` reverts — {LabelLib} treats a
///      revert and an empty string identically, so `_revertOnName` covers the other half of that behaviour.
contract MockStakeWiseVault {
    string private _name;
    bool private _revertOnName;
    uint256 private _rate; // assets per share, 1e18-scaled
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _osToken;

    constructor(string memory name_, uint256 rate_) {
        _name = name_;
        _rate = rate_;
    }

    /// @notice Raised by `name()` on the mock's non-ERC20 vault setting.
    error NameNotSupported();

    /// @notice ERC20 `name()` — reverts when `revertOnName` is set, mirroring the non-ERC20 vault variants.
    function name() external view returns (string memory) {
        if (_revertOnName) revert NameNotSupported();
        return _name;
    }

    function setRevertOnName(bool v) external {
        _revertOnName = v;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _rate) / 1e18;
    }

    function getShares(address account) external view returns (uint256) {
        return _shares[account];
    }

    function osTokenPositions(address account) external view returns (uint256) {
        return _osToken[account];
    }

    function setShares(address account, uint256 v) external {
        _shares[account] = v;
    }

    function setOsToken(address account, uint256 v) external {
        _osToken[account] = v;
    }
}

contract MockUnderlying {
    string public symbol = "ETH";
    uint8 public decimals = 18;
}

/// @title StakeWiseV3VaultsMetaBalanceAdapter unit tests (no fork)
contract StakeWiseV3VaultsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    StakeWiseV3VaultsMetaBalanceAdapter meta;
    MockUnderlying underlying;
    MockStakeWiseVault vaultA; // Genesis
    MockStakeWiseVault vaultB; // Meta
    MockStakeWiseVault osTokenController; // stands in for the OsTokenVaultController (has convertToAssets)

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        underlying = new MockUnderlying();
        nav.registerAsset(address(underlying), 18, "ETH");

        vaultA = new MockStakeWiseVault("Genesis Vault", 2e18); // 1 share = 2 underlying
        vaultB = new MockStakeWiseVault("Meta Vault", 1e18);

        // alice: vaultA staking 5 shares (=10), osToken 1 share (=2 debt); vaultB staking 3 (=3), no debt.
        vaultA.setShares(alice, 5e18);
        vaultA.setOsToken(alice, 1e18);
        vaultB.setShares(alice, 3e18);

        // OsTokenVaultController converts osToken debt shares → underlying at its own rate (2e18 here): alice's
        // 1 osToken share → 2 underlying debt, matching the comment above.
        osTokenController = new MockStakeWiseVault("OsTokenVaultController", 2e18);
        meta = new StakeWiseV3VaultsMetaBalanceAdapter(
            address(underlying), address(osTokenController), "StakeWise V3", address(nav)
        );
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_fanOut_legsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // vaultA: Staking(10) + Borrow(2); vaultB: Staking(3) -> 3 legs total
        assertEq(p.length, 3);

        // vaultA Staking
        assertEq(p[0].balanceAsset.asset, address(underlying));
        assertEq(p[0].amount, 10e18);
        assertFalse(p[0].isDebt);
        assertEq(p[0].balanceAdapter, address(meta));
        assertEq(p[0].positionId, abi.encode(address(vaultA)));

        // vaultA Borrow
        assertEq(p[1].amount, 2e18);
        assertTrue(p[1].isDebt);

        // vaultB Staking only
        assertEq(p[2].amount, 3e18);
        assertFalse(p[2].isDebt);
        assertEq(p[2].positionId, abi.encode(address(vaultB)));
    }

    function test_assetFilter_match_and_miss() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        // Filter on the underlying -> both legs of vaultA.
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(underlying)).length, 2);
        // Filter on a different asset -> empty.
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(0xdead)).length, 0);
    }

    function test_unregisteredUnderlying_skipped() public {
        nav.unregisterAssetHelper(address(underlying));
        assertEq(meta.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_noPosition_empty() public view {
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vaultB))));
        assertEq(meta.getAdapterPositionsForInstances(address(0xB0B), ins, address(0)).length, 0);
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 1, "bad vault isolated, vaultB staking leg returned");
        assertEq(p[0].amount, 3e18);
    }

    // --- positionLabels ---------------------------------------------------------------------------------------

    /// @notice Two ERC20-variant vaults produce different final label elements — the property the leaf exists for.
    function test_positionLabels_distinctPerNamedVault() public view {
        string[] memory a = meta.positionLabels(abi.encode(address(vaultA)));
        string[] memory b = meta.positionLabels(abi.encode(address(vaultB)));

        assertEq(a.length, 2);
        assertEq(a[0], "Vault");
        assertEq(a[1], "Genesis Vault");

        assertEq(b.length, 2);
        assertEq(b[0], "Vault");
        assertEq(b[1], "Meta Vault");

        assertTrue(
            keccak256(bytes(a[a.length - 1])) != keccak256(bytes(b[b.length - 1])),
            "distinct instances must produce distinct final label elements"
        );
    }

    /// @notice A vault whose `name()` reverts (every non-ERC20 StakeWise variant) falls back to
    ///         `"<underlying symbol> <vault address>"` — never a blank leaf.
    function test_positionLabels_revertingName_fallsBackToSymbolAndAddress() public {
        vaultA.setRevertOnName(true);
        string[] memory l = meta.positionLabels(abi.encode(address(vaultA)));
        assertEq(l.length, 2, "leaf is present even without an on-chain name");
        assertEq(l[0], "Vault");
        assertEq(l[1], string.concat("ETH ", address(vaultA).toHexString()));
    }

    /// @notice An empty `name()` is treated exactly like a reverting one.
    function test_positionLabels_emptyName_fallsBackToSymbolAndAddress() public {
        MockStakeWiseVault unnamed = new MockStakeWiseVault("", 1e18);
        string[] memory l = meta.positionLabels(abi.encode(address(unnamed)));
        assertEq(l.length, 2);
        assertEq(l[1], string.concat("ETH ", address(unnamed).toHexString()));
    }

    /// @notice Two *unnamed* vaults still produce different final label elements — the fallback carries the
    ///         per-instance coordinate, so the blank-breadcrumb collision cannot reappear.
    function test_positionLabels_distinctForUnnamedVaults() public {
        vaultA.setRevertOnName(true);
        vaultB.setRevertOnName(true);
        string[] memory a = meta.positionLabels(abi.encode(address(vaultA)));
        string[] memory b = meta.positionLabels(abi.encode(address(vaultB)));
        assertEq(a.length, 2);
        assertEq(b.length, 2);
        assertTrue(
            keccak256(bytes(a[a.length - 1])) != keccak256(bytes(b[b.length - 1])),
            "distinct instances must produce distinct final label elements"
        );
    }

    /// @notice With the underlying unregistered there is no symbol to prefix, so the leaf is the bare address.
    function test_positionLabels_unregisteredUnderlying_addressOnly() public {
        vaultA.setRevertOnName(true);
        nav.unregisterAssetHelper(address(underlying));
        string[] memory l = meta.positionLabels(abi.encode(address(vaultA)));
        assertEq(l.length, 2);
        assertEq(l[1], address(vaultA).toHexString(), "symbol prefix dropped, address retained");
    }

    /// @notice A positionId pointing at a code-less address must not revert this display-only view.
    function test_positionLabels_noCode_failsOpen() public view {
        string[] memory l = meta.positionLabels(abi.encode(address(0xdead)));
        assertEq(l.length, 2);
        assertEq(l[0], "Vault");
        assertEq(l[1], string.concat("ETH ", address(0xdead).toHexString()));
    }

    /// @notice A short/malformed positionId yields no labels rather than reverting.
    function test_positionLabels_shortPositionId_empty() public view {
        assertEq(meta.positionLabels(hex"1234").length, 0);
        assertEq(meta.positionLabels("").length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2); // one per instance
        assertEq(a[0], address(underlying));
        assertEq(a[1], address(underlying));
    }
}
