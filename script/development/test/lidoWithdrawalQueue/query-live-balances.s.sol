// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LidoWithdrawalQueueBalanceAdapter} from "src/balances/protocols/LidoWithdrawalQueue.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryLidoWithdrawalQueueLiveBalances
/// @notice Ad-hoc evidence helper: deploys the Lido Withdrawal Queue adapter pointed at a deployed NAV (the asset
///         registry) on the dev fork and prints each holder's ETH leg. Used to capture the values in this folder's
///         README and to cross-check against a portfolio tracker.
/// @dev The position is denominated in native ETH (the asset Lido pays on claim). Native ETH must be registered on
///      the NAV for getAdapterPositions to emit the leg (01_DeployNAV registers the native ETH/USD feed). Point this
///      at the dev anvil RPC where deploy.sh stood up a NAV proxy:
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/lidoWithdrawalQueue/query-live-balances.s.sol:QueryLidoWithdrawalQueueLiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
contract QueryLidoWithdrawalQueueLiveBalances is Script {
    address constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    /// @dev ERC-7528 native-ETH sentinel — what Lido pays on claim and how the adapter denominates positions.
    address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Primary holder: two PENDING (un-finalized) requests → amountOfStETH branch + multi-request summing.
    address constant PRIMARY = 0x9074212F22F75789cA3fa21A4B46d3A1489CC0a9;
    /// @dev Secondary holder: one FINALIZED-unclaimed request → getClaimableEther branch.
    address constant SECONDARY = 0x2DE923BEE124514939ACa4f8f057e11Ff8d44F2b;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        LidoWithdrawalQueueBalanceAdapter adapter =
            new LidoWithdrawalQueueBalanceAdapter(WITHDRAWAL_QUEUE, NATIVE_ETH, nav);

        _print(adapter, "PRIMARY (2 pending)", PRIMARY);
        _print(adapter, "SECONDARY (1 finalized)", SECONDARY);
    }

    function _print(LidoWithdrawalQueueBalanceAdapter adapter, string memory label, address holder) internal view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        console2.log("=== Lido WQ holder:", label);
        console2.log("  address:  ", holder);
        console2.log("  ETH owed: ", amount);
        console2.log("  isDebt:   ", isDebt);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        console2.log("  legs:     ", p.length);
        for (uint256 i = 0; i < p.length; i++) {
            console2.log("  ---");
            console2.log("    asset: ", p[i].balanceAsset.symbol);
            console2.log("    amount:", p[i].amount);
            // positionKind: 1 = Supplied (src/utils/PositionKind.sol)
            console2.log("    kind:  ", uint256(p[i].positionKind));
        }
    }
}
