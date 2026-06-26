// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC4626WrapBalanceAdapter} from "src/balances/protocols/ERC4626WrapBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QuerySghoLiveBalances
/// @notice Ad-hoc evidence helper: deploys the ERC4626 wrapper adapter for sGHO pointed at a deployed NAV (the
///         asset registry) on the dev fork and prints the holder's GHO leg. Used to capture the value in this
///         folder's README and to cross-check against the Aave UI / a portfolio tracker.
/// @dev The constructor reverts unless GHO is registered on the NAV. Point this at the dev anvil RPC where
///      deploy.sh stood up a NAV proxy (GHO registered by register-assets.sh):
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/sgho/query-live-balances.s.sol:QuerySghoLiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
contract QuerySghoLiveBalances is Script {
    address constant SGHO = 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d;
    address constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address constant HOLDER = 0x5eF87DeC00a19d2b47EE0073d869F7d7feFF26ef;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        ERC4626WrapBalanceAdapter adapter = new ERC4626WrapBalanceAdapter(SGHO, nav);

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, GHO);
        console2.log("=== sGHO holder:", HOLDER);
        console2.log("  GHO value:", amount);
        console2.log("  isDebt:   ", isDebt);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
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
