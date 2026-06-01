// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMeta.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
/// @title CompoundV3CometsMetaParityForkTest
/// @notice Proves the Compound V3 comets meta-adapter reproduces the per-comet CompoundV3Comet exactly (same
///         CompoundV3CometLib math) against the real mainnet cUSDCv3 market and real holders covering supply,
///         borrow, multi-collateral, and COMP-reward positions. Both adapters share one BalancesHarnessForFork.
contract CompoundV3CometsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address public constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address public constant COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3; // cUSDCv3

    address public constant LEND_USER = 0x2b2E894f08F1BF8C93a82297c347EbdC8717d99a;
    address public constant BORROW_USER = 0xe84A061897afc2e7fF5FB7e3686717C528617487;
    address public constant MULTI_COLLATERAL_USER = 0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94;
    address public constant COMP_ONLY_USER = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;
    uint256 public constant FORK_BLOCK = 20_570_307;

    CompoundV3Comet public per;
    CompoundV3CometsMetaBalanceAdapter public meta;
    address[] internal assetsList;

    function setUp() public override {
        super.setUp();
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);

        assetsList = new address[](4);
        assetsList[0] = MAINNET_USDC;
        assetsList[1] = MAINNET_WBTC;
        assetsList[2] = MAINNET_WETH;
        assetsList[3] = COMP;
        balances = _deployBalancesForOracle(assetsList);

        per = new CompoundV3Comet(COMPOUND_REWARDS, COMET, COMP, address(balances));
        meta = new CompoundV3CometsMetaBalanceAdapter(COMPOUND_REWARDS, COMP, "Compound V3", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(COMET)));
    }

    /// @notice (credit, debt) totals for `asset` across a positions array.
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

    function _assertParity(address user) internal view {
        INAVCalculator.PositionBalance[] memory perPos = per.getOraclePositions(user, address(0));
        INAVCalculator.PositionBalance[] memory metaPos =
            meta.getOraclePositionsForInstances(user, _instance(), address(0));
        uint256 total;
        for (uint256 a = 0; a < assetsList.length; a++) {
            (uint256 pc, uint256 pd) = _sums(perPos, assetsList[a]);
            (uint256 mc, uint256 md) = _sums(metaPos, assetsList[a]);
            assertEq(mc, pc, "credit parity");
            assertEq(md, pd, "debt parity");
            total += pc + pd;
        }
        assertGt(total, 0, "user should have a non-zero position");
    }

    function test_parity_lend() public view {
        _assertParity(LEND_USER);
    }

    function test_parity_borrow() public view {
        _assertParity(BORROW_USER);
    }

    function test_parity_multiCollateral() public view {
        _assertParity(MULTI_COLLATERAL_USER);
    }

    function test_parity_compReward() public view {
        _assertParity(COMP_ONLY_USER);
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(LEND_USER, _instance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(COMET), "positionId = comet address");
        }
    }
}
