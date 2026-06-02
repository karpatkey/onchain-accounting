// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {IProtocolDataProvider} from "src/balances/protocols/SparkLend.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Minimal PoolAddressesProvider mock: getPool() + getMarketId().
contract MockAaveAddressesProvider {
    address public pool;
    string private _marketId;

    constructor(address pool_, string memory marketId_) {
        pool = pool_;
        _marketId = marketId_;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function getMarketId() external view returns (string memory) {
        return _marketId;
    }
}

/// @notice Minimal Aave ProtocolDataProvider mock: reserves list, per-user reserve data, ADDRESSES_PROVIDER.
contract MockAaveDataProvider {
    address public ADDRESSES_PROVIDER;
    IProtocolDataProvider.TokenData[] private _reserves;

    struct UserData {
        uint256 aToken;
        uint256 variableDebt;
        bool usageAsCollateral;
    }

    mapping(address => mapping(address => UserData)) private _userData;

    constructor(address addressesProvider) {
        ADDRESSES_PROVIDER = addressesProvider;
    }

    function addReserve(string memory symbol, address token) external {
        _reserves.push(IProtocolDataProvider.TokenData({symbol: symbol, tokenAddress: token}));
    }

    function setUserData(address user, address asset, uint256 aToken, uint256 variableDebt, bool usageAsCollateral)
        external
    {
        _userData[user][asset] = UserData(aToken, variableDebt, usageAsCollateral);
    }

    function getAllReservesTokens() external view returns (IProtocolDataProvider.TokenData[] memory) {
        return _reserves;
    }

    function getUserReserveData(address asset, address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint40, bool)
    {
        UserData memory d = _userData[user][asset];
        return (d.aToken, 0, d.variableDebt, 0, 0, 0, 0, 0, d.usageAsCollateral);
    }
}

/// @title AaveV3InstancesMetaBalanceAdapter unit tests (mocks, no fork)
contract AaveV3InstancesMetaUnitTest is BalanceAdapterTestBase {
    using Strings for address;

    AaveV3InstancesMetaBalanceAdapter public oracle;
    MockAaveDataProvider public dp;
    MockAaveAddressesProvider public addrProvider;
    address public constant pool = 0x1111111111111111111111111111111111111111;

    function setUp() public override {
        super.setUp(); // registers usdc, dai, weth on `balances`
        addrProvider = new MockAaveAddressesProvider(pool, "Aave V3 Test Instance");
        dp = new MockAaveDataProvider(address(addrProvider));
        dp.addReserve("USDC", address(usdc));
        dp.addReserve("WETH", address(weth));
        oracle = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(balances));
    }

    function _ids() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(address(dp))));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_empty() public {
        dp.setUserData(alice, address(usdc), 100e6, 0, true);
        assertEq(oracle.getOraclePositions(alice, address(0)).length, 0);
    }

    function test_collateralSupplyBorrow_legs() public {
        // WETH used as collateral, USDC supplied (not collateral) + USDC borrowed.
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        dp.setUserData(alice, address(usdc), 1000e6, 400e6, false);

        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 3, "collateral(WETH) + supply(USDC) + borrow(USDC)");

        // Reserve order: USDC first, WETH second.
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 1000e6);
        assertFalse(pos[0].isDebt);
        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertEq(pos[1].amount, 400e6);
        assertTrue(pos[1].isDebt);
        assertEq(pos[2].balanceAsset.asset, address(weth));
        assertEq(pos[2].amount, 5e18);
        assertFalse(pos[2].isDebt);

        // Identity derived on-chain: positionId = abi.encode(pool), protocolId = AAVE_V3_LENDING.
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceOracle, address(oracle));
            assertEq(pos[i].protocolId, keccak256("aave-v3-lending"));
            assertEq(pos[i].positionId, abi.encode(pool));
        }
    }

    function test_assetFilter_returnsOnlyAsset() public {
        dp.setUserData(alice, address(weth), 5e18, 0, true);
        dp.setUserData(alice, address(usdc), 1000e6, 400e6, false);

        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _ids(), address(usdc));
        assertEq(pos.length, 2, "USDC supply + borrow");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[1].balanceAsset.asset, address(usdc));
    }

    function test_noPosition_empty() public view {
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = oracle.underlyingAssetsSupportedForInstances(_ids());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }
}
