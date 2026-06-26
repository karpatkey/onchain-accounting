// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV2InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV2InstancesMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Independent ground-truth views: the reserve's aToken / variableDebtToken (a different read path than
///         the adapter's getUserReserveData) used to cross-check emitted amounts.
interface IAaveV2Tokens {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aToken, address stableDebtToken, address variableDebtToken);

    /// @dev Canonical per-user reserve view; `usageAsCollateralEnabled` is the same flag the adapter uses to choose
    ///      Collateral vs Supplied, so the test can assert the exact expected kind rather than "either".
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title AaveV2InstancesMetaParityForkTest
/// @notice Fork tests for the Aave V2 instances meta-adapter against the real mainnet Aave V2 market and real
///         holders. Beyond the presence/identity smoke tests, asserts STRICT ground truth: every emitted leg's
///         amount equals the canonical aToken / variableDebtToken balanceOf, with the right PositionKind,
///         AAVE_V2_LENDING protocolId, (LendingPool, reserve) positionId, and "<symbol> position (<market>)" label.
contract AaveV2InstancesMetaParityForkTest is BalanceAdapterTestBase {
    address public constant DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address public constant LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant PURE_USDC_SUPPLIER = 0x32e8D4c9d1B711BC958d0Ce8D14b41F77Bb03a64;
    address public constant STETH_SUPPLY_USDC_BORROW = 0x434Dba149a4A2b9909A7FFeED08491Aed9d5b904;
    uint256 public constant FORK_BLOCK = 25_281_400;

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

    /// @notice Strict ground truth: each emitted leg's amount equals the canonical aToken / variableDebtToken
    ///         balanceOf (an independent read path from the adapter's getUserReserveData), with the correct kind,
    ///         AAVE_V2_LENDING protocolId, and (LendingPool, reserve) positionId.
    function _assertGroundTruth(address user) internal view {
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(user, _instance(), address(0));
        assertGt(pos.length, 0, "expected at least one V2 leg");
        for (uint256 i = 0; i < pos.length; i++) {
            INAVCalculator.PositionBalance memory p = pos[i];
            assertEq(p.protocolId, ProtocolIds.AAVE_V2_LENDING, "protocolId == aave-v2-lending");
            (address pool, address reserve) = abi.decode(p.positionId, (address, address));
            assertEq(pool, LENDING_POOL, "positionId pool == LendingPool (getLendingPool override)");
            assertEq(reserve, p.balanceAsset.asset, "positionId reserve == balanceAsset.asset");

            (address aToken,, address variableDebtToken) =
                IAaveV2Tokens(DATA_PROVIDER).getReserveTokensAddresses(reserve);
            if (p.isDebt) {
                assertEq(uint8(p.positionKind), uint8(PositionKind.Borrowed), "debt leg kind == Borrowed");
                assertEq(
                    p.amount, IERC20BalanceOf(variableDebtToken).balanceOf(user), "debt == variableDebtToken.balanceOf"
                );
            } else {
                assertEq(p.amount, IERC20BalanceOf(aToken).balanceOf(user), "credit == aToken.balanceOf");
                (,,,,,,,, bool usageAsCollateral) = IAaveV2Tokens(DATA_PROVIDER).getUserReserveData(reserve, user);
                PositionKind expected = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                assertEq(
                    uint8(p.positionKind), uint8(expected), "credit leg kind matches canonical usageAsCollateralEnabled"
                );
            }
        }
    }

    function test_groundTruth_collateralSupplier() public view {
        _assertGroundTruth(PURE_USDC_SUPPLIER);
    }

    function test_groundTruth_supplyAndBorrow() public view {
        _assertGroundTruth(STETH_SUPPLY_USDC_BORROW);
    }

    /// @notice The supply/borrow holder must emit a stETH credit leg and a USDC Borrowed leg, each matching the
    ///         canonical token balanceOf exactly.
    function test_supplyBorrow_exactLegs() public view {
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(STETH_SUPPLY_USDC_BORROW, _instance(), address(0));
        (address aSteth,,) = IAaveV2Tokens(DATA_PROVIDER).getReserveTokensAddresses(STETH);
        (,, address vdUsdc) = IAaveV2Tokens(DATA_PROVIDER).getReserveTokensAddresses(MAINNET_USDC);
        bool sawStethCredit;
        bool sawUsdcDebt;
        for (uint256 i = 0; i < pos.length; i++) {
            INAVCalculator.PositionBalance memory p = pos[i];
            if (p.balanceAsset.asset == STETH && !p.isDebt) {
                assertEq(
                    p.amount, IERC20BalanceOf(aSteth).balanceOf(STETH_SUPPLY_USDC_BORROW), "stETH == aToken.balanceOf"
                );
                (,,,,,,,, bool usageAsCollateral) =
                    IAaveV2Tokens(DATA_PROVIDER).getUserReserveData(STETH, STETH_SUPPLY_USDC_BORROW);
                PositionKind expected = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                assertEq(uint8(p.positionKind), uint8(expected), "stETH credit kind matches usageAsCollateralEnabled");
                sawStethCredit = true;
            }
            if (p.balanceAsset.asset == MAINNET_USDC && p.isDebt) {
                assertEq(uint8(p.positionKind), uint8(PositionKind.Borrowed), "USDC leg == Borrowed");
                assertEq(
                    p.amount,
                    IERC20BalanceOf(vdUsdc).balanceOf(STETH_SUPPLY_USDC_BORROW),
                    "USDC debt == variableDebtToken.balanceOf"
                );
                sawUsdcDebt = true;
            }
        }
        assertTrue(sawStethCredit, "expected stETH credit leg");
        assertTrue(sawUsdcDebt, "expected USDC Borrowed leg");
    }

    function test_protocolId_isAaveV2() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(PURE_USDC_SUPPLIER, _instance(), address(0));
        assertGt(p.length, 0);
        assertEq(p[0].protocolId, ProtocolIds.AAVE_V2_LENDING, "protocolId == keccak256('aave-v2-lending')");
    }

    /// @notice positionLabels surfaces the market id (resolved via the V2 getAddressesProvider() path), so the
    ///         label distinguishes the V2 genesis market from V3 Core/Lido.
    function test_positionLabels_includesMarket() public view {
        string[] memory labels = meta.positionLabels(abi.encode(LENDING_POOL, MAINNET_USDC));
        assertEq(labels.length, 2);
        assertEq(labels[0], "Market Instance");
        assertEq(labels[1], "USDC position (Aave genesis market)", "labels[1] == '<symbol> position (<market id>)'");
    }
}
