// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AaveUmbrellaBalanceOracle} from "src/balances/protocols/AaveUmbrella.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryAaveUmbrellaLiveBalances
/// @notice Ad-hoc evidence helper: deploys the Aave Umbrella balance oracle pointed at a deployed NAV (used as
///         the asset registry) on the dev fork and prints the per-leg breakdown the adapter emits for the
///         verification holders. Used to capture the amounts documented in this folder's README and to
///         cross-check against a portfolio tracker.
/// @dev The adapter only reports a stake token's leg if its bare reserve is registered on the NAVCalculator.
///      Point this at the dev anvil RPC where deploy.sh stood up a NAV proxy (USDC/USDT/WETH/GHO registered):
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/aaveUmbrella/query-live-balances.s.sol:QueryAaveUmbrellaLiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
///      For a registry-controlled dump at an exact archive block, read getOraclePositions in the fork test
///      (test/balances/protocols/fork/AaveUmbrella.fork.t.sol), which deploys its own Balances harness.
contract QueryAaveUmbrellaLiveBalances is Script {
    address constant REWARDS_CONTROLLER = 0x4655Ce3D625a63d30bA704087E52B4C31E38188B;
    // Holders covering all four stake tokens + the same-asset stkGHO case (see README §5).
    address constant STK_WA_WETH_HOLDER = 0x000000000004444c5dc75cB358380D2e3dE08A90; // all four stake tokens
    address constant STK_GHO_HOLDER = 0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a; // stkGHO staking + rewards (both GHO)
    address constant STK_WA_USDC_HOLDER = 0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03;
    address constant STK_WA_USDT_HOLDER = 0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        AaveUmbrellaBalanceOracle oracle = new AaveUmbrellaBalanceOracle(REWARDS_CONTROLLER, nav);

        _dump(oracle, "STK_WA_WETH_HOLDER (all four)", STK_WA_WETH_HOLDER);
        _dump(oracle, "STK_GHO_HOLDER", STK_GHO_HOLDER);
        _dump(oracle, "STK_WA_USDC_HOLDER", STK_WA_USDC_HOLDER);
        _dump(oracle, "STK_WA_USDT_HOLDER", STK_WA_USDT_HOLDER);
    }

    function _dump(AaveUmbrellaBalanceOracle oracle, string memory label, address holder) internal view {
        console2.log("=== holder:", label);
        INAVCalculator.PositionBalance[] memory p = oracle.getOraclePositions(holder, address(0));
        console2.log("legs:", p.length);
        for (uint256 i = 0; i < p.length; i++) {
            console2.log("---");
            console2.log("  asset: ", p[i].balanceAsset.symbol);
            console2.log("  amount:", p[i].amount);
            // positionKind: 4 = Staking, 5 = Rewards (src/utils/PositionKind.sol)
            console2.log("  kind:  ", uint256(p[i].positionKind));
        }
    }
}
