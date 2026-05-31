// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {StakeWiseV3VaultsMetaBalanceAdapter} from "src/balances/protocols/StakeWiseV3VaultsMeta.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal StakeWise V3 vault mock: settable shares/osToken positions, 1:1 share→asset, on-chain name.
contract MockStakeWiseVault {
    string public name;
    uint256 private _rate; // assets per share, 1e18-scaled
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _osToken;

    constructor(string memory name_, uint256 rate_) {
        name = name_;
        _rate = rate_;
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

        meta = new StakeWiseV3VaultsMetaBalanceAdapter(address(underlying), "StakeWise V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getOraclePositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_fanOut_legsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        // vaultA: Staking(10) + Borrow(2); vaultB: Staking(3) -> 3 legs total
        assertEq(p.length, 3);

        // vaultA Staking
        assertEq(p[0].underlyingAsset.asset, address(underlying));
        assertEq(p[0].amount, 10e18);
        assertFalse(p[0].isDebt);
        assertEq(p[0].balanceOracle, address(meta));
        assertEq(p[0].protocol, "StakeWise V3");
        assertEq(p[0].positionId, address(vaultA).toHexString());
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"StakeWise V3\",\"product\":\"Vault\",\"name\":\"Genesis Vault\",\"type\":\"Staking\"}"
        );
        // vaultA Borrow
        assertEq(p[1].amount, 2e18);
        assertTrue(p[1].isDebt);
        assertEq(
            p[1].positionDetail,
            "{\"protocol\":\"StakeWise V3\",\"product\":\"Vault\",\"name\":\"Genesis Vault\",\"type\":\"Borrow\"}"
        );
        // vaultB Staking only
        assertEq(p[2].amount, 3e18);
        assertFalse(p[2].isDebt);
        assertEq(p[2].positionId, address(vaultB).toHexString());
        assertEq(
            p[2].positionDetail,
            "{\"protocol\":\"StakeWise V3\",\"product\":\"Vault\",\"name\":\"Meta Vault\",\"type\":\"Staking\"}"
        );
    }

    function test_assetFilter_match_and_miss() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        // Filter on the underlying -> both legs of vaultA.
        assertEq(meta.getOraclePositionsForInstances(alice, one, address(underlying)).length, 2);
        // Filter on a different asset -> empty.
        assertEq(meta.getOraclePositionsForInstances(alice, one, address(0xdead)).length, 0);
    }

    function test_unregisteredUnderlying_skipped() public {
        nav.unregisterAssetHelper(address(underlying));
        assertEq(meta.getOraclePositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_noPosition_empty() public view {
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(vaultB))));
        assertEq(meta.getOraclePositionsForInstances(address(0xB0B), ins, address(0)).length, 0);
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 1, "bad vault isolated, vaultB staking leg returned");
        assertEq(p[0].amount, 3e18);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2); // one per instance
        assertEq(a[0], address(underlying));
        assertEq(a[1], address(underlying));
    }
}
