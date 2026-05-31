// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {AaveV2InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV2InstancesMeta.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockAaveDataProvider} from "test/balances/protocols/AaveV3InstancesMeta.t.sol";

/// @notice Minimal Aave V2 LendingPoolAddressesProvider mock: getLendingPool() + getMarketId().
contract MockV2AddrProvider {
    address public lendingPool;
    string private _marketId;

    constructor(address lendingPool_, string memory marketId_) {
        lendingPool = lendingPool_;
        _marketId = marketId_;
    }

    function getLendingPool() external view returns (address) {
        return lendingPool;
    }

    function getMarketId() external view returns (string memory) {
        return _marketId;
    }
}

contract V2Tok {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title AaveV2InstancesMetaBalanceAdapter unit tests (no fork)
contract AaveV2InstancesMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    AaveV2InstancesMetaBalanceAdapter meta;
    MockAaveDataProvider dp;
    MockV2AddrProvider addr;
    V2Tok usdc;
    V2Tok weth;

    address alice = makeAddr("alice");
    address constant LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new V2Tok("USDC", 6);
        weth = new V2Tok("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        addr = new MockV2AddrProvider(LENDING_POOL, "Aave Mainnet Market");
        dp = new MockAaveDataProvider(address(addr));
        dp.addReserve("USDC", address(usdc));
        dp.addReserve("WETH", address(weth));
        // alice: 1000 USDC supplied as collateral; 0.5 WETH variable debt.
        dp.setUserData(alice, address(usdc), 1000e6, 0, true);
        dp.setUserData(alice, address(weth), 0, 5e17, false);

        meta = new AaveV2InstancesMetaBalanceAdapter("Aave V2", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(dp))));
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

    function test_legs_andIdentityViaLendingPool() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 2); // USDC Collateral + WETH Borrow

        assertEq(p[0].underlyingAsset.asset, address(usdc));
        assertEq(p[0].amount, 1000e6);
        assertFalse(p[0].isDebt);
        assertEq(p[0].protocol, "Aave V2");
        // positionId derived via getLendingPool() (V2), not getPool().
        assertEq(p[0].positionId, LENDING_POOL.toHexString());
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"Aave V2\",\"product\":\"Lending\",\"name\":\"Aave Mainnet Market\",\"type\":\"Collateral\"}"
        );

        assertEq(p[1].underlyingAsset.asset, address(weth));
        assertEq(p[1].amount, 5e17);
        assertTrue(p[1].isDebt);
        assertEq(
            p[1].positionDetail,
            "{\"protocol\":\"Aave V2\",\"product\":\"Lending\",\"name\":\"Aave Mainnet Market\",\"type\":\"Borrow\"}"
        );
    }

    function test_supplyLeg_whenNotCollateral() public {
        dp.setUserData(alice, address(usdc), 1000e6, 0, false); // supply not used as collateral
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(alice, _instances(), address(usdc));
        assertEq(p.length, 1);
        assertTrue(_hasType(p[0].positionDetail, "Supply"));
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(alice, _instances(), address(weth));
        assertEq(p.length, 1);
        assertEq(p[0].underlyingAsset.asset, address(weth));
    }

    function test_unregisteredReserve_skipped() public {
        nav.unregisterAssetHelper(address(weth));
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].underlyingAsset.asset, address(usdc));
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(dp))));
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 2, "bad instance isolated, dp legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2);
        assertEq(a[0], address(usdc));
        assertEq(a[1], address(weth));
    }

    function _hasType(string memory detail, string memory typ) private pure returns (bool) {
        bytes memory h = bytes(detail);
        bytes memory n = bytes(string.concat("\"type\":\"", typ, "\"}"));
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
