// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title PriceFeedPolicyTest
/// @notice Enforces the share-price oracle provider policy (ADR 0021) on the registration config so it cannot
///         silently drift back:
///           - AT MOST ONE price feed per asset — a single deterministic source removes the freshest-wins
///             oscillation / stale-flip surface that an adversarial sub/redeem share price could exploit; and
///           - ONLY Chainlink or Custom feed types — no API3 (schedule-only, ~once-daily → serves a stale price
///             between updates) and no Redstone (redundant market feed). Yield-bearing assets use a Custom
///             (fundamental, CAPO) feed; everything else a single Chainlink feed.
///         Assets may be feedless (empty priceFeeds) by design — that is fail-loud, not a violation.
contract PriceFeedPolicyTest is Test {
    /// @dev Every chain with a nav-config assets file.
    function _chains() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](7);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 56;
        ids[3] = 100;
        ids[4] = 137;
        ids[5] = 8453;
        ids[6] = 42_161;
    }

    function test_config_atMostOneFeed_andOnlyChainlinkOrCustom() public view {
        uint256[] memory ids = _chains();
        for (uint256 c; c < ids.length; ++c) {
            uint256 chainId = ids[c];
            string[] memory symbols = ConfigReader.getAssetSymbols(vm, chainId);
            for (uint256 i; i < symbols.length; ++i) {
                string memory sym = symbols[i];
                uint256 n = ConfigReader.assetFeedCount(vm, chainId, sym);
                assertLe(n, 1, string(abi.encodePacked("more than one feed: chain ", vm.toString(chainId), " ", sym)));
                for (uint256 j; j < n; ++j) {
                    (IPrices.PriceType pt, bool valid) = ConfigReader.readAssetFeedPriceType(vm, chainId, sym, j);
                    assertTrue(
                        valid, string(abi.encodePacked("invalid feed type: chain ", vm.toString(chainId), " ", sym))
                    );
                    assertTrue(
                        pt == IPrices.PriceType.Chainlink || pt == IPrices.PriceType.Custom,
                        string(abi.encodePacked("non-Chainlink/Custom feed: chain ", vm.toString(chainId), " ", sym))
                    );
                }
            }
        }
    }
}
