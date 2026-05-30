// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MorphoVaultsMetaBalanceOracle} from "src/balances/protocols/MorphoVaultsMeta.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Minimal ERC4626-shaped vault mock with a configurable share→asset rate and an on-chain name.
contract MockMetaVault {
    using Strings for uint256;

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

/// @title MorphoVaultsMetaBalanceOracle unit tests (no fork)
contract MorphoVaultsMetaBalanceOracleTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MorphoVaultsMetaBalanceOracle oracle;

    MockToken usdc;
    MockToken weth;
    MockMetaVault vaultA; // USDC, 1:1
    MockMetaVault vaultB; // WETH, 2:1

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        vaultA = new MockMetaVault("Steakhouse USDC", address(usdc), 1e18);
        vaultB = new MockMetaVault("kpk ETH Prime", address(weth), 2e18);

        oracle = new MorphoVaultsMetaBalanceOracle("Morpho", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
    }

    // ----- ERC165 -----

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    // ----- no-arg base methods return empty -----

    function test_noArgMethods_returnEmpty() public {
        vaultA.setBalance(alice, 1000);
        assertEq(oracle.getOraclePositions(alice, address(0)).length, 0);
        (address[] memory a, uint256[] memory amt, bool[] memory d) = oracle.getOracleBalances(alice);
        assertEq(a.length, 0);
        assertEq(amt.length, 0);
        assertEq(d.length, 0);
        (uint256 bal, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(bal, 0);
        assertFalse(isDebt);
        assertEq(oracle.underlyingAssetsSupported().length, 0);
    }

    // ----- instance fan-out -----

    function test_positionsForInstances_aggregatesAcrossVaults() public {
        vaultA.setBalance(alice, 1_000_000); // 1.0 USDC at 1:1
        vaultB.setBalance(alice, 5e17); // 0.5 shares * 2 = 1.0 WETH

        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "two positions");

        // vaultA position
        assertEq(pos[0].underlyingAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1_000_000);
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].balanceOracle, address(oracle));
        assertEq(pos[0].protocol, "Morpho");
        assertEq(pos[0].positionId, address(vaultA).toHexString());
        assertEq(
            pos[0].positionDetail,
            "{\"protocol\":\"Morpho\",\"product\":\"Vault\",\"name\":\"Steakhouse USDC\",\"type\":\"Supply\"}"
        );

        // vaultB position (rate applied)
        assertEq(pos[1].underlyingAsset.asset, address(weth));
        assertEq(pos[1].amount, 1e18);
        assertEq(pos[1].positionId, address(vaultB).toHexString());
    }

    function test_assetFilter_returnsOnlyMatchingVault() public {
        vaultA.setBalance(alice, 1_000_000);
        vaultB.setBalance(alice, 1e18);

        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(usdc));
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, address(usdc));
    }

    function test_zeroBalance_skipped() public {
        vaultA.setBalance(alice, 1_000_000);
        // vaultB balance left at 0
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, address(usdc));
    }

    function test_unregisteredAsset_skipped_othersSurvive() public {
        MockToken dai = new MockToken("DAI", 18); // not registered on NAV
        MockMetaVault vaultC = new MockMetaVault("Unregistered DAI", address(dai), 1e18);
        vaultA.setBalance(alice, 1_000_000);
        vaultC.setBalance(alice, 5_000);

        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultC))));

        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "unregistered vault skipped, registered one survives");
        assertEq(pos[0].underlyingAsset.asset, address(usdc));
    }

    function test_badInstance_isolated() public {
        vaultA.setBalance(alice, 1_000_000);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // EOA / no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(vaultA))));

        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 1, "bad instance isolated, good one returned");
        assertEq(pos[0].underlyingAsset.asset, address(usdc));
    }

    function test_emptyInstances_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, new bytes32[](0), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = oracle.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }
}
