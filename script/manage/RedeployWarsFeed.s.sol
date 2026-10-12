// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {InvertedChainlinkCustomPriceFeed} from "src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol";

interface IFeedHeartbeat {
    function FEED_HEARTBEAT() external view returns (uint256);
}
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title RedeployWarsFeed
/// @author KPK
/// @notice Redeploys the wARS custom price feed at the DECLARED heartbeat and swaps the live
///         registration onto it, per ADR 0025.
/// @dev **Why a redeploy rather than a realignment.** The offending value is
///      `usdToAssetChainlinkHeartbeat`, a CONSTRUCTOR arg of `InvertedChainlinkCustomPriceFeed`. It was
///      90 000 against a declared 86 400 on the USD/ARS leg — a +3 600 s window in which a dead feed
///      still reads fresh, which is the one error ADR 0025 treats as critical. Constructor args are
///      immutable, so `HeartbeatRealigner` cannot touch it; the contract has to be replaced.
///
///      **No mirror is needed here, unlike a heartbeat realignment.** The new feed is a DIFFERENT
///      address, so `addOrModifyPriceFeed` does not hit `PriceFeedAlreadyRegistered` and the asset is never
///      single-feed at the moment of removal:
///
///        add(new) -> asset holds [old, new], primary is still `old`
///        remove(old) -> swap-and-pop leaves [new], primary is `new`
///
///      The price is correct at every step: both feeds invert the same USD/ARS aggregator, and the only
///      difference between them is the staleness gate. Asserted below rather than assumed.
///
///      Registration of a Custom feed is validated against `underlyingAssetSupported()`, so a feed built
///      for the wrong asset cannot be swapped in by accident.
contract RedeployWarsFeed is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    string constant NAME = "wARS";

    error NotManager(address who);
    error WrongChain(uint256 chainId);
    error NothingToDo();

    function run() external {
        uint256 chainId = block.chainid;
        if (chainId != 1) revert WrongChain(chainId);

        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, chainId, NAME, "underlyingAsset"));
        address usdToAssetFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, chainId, NAME, "usdToAssetChainlinkAddress"));
        uint256 heartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, chainId, NAME, "usdToAssetChainlinkHeartbeat"));
        uint256 minAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, chainId, NAME, "minAnswer"));
        uint256 maxAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, chainId, NAME, "maxAnswer"));

        address sender = ConfigReader.readChainConfig(vm, chainId).manager;
        if (!NAVCalculator(NAV).hasRole(keccak256("MANAGER"), sender)) revert NotManager(sender);

        IPrices.PriceFeedConfig memory old = NAVCalculator(NAV).getPriceFeedAt(underlying, 0);
        INAVCalculator.PriceFeedData memory before_ = INAVCalculator(NAV).getPriceData(underlying);
        console2.log("=== wARS feed redeploy (ADR 0025) ===");
        console2.log("underlying     :", underlying);
        console2.log("old feed       :", old.priceFeed);
        console2.log("old NAV hb     :", old.chainlinkHeartbeat);
        console2.log("new ctor hb    :", heartbeat);
        console2.log("price before   :", uint256(before_.price));
        require(!before_.stale, "wARS is stale BEFORE the swap - resolve that first");

        // IDEMPOTENCE MUST BE DECIDED BEFORE DEPLOYING, NOT AFTER. The old guard compared the freshly
        // deployed address against the incumbent, which can never match — plain CREATE always yields a new
        // address — so re-running a COMPLETED migration would deploy a second identical feed, rotate wARS
        // onto it, and leave the address committed in deployments/1.json stale again. The real question is
        // whether the incumbent already carries the target heartbeat on BOTH axes: the NAV-side
        // registration and the feed's own immutable FEED_HEARTBEAT.
        uint256 incumbentCtorHb = IFeedHeartbeat(old.priceFeed).FEED_HEARTBEAT();
        if (old.chainlinkHeartbeat == heartbeat && incumbentCtorHb == heartbeat) revert NothingToDo();
        console2.log("incumbent ctor hb:", incumbentCtorHb);

        vm.startBroadcast();
        InvertedChainlinkCustomPriceFeed feed =
            new InvertedChainlinkCustomPriceFeed(underlying, usdToAssetFeed, heartbeat, minAnswer, maxAnswer);

        // Add BEFORE removing: the asset is never single-feed at the moment of removal, so the
        // CannotRemoveLastFeed guard is never reached and no mirror is required.
        NAVCalculator(NAV).addOrModifyPriceFeed(underlying, address(feed), IPrices.PriceType.Custom, heartbeat);
        NAVCalculator(NAV).removePriceFeed(underlying, old.priceFeed);
        vm.stopBroadcast();

        require(NAVCalculator(NAV).getPriceFeedCount(underlying) == 1, "expected exactly one feed");
        IPrices.PriceFeedConfig memory end = NAVCalculator(NAV).getPriceFeedAt(underlying, 0);
        require(end.priceFeed == address(feed), "did not end on the new feed");
        require(end.chainlinkHeartbeat == heartbeat, "NAV-side heartbeat not applied");
        INAVCalculator.PriceFeedData memory after_ = INAVCalculator(NAV).getPriceData(underlying);
        require(!after_.stale, "wARS went stale after the swap");
        // Both feeds invert the same aggregator, so the price must be identical, not merely close.
        require(uint256(after_.price) == uint256(before_.price), "PRICE MOVED");

        console2.log("new feed       :", address(feed));
        console2.log("price after    :", uint256(after_.price));
        console2.log("REMEMBER: record the new address in script/config/deployments/1.json");
    }
}
