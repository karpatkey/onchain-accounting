// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StaderWithdrawalQueueBalanceAdapter} from "src/balances/protocols/StaderWithdrawalQueue.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryStaderWithdrawalQueueLiveBalances
/// @notice Ad-hoc evidence helper: deploys the Stader Withdrawal Queue oracle pointed at a deployed NAV (the asset
///         registry) on the dev fork and prints each holder's WETH leg. Used to capture the values in this folder's
///         README and to cross-check against a portfolio tracker.
/// @dev The position is denominated in WETH (the position is ETH owed by the manager once ETHx is burned). WETH must
///      be registered on the NAV for getAdapterPositions to emit the leg (deploy.sh registers the WETH/USD feed). Point
///      this at the dev anvil RPC where deploy.sh stood up a NAV proxy:
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/stader/query-live-balances.s.sol:QueryStaderWithdrawalQueueLiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
contract QueryStaderWithdrawalQueueLiveBalances is Script {
    address constant USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;
    /// @dev WETH — the position is ETH owed by the manager; NAV prices it via ETH/USD.
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Pending holder: one un-finalized request (8218) → ethExpected branch.
    address constant PENDING = 0x4D0B2dB7d38009884c3f2a15c1c212f4F4a356c9;
    /// @dev Finalized holder: one finalized-unclaimed request (8214) → ethFinalized branch.
    address constant FINALIZED = 0x404186e63CA9e1D0648a5AEc0b77cD398814C47D;
    /// @dev Multi-request holder: two open requests (8196 + 8197) → summed into one aggregated leg.
    address constant MULTI = 0xeB0CBBA408436997AfD29c50d6A9ffcCf9a2493f;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        StaderWithdrawalQueueBalanceAdapter oracle =
            new StaderWithdrawalQueueBalanceAdapter(USER_WITHDRAWAL_MANAGER, WETH, nav);

        _print(oracle, "PENDING (1 un-finalized)", PENDING);
        _print(oracle, "FINALIZED (1 finalized)", FINALIZED);
        _print(oracle, "MULTI (2 requests summed)", MULTI);
    }

    function _print(StaderWithdrawalQueueBalanceAdapter oracle, string memory label, address holder) internal view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(holder, WETH);
        console2.log("=== Stader WQ holder:", label);
        console2.log("  address:  ", holder);
        console2.log("  ETH owed: ", amount);
        console2.log("  isDebt:   ", isDebt);

        INAVCalculator.PositionBalance[] memory p = oracle.getAdapterPositions(holder, address(0));
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
