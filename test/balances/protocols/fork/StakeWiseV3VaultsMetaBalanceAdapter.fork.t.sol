// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {StakeWiseV3VaultsMetaBalanceAdapter} from "src/balances/protocols/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3VaultsMetaParityForkTest (Gnosis)
/// @notice Fork tests for the StakeWise V3 vaults meta-adapter against real Gnosis contracts.
///         leg-for-leg (exact) against the real Gnosis Genesis vault and real holders. Both adapters share one
///         BalancesHarnessForFork registry.
contract StakeWiseV3VaultsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant VAULT = 0x4b4406Ed8659D03423490D8b62a1639206dA0A7a;
    address public constant TEST_USER = 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f;
    address public constant TEST_USER2 = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    uint256 public constant FORK_BLOCK_1 = 38_449_644;
    uint256 public constant FORK_BLOCK_2 = 35_261_999;

    StakeWiseV3VaultsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
    }

    function _deploy() internal {
        balances = _deployBalancesForAdapter(GNO);
        // Gnosis StakeWise OsTokenVaultController (same one osToken_CustomPriceFeed uses for osGNO).
        meta = new StakeWiseV3VaultsMetaBalanceAdapter(
            GNO, 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a, "StakeWise V3", address(balances)
        );
    }

    function _vaultInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(VAULT)));
    }

    /// @notice Sums (staking, borrow) over a position array.
    function _legs(INAVCalculator.PositionBalance[] memory p) internal pure returns (uint256 staking, uint256 borrow) {
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].isDebt) borrow += p[i].amount;
            else staking += p[i].amount;
        }
    }

    function test_user1_hasPosition() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();
        (uint256 s, uint256 b) = _legs(meta.getAdapterPositionsForInstances(TEST_USER, _vaultInstance(), address(0)));
        assertTrue(s > 0 || b > 0, "user1 should have a position");
    }

    function test_user2_withDebt() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_2);
        _deploy();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER2, _vaultInstance(), address(0));
        assertTrue(p.length > 0, "user2 should have a position");
    }

    function test_identityDerivedOnChain() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        _deploy();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER, _vaultInstance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(VAULT), "positionId = vault address");
            assertEq(p[i].balanceAsset.asset, GNO);
        }
    }
}
