// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {HeartbeatRealigner} from "script/manage/HeartbeatRealigner.sol";

/// @title HeartbeatRealignerForkTest
/// @author KPK
/// @notice End-to-end rehearsal of the ADR 0025 realignment against live mainnet state.
/// @dev Exercises the real path: grant MANAGER_ROLE to the realigner from the account that actually holds
///      DEFAULT_ADMIN_ROLE on the live proxy, realign all eight chain-1 assets in ONE transaction, revoke.
///      The assertion that matters is not that the heartbeats moved — it is that nothing else did.
contract HeartbeatRealignerForkTest is Test, TestEnvConfigurator {
    uint256 constant FORK_BLOCK = 25_854_566;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant ADMIN = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

    HeartbeatRealigner realigner;
    address[] assets;
    uint256[] heartbeats;
    string[] syms;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        realigner = new HeartbeatRealigner(NAV, ADMIN);

        _t("AAVE", 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, 3600);
        _t("GHO", 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f, 86_400);
        _t("UNI", 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 3600);
        _t("USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 82_800);
        _t("USDS", 0xdC035D45d973E3EC169d2276DDab16f1e407384F, 82_800);
        _t("USDT", 0xdAC17F958D2ee523a2206206994597C13D831ec7, 86_400);
        _t("USDe", 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3, 82_800);
        _t("crvUSD", 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, 86_400);
    }

    function _t(string memory s, address a, uint256 h) private {
        syms.push(s);
        assets.push(a);
        heartbeats.push(h);
    }

    function test_realignsEveryChain1Asset_inOneTransaction() public {
        uint256 n = assets.length;
        uint256[] memory priceBefore = new uint256[](n);
        address[] memory feedBefore = new address[](n);
        uint256[] memory hbBefore = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            priceBefore[i] = uint256(d.price);
            assertGt(priceBefore[i], 0, string.concat(syms[i], ": unpriced before realignment"));
            assertFalse(d.stale, string.concat(syms[i], ": already stale before realignment"));
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            feedBefore[i] = c.priceFeed;
            hbBefore[i] = c.chainlinkHeartbeat;
        }

        vm.startPrank(ADMIN);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
        realigner.realign(assets, heartbeats);
        vm.stopPrank();

        for (uint256 i; i < n; ++i) {
            assertEq(NAVCalculator(NAV).getPriceFeedCount(assets[i]), 1, string.concat(syms[i], ": feed count"));
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            assertEq(c.priceFeed, feedBefore[i], string.concat(syms[i], ": FEED ADDRESS CHANGED"));
            assertEq(c.chainlinkHeartbeat, heartbeats[i], string.concat(syms[i], ": heartbeat not applied"));
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            assertEq(uint256(d.price), priceBefore[i], string.concat(syms[i], ": PRICE MOVED"));
            assertFalse(d.stale, string.concat(syms[i], ": went stale"));
            console2.log(
                string.concat("  ", syms[i], ": ", vm.toString(hbBefore[i]), " -> ", vm.toString(c.chainlinkHeartbeat))
            );
        }
        assertFalse(NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner)), "role must not survive");
    }

    /// @notice A stranded MANAGER_ROLE on this contract is INERT to everyone but the operator.
    /// @dev The defect this guards. On the Polygon rollout the trailing revoke ran out of gas and the
    ///      contract held MANAGER_ROLE for 107 blocks while `realign` had no caller check — anyone could
    ///      have rewritten the chain's pricing config. Revert-probed: with the `onlyOperator` modifier
    ///      removed, this test fails because the call succeeds.
    function test_strandedRole_isInertToNonOperators() public {
        vm.prank(ADMIN);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
        assertTrue(NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner)), "precondition: role stranded");

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(HeartbeatRealigner.NotOperator.selector, attacker));
        realigner.realign(assets, heartbeats);

        // ...and the config is untouched.
        assertEq(
            NAVCalculator(NAV).getPriceFeedAt(assets[0], 0).chainlinkHeartbeat,
            hbOf(assets[0]),
            "attacker mutated the registry"
        );
    }

    /// @notice The role does not outlive the transaction that used it — no trailing revoke required.
    /// @dev The second half of the fix. The operator never sends a revoke; `realign` renounces. That
    ///      removes the transaction that failed on Polygon.
    function test_roleIsRenouncedByRealignItself() public {
        vm.startPrank(ADMIN);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
        realigner.realign(assets, heartbeats);
        vm.stopPrank();
        assertFalse(NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner)), "realign did not renounce the role");
    }

    function hbOf(address a) internal view returns (uint256) {
        return NAVCalculator(NAV).getPriceFeedAt(a, 0).chainlinkHeartbeat;
    }

    /// @notice Without the role the realigner is inert — revert-probe for the grant/revoke bracket.
    function test_isInertWithoutTheRole() public {
        assertFalse(NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner)));
        vm.expectRevert();
        realigner.realign(assets, heartbeats);
    }

    /// @notice A batch where any asset fails leaves the WHOLE batch unapplied.
    /// @dev The property that makes a partial rollout unrepresentable. Re-running an already-applied asset
    ///      reverts NothingToRealign, so an accidental double-run cannot half-apply a chain either.
    function test_batchIsAllOrNothing() public {
        uint256[] memory bad = new uint256[](heartbeats.length);
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = heartbeats[i];
        }
        bad[bad.length - 1] = NAVCalculator(NAV).getPriceFeedAt(assets[bad.length - 1], 0).chainlinkHeartbeat;

        uint256 hb0 = NAVCalculator(NAV).getPriceFeedAt(assets[0], 0).chainlinkHeartbeat;
        vm.startPrank(ADMIN);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
        vm.expectRevert(abi.encodeWithSelector(HeartbeatRealigner.NothingToRealign.selector, assets[bad.length - 1]));
        realigner.realign(assets, bad);
        vm.stopPrank();

        assertEq(NAVCalculator(NAV).getPriceFeedAt(assets[0], 0).chainlinkHeartbeat, hb0, "first asset was mutated");
    }
}
