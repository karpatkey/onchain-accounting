// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV2InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV2InstancesMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryAaveV2LiveBalances
/// @notice Ad-hoc evidence helper: deploys the Aave V2 instances meta-adapter pointed at a deployed NAV (used as
///         the asset registry) on the dev fork and prints the per-leg breakdown the adapter emits for the
///         verification holders. Used to capture the amounts documented in this folder's README and to
///         cross-check against a portfolio tracker.
/// @dev The adapter only reports a token leg if that token is registered on its NAVCalculator. Point this at the
///      dev anvil RPC where deploy.sh stood up a NAV proxy (USDC/stETH registered) and pass it as DEV_NAV_PROXY:
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/aaveV2/query-live-balances.s.sol:QueryAaveV2LiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
///      For a registry-free dump at an exact archive block, read getOraclePositionsForInstances in the fork test
///      (test/balances/protocols/fork/AaveV2InstancesMeta.fork.t.sol), which deploys its own Balances harness.
contract QueryAaveV2LiveBalances is Script {
    address constant DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d; // Aave V2 ProtocolDataProvider
    address constant PURE_USDC_SUPPLIER = 0x32e8D4c9d1B711BC958d0Ce8D14b41F77Bb03a64;
    address constant STETH_SUPPLY_USDC_BORROW = 0x434Dba149a4A2b9909A7FFeED08491Aed9d5b904;

    function run() public {
        address nav = vm.envAddress("DEV_NAV_PROXY");
        AaveV2InstancesMetaBalanceAdapter meta = new AaveV2InstancesMetaBalanceAdapter("Aave V2", nav);

        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(DATA_PROVIDER)));

        _dump(meta, instances, "PURE_USDC_SUPPLIER", PURE_USDC_SUPPLIER);
        _dump(meta, instances, "STETH_SUPPLY_USDC_BORROW", STETH_SUPPLY_USDC_BORROW);
    }

    function _dump(
        AaveV2InstancesMetaBalanceAdapter meta,
        bytes32[] memory instances,
        string memory label,
        address holder
    ) internal view {
        console2.log("=== holder:", label);
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(holder, instances, address(0));
        console2.log("legs:", p.length);
        for (uint256 i = 0; i < p.length; i++) {
            console2.log("---");
            console2.log("  asset: ", p[i].balanceAsset.symbol);
            console2.log("  amount:", p[i].amount);
            console2.log("  isDebt:", p[i].isDebt);
            console2.log("  kind:  ", uint256(p[i].positionKind));
            console2.log("  label: ", meta.describePosition(p[i].positionId));
        }
    }
}
