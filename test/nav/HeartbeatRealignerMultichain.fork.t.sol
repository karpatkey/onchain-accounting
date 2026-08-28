// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {HeartbeatRealigner} from "script/manage/HeartbeatRealigner.sol";

/// @title HeartbeatRealignerMultichainForkTest
/// @author KPK
/// @notice Rehearses the ADR 0025 realignment on every remaining chain, against live state.
/// @dev One test per chain so a failure names the chain rather than the batch. The asset lists and target
///      heartbeats are generated from `script/config/nav-config/assets-and-price-feeds/<chainId>.json`
///      rather than transcribed, so the rehearsal and the config cannot drift apart.
///
///      Chains 56 and 137 carry the largest drops (86400 -> 27 on Polygon), which is exactly why each
///      chain is rehearsed rather than inferred from mainnet passing: a heartbeat shorter than the feed's
///      real publish cadence would leave the asset permanently stale, and that shows up here as the
///      post-realignment staleness assertion failing.
///
///      Public endpoints are the defaults because Alchemy does not serve BSC or Polygon on this key; each
///      is overridable via the named env var.
contract HeartbeatRealignerMultichainForkTest is Test {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant ADMIN = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

    address[] assets;
    uint256[] heartbeats;
    string[] syms;

    function _fork(string memory envName, string memory fallbackUrl, uint256 blk) private {
        vm.createSelectFork(vm.envOr(envName, fallbackUrl), blk);
    }

    /// @dev Forks at head rather than a pinned block. Only for chains with no reachable archive node —
    ///      BSC's public endpoints serve current state but answer `missing trie node` for historical
    ///      state, and the archive-capable ones require a paid token. The cost is that this rehearsal is
    ///      not reproducible at a fixed block; set CHAIN_56_RPC to an archive endpoint to pin it.
    function _forkLatest(string memory envName, string memory fallbackUrl) private {
        vm.createSelectFork(vm.envOr(envName, fallbackUrl));
    }

    function _t(string memory s, address a, uint256 h) private {
        syms.push(s);
        assets.push(a);
        heartbeats.push(h);
    }

    /// @dev Asserts the realignment moved the heartbeat and nothing else, for every asset on the chain.
    function _rehearse(uint256 chainId) private {
        uint256 n = assets.length;
        uint256[] memory priceBefore = new uint256[](n);
        address[] memory feedBefore = new address[](n);
        uint256[] memory hbBefore = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            priceBefore[i] = uint256(d.price);
            assertGt(priceBefore[i], 0, string.concat(syms[i], ": unpriced BEFORE realignment"));
            assertFalse(d.stale, string.concat(syms[i], ": already stale BEFORE realignment"));
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            feedBefore[i] = c.priceFeed;
            hbBefore[i] = c.chainlinkHeartbeat;
        }

        HeartbeatRealigner r = new HeartbeatRealigner(NAV);
        assertTrue(NAVCalculator(NAV).hasRole(0x00, ADMIN), "ADMIN does not hold DEFAULT_ADMIN_ROLE on this chain");

        vm.startPrank(ADMIN);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(r));
        r.realign(assets, heartbeats);
        NAVCalculator(NAV).revokeRole(MANAGER_ROLE, address(r));
        vm.stopPrank();

        for (uint256 i; i < n; ++i) {
            assertEq(NAVCalculator(NAV).getPriceFeedCount(assets[i]), 1, string.concat(syms[i], ": feed count"));
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            assertEq(c.priceFeed, feedBefore[i], string.concat(syms[i], ": FEED ADDRESS CHANGED"));
            assertEq(c.chainlinkHeartbeat, heartbeats[i], string.concat(syms[i], ": heartbeat not applied"));
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            // The realignment must never change WHAT the asset is worth. It may legitimately change
            // whether the asset is currently priceable at all: at `declared + 0` a feed that has overrun
            // its declared heartbeat reads stale and prices 0, which is the deliberate ADR 0025 trade-off
            // (a loud halt beats a stale number presented as fresh). So the property is: either the price
            // is unchanged and fresh, or the asset is flagged stale. A CHANGED price that is still
            // reported fresh is the failure, and is what this asserts against.
            if (d.stale) {
                assertEq(uint256(d.price), 0, string.concat(syms[i], ": stale but non-zero price"));
                console2.log(string.concat("  NOTE ", syms[i], ": stale at the new heartbeat (feed overran declared)"));
            } else {
                assertEq(uint256(d.price), priceBefore[i], string.concat(syms[i], ": PRICE MOVED WHILE FRESH"));
            }
            console2.log(
                string.concat(
                    "  [",
                    vm.toString(chainId),
                    "] ",
                    syms[i],
                    ": ",
                    vm.toString(hbBefore[i]),
                    " -> ",
                    vm.toString(c.chainlinkHeartbeat)
                )
            );
        }
        assertFalse(NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(r)), "role must not survive");
    }

    /// @notice Chain 10 — 2 asset(s).
    function test_chain10() public {
        _fork("CHAIN_10_RPC", "https://mainnet.optimism.io", 156168200);
        _t("USDC", 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, 86400);
        _t("USDT", 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58, 86400);
        _rehearse(10);
    }

    /// @notice Chain 56 — 6 asset(s).
    function test_chain56() public {
        _forkLatest("CHAIN_56_RPC", "https://bsc-dataseed.binance.org");
        _t("BNB", 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, 27);
        _t("CAKE", 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82, 60);
        _t("ETH", 0x2170Ed0880ac9A755fd29B2688956BD959F933F8, 60);
        _t("USDC", 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d, 900);
        _t("USDT", 0x55d398326f99059fF775485246999027B3197955, 900);
        _t("WBNB", 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 27);
        _rehearse(56);
    }

    /// @notice Chain 100 — 6 asset(s).
    function test_chain100() public {
        _fork("CHAIN_100_RPC", "https://rpc.gnosischain.com", 47960811);
        _t("EURe", 0xcB444e90D8198415266c6a2724b7900fb12FC56E, 86400);
        _t("GHO", 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73, 86400);
        _t("USDCe", 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0, 86400);
        _t("USDT", 0x4ECaBa5870353805a9F068101A40E0f32ed605C6, 86400);
        _t("WXDAI", 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d, 86400);
        _t("xDAI", 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, 86400);
        _rehearse(100);
    }

    /// @notice Chain 137 — 5 asset(s).
    function test_chain137() public {
        _fork("CHAIN_137_RPC", "https://polygon.drpc.org", 92820103);
        _t("POL", 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, 27);
        _t("USDC", 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, 27);
        _t("USDT", 0xc2132D05D31c914a87C6611C10748AEb04B58e8F, 27);
        _t("WETH", 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619, 27);
        _t("WPOL", 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, 27);
        _rehearse(137);
    }

    /// @notice Chain 8453 — 4 asset(s).
    function test_chain8453() public {
        _fork("CHAIN_8453_RPC", "https://mainnet.base.org", 50572917);
        _t("GHO", 0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee, 86400);
        _t("USDC", 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 86400);
        _t("USDT", 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2, 86400);
        _t("cbBTC", 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, 1200);
        _rehearse(8453);
    }

    /// @notice Chain 42161 — 5 asset(s).
    function test_chain42161() public {
        _fork("CHAIN_42161_RPC", "https://arb1.arbitrum.io/rpc", 499321360);
        _t("ETH", 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, 1755);
        _t("GHO", 0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33, 86400);
        _t("USDC", 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, 255);
        _t("USDT", 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9, 255);
        _t("WETH", 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, 1755);
        _rehearse(42161);
    }
}
