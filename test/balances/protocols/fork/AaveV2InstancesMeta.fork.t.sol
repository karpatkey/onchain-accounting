// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV2InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV2InstancesMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title AaveV2InstancesMetaParityForkTest
/// @notice Fork tests for the Aave V2 instances meta-adapter against real mainnet contracts.
///         exactly against the real mainnet Aave V2 market and real holders (pure supplier + supply/borrow). Both
///         adapters share one BalancesHarnessForFork.
contract AaveV2InstancesMetaParityForkTest is BalanceAdapterTestBase {
    address public constant DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address public constant LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant PURE_USDC_SUPPLIER = 0x32e8D4c9d1B711BC958d0Ce8D14b41F77Bb03a64;
    address public constant STETH_SUPPLY_USDC_BORROW = 0x434Dba149a4A2b9909A7FFeED08491Aed9d5b904;
    uint256 public constant FORK_BLOCK = 25_000_000;

    AaveV2InstancesMetaBalanceAdapter public meta;
    address[] internal assetsList;

    function setUp() public override {
        super.setUp();
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);

        assetsList = new address[](6);
        assetsList[0] = MAINNET_USDC;
        assetsList[1] = MAINNET_DAI;
        assetsList[2] = MAINNET_WETH;
        assetsList[3] = MAINNET_WBTC;
        assetsList[4] = MAINNET_USDT;
        assetsList[5] = STETH;
        balances = _deployBalancesForAdapter(assetsList);

        meta = new AaveV2InstancesMetaBalanceAdapter("Aave V2", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(DATA_PROVIDER)));
    }

    function _sums(INAVCalculator.PositionBalance[] memory p, address asset)
        internal
        pure
        returns (uint256 credit, uint256 debt)
    {
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset != asset) continue;
            if (p[i].isDebt) debt += p[i].amount;
            else credit += p[i].amount;
        }
    }

    function _assertMetaHasPositions(address user) internal view {
        INAVCalculator.PositionBalance[] memory metaPos =
            meta.getAdapterPositionsForInstances(user, _instance(), address(0));
        uint256 total;
        for (uint256 a = 0; a < assetsList.length; a++) {
            (uint256 mc, uint256 md) = _sums(metaPos, assetsList[a]);
            total += mc + md;
        }
        assertGt(total, 0, "user should have a non-zero V2 position");
    }

    function test_pureSupplier_hasPositions() public view {
        _assertMetaHasPositions(PURE_USDC_SUPPLIER);
    }

    function test_supplyBorrow_hasPositions() public view {
        _assertMetaHasPositions(STETH_SUPPLY_USDC_BORROW);
    }

    function test_identityDerivedViaLendingPool() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(PURE_USDC_SUPPLIER, _instance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            (address pool,) = abi.decode(p[i].positionId, (address, address));
            assertEq(pool, LENDING_POOL, "positionId pool = LendingPool (getLendingPool)");
        }
    }
}
