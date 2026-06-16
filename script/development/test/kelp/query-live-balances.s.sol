// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {KelpWithdrawalQueueBalanceOracle} from "src/balances/protocols/KelpWithdrawalQueue.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryKelpWithdrawalQueueLiveBalances
/// @notice Ad-hoc evidence helper: deploys the Kelp Withdrawal Queue oracle pointed at a deployed NAV (the asset
///         registry) on the dev fork and prints the holder's per-asset legs. Used to capture the values in this
///         folder's README and to cross-check against a portfolio tracker.
/// @dev Kelp is multi-asset (one leg per Kelp-supported payout asset registered in NAV: stETH, native ETH; ETHx
///      is skipped on the dev NAV — custom feed). Point this at the dev anvil RPC where deploy.sh stood up a NAV:
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/kelp/query-live-balances.s.sol:QueryKelpWithdrawalQueueLiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
contract QueryKelpWithdrawalQueueLiveBalances is Script {
    address constant WITHDRAWAL_MANAGER = 0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16;

    /// @dev Multi-asset holder: two open stETH requests (summed) + one open native-ETH request.
    address constant HOLDER = 0x13833b44341288dF27cc85e3eFDA8CD3830a4d35;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        KelpWithdrawalQueueBalanceOracle oracle = new KelpWithdrawalQueueBalanceOracle(WITHDRAWAL_MANAGER, nav);

        console2.log("=== Kelp WQ holder (MULTI_ASSET):", HOLDER);
        INAVCalculator.PositionBalance[] memory p = oracle.getOraclePositions(HOLDER, address(0));
        console2.log("  legs:", p.length);
        for (uint256 i = 0; i < p.length; i++) {
            console2.log("  ---");
            console2.log("    asset: ", p[i].balanceAsset.symbol);
            console2.log("    amount:", p[i].amount);
            // positionKind: 1 = Supplied (src/utils/PositionKind.sol)
            console2.log("    kind:  ", uint256(p[i].positionKind));
        }
    }
}
