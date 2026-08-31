// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PolygonStakingMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title RedeployPolygonStakingMeta
/// @author KPK
/// @notice Deploys `PolygonStakingMetaBalanceAdapter` from the CURRENT tree, so the live adapter stops
///         predating the `word == 0` label guard.
/// @dev The live adapter `0x3Feb6F1e…` was compiled at `f2d14408`, before `8a3a527b` added
///      `if (word == 0) return (0, false);` to `_readValidatorId`. Measured: 7 460 bytes on chain against
///      7 466 for HEAD. Impact is DISPLAY-ONLY — the live contract renders `"Validator #0"` for an
///      instance answering every selector with a zero word where HEAD falls back to the symbol/address
///      form. `positionLabels` feeds no valuation and `_instancePositions` is byte-identical, so no NAV
///      figure changes. This closes the drift entry rather than fixing a valuation bug.
///
///      **This script only DEPLOYS.** Registration is deliberately left to `SwapMetaAdapter`, which
///      removes the predecessor's instance set before deregistering it — the ordering that never leaves
///      both adapters live at once. Both registered simultaneously is a silent double-count, measured at
///      +$11,375.92 on ACCOUNT_11, and it is exactly what a hand-rolled add-then-remove would cause.
contract RedeployPolygonStakingMeta is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant LIVE = 0x3Feb6F1e0cd384BE4440cFCCd1aa90394A05b1a4;

    error WrongChain(uint256 chainId);

    function run() external {
        if (block.chainid != 1) revert WrongChain(block.chainid);

        address underlying = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, 1, "balanceAdapters", "PolygonStakingMeta", "underlyingToken")
        );
        console2.log("underlying (POL) :", underlying);
        console2.log("live adapter     :", LIVE);
        console2.log("live codesize    :", LIVE.code.length);

        vm.startBroadcast();
        PolygonStakingMetaBalanceAdapter adapter = new PolygonStakingMetaBalanceAdapter(underlying, NAV);
        vm.stopBroadcast();

        console2.log("new adapter      :", address(adapter));
        console2.log("new codesize     :", address(adapter).code.length);
        require(address(adapter).code.length > LIVE.code.length, "successor is not newer than the incumbent");
        console2.log("NEXT: SwapMetaAdapter with OLD_ADAPTER=%s NEW_ADAPTER=%s", LIVE, address(adapter));
    }
}
