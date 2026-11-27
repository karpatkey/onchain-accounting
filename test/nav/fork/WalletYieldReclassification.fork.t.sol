// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {
    AaveSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AaveSavingsWalletMetaBalanceAdapter.sol";
import {
    AnkrStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AnkrStakedEthWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";
import {
    EtherFiStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EtherFiStakedEthWalletMetaBalanceAdapter.sol";
import {
    KelpRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/KelpRestakedEthWalletMetaBalanceAdapter.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    LiquidCollectiveStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LiquidCollectiveStakedEthWalletMetaBalanceAdapter.sol";
import {
    MapleSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/MapleSavingsWalletMetaBalanceAdapter.sol";
import {
    NexusMutualVaultsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/NexusMutualVaultsWalletMetaBalanceAdapter.sol";
import {
    RenzoRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RenzoRestakedEthWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    RocketPoolStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RocketPoolStakedEthWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    SparkSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SparkSavingsWalletMetaBalanceAdapter.sol";
import {
    StaderStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StaderStakedEthWalletMetaBalanceAdapter.sol";
import {
    StakeWiseV3OsTokenWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StakeWiseV3OsTokenWalletMetaBalanceAdapter.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title Wallet-yield reclassification — end-to-end value neutrality and gas, on real mainnet state
/// @author KPK
/// @notice Upgrades the LIVE proxy on a fork, registers all 16 chain-1 wallet-yield adapters with their 23
///         coordinates, and asserts the account's NAV is UNCHANGED to the wei while its position identities
///         change. Also reports the read-gas delta.
/// @dev This is the test the PR was missing, and it closes two recorded gaps at once.
///
///      **Why it is stronger than the per-adapter parity test.** That one proves each adapter reports exactly
///      `balanceOf` for one token in isolation. It cannot see the thing that actually determines whether NAV
///      moves: that claiming a coordinate DISARMS `ERC20DefaultBalanceAdapter` for it, so the holding is
///      reported once afterwards rather than twice or zero times. Only a whole-NAV read over real state with
///      real prices can witness that, and only against the UPGRADED implementation — the live proxy runs code
///      without the claimant map, where `addMetaInstances` does not disarm anything.
///
///      **Why the gas figure needed measuring.** The 17 adapters add instances to a single-call fan-out on a
///      chain whose full read already needs slicing, and the PR shipped no number. The offsetting saving is
///      real but was also unmeasured: every reclassified token leaves `ERC20DefaultBalanceAdapter`'s inclusion
///      list, and that adapter costs roughly 585k gas per registered asset. This prints both sides.
contract WalletYieldReclassificationForkTest is TestEnvConfigurator {
    address internal constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    /// @dev Holds both roles on chain 1 — a recorded decision, not a gap (see ADR 0025 rollout notes).
    address internal constant ADMIN_AND_MANAGER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    bytes32 internal constant MANAGER = keccak256("MANAGER");

    /// @dev An integration account measured to hold stETH, weETH, rETH and sGHO at this block — i.e. four of
    ///      the reclassified tokens across four different adapters, which is what makes the read meaningful.
    address internal constant ACCOUNT = 0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89;
    uint256 internal constant FORK_BLOCK = 26_040_000;

    bytes32[] internal _coords;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);

        // ETCH BOTH LIBRARIES WITH THIS TREE'S CODE, or this test silently measures the wrong thing.
        // `NAVRegistryLib` and `PriceFeedLib` are pre-linked at deterministic CREATE2 addresses. Where a pin
        // still equals the live address (NAVRegistryLib today), the fork holds the live code there, and an
        // implementation compiled here would DELEGATECALL it; etching puts this tree's logic behind it. Where
        // the pin has moved off the live address (PriceFeedLib since ADR 0029), the etch lands on an empty
        // address only the NEW implementation links to, so step 1's baseline runs the live PriceFeedLib and
        // step 2 is a real old-engine -> new-engine comparison.
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
    }

    function _register(address adapter, bytes32[] memory coords) internal {
        vm.startPrank(ADMIN_AND_MANAGER);
        NAVCalculator(NAV).addMetaBalanceAdapter(adapter, coords);
        vm.stopPrank();
    }

    function _nav() internal view returns (int256) {
        return NAVCalculator(NAV).getAccountNav(ACCOUNT, address(0)).value;
    }

    /// @notice NAV is identical before and after the whole reclassification; only identity moves.
    function test_reclassification_isValueNeutral_endToEnd() public {
        // 1. Baseline on the live implementation.
        uint256 g0 = gasleft();
        int256 before = _nav();
        uint256 gasBefore = g0 - gasleft();
        INAVCalculator.Asset[] memory staleBefore =
        NAVCalculator(NAV).getAccountNav(ACCOUNT, address(0)).stalePriceAssets;
        assertGt(before, 0, "precondition: the account must hold something priced");

        // 2. Upgrade the proxy. This alone must not move any FRESH valuation — if it does, the upgrade is not safe
        //    and nothing after this point is interpretable. Since ADR 0029 a STALE asset keeps its last price
        //    instead of pricing at 0, and at this block 17 assets (ETH/WETH and the ETH-based LSTs) are stale, so
        //    the total legitimately rises. The invariant that survives: the non-stale positions sum to exactly the
        //    old NAV (the old engine valued every stale leg at 0).
        address newImpl = address(new NAVCalculator());
        vm.prank(ADMIN_AND_MANAGER);
        IUUPS(NAV).upgradeToAndCall(newImpl, "");
        INAVCalculator.Position[] memory upgraded = NAVCalculator(NAV).getAccountPositions(ACCOUNT, address(0));
        int256 freshSum;
        for (uint256 i; i < upgraded.length; ++i) {
            if (!upgraded[i].stale) {
                freshSum += upgraded[i].value;
            } else {
                // A stale leg is valued at exactly the price the selector reports for it (or 0 if none usable).
                assertEq(
                    upgraded[i].price,
                    NAVCalculator(NAV).getPriceData(upgraded[i].balanceAsset.asset).price,
                    "a stale leg is priced at the selected (stale) price"
                );
            }
        }
        assertEq(freshSum, before, "the upgrade alone must not change any fresh valuation");
        // Freshness classification is unchanged by ADR 0029, so the stale set must be identical.
        INAVCalculator.Asset[] memory staleAfter =
        NAVCalculator(NAV).getAccountNav(ACCOUNT, address(0)).stalePriceAssets;
        assertEq(staleAfter.length, staleBefore.length, "the upgrade must not change the stale set");
        for (uint256 i; i < staleAfter.length; ++i) {
            assertEq(staleAfter[i].asset, staleBefore[i].asset, "the upgrade must not change the stale set");
        }
        // The reclassification below is measured against the post-upgrade NAV.
        before = _nav();

        // 3. Register all 16 adapters with their 23 coordinates. Each claim disarms the default adapter for
        //    that token in the same transaction.
        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d))));
        _register(address(new AaveSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE95A203B1a91a908F9B9CE46459d101078c2c3cb))));
        _register(address(new AnkrStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497))));
        _register(address(new EthenaSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x35fA164735182de50811E8e2E824cFb9B6118ac2))));
        _coords.push(bytes32(uint256(uint160(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee))));
        _register(address(new EtherFiStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7))));
        _register(address(new KelpRestakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0))));
        _coords.push(bytes32(uint256(uint160(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84))));
        _register(address(new LidoStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x8c1BEd5b9a0928467c9B1341Da1D7BD5e10b6549))));
        _register(address(new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b))));
        _coords.push(bytes32(uint256(uint160(0x87b65C4aAFFA76881f9E96F3e7ED945ddFC3Cd7A))));
        _coords.push(bytes32(uint256(uint160(0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D))));
        _register(address(new MapleSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xcAFeAA466736ac01e0AC9Ca72644beF348694731))));
        _register(address(new NexusMutualVaultsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110))));
        _register(address(new RenzoRestakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8))));
        _register(address(new ReserveBasketsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xae78736Cd615f374D3085123A210448E74Fc6393))));
        _register(address(new RocketPoolStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x83F20F44975D03b1b09e64809B757c47f942BEeA))));
        _coords.push(bytes32(uint256(uint160(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD))));
        _register(address(new SkySavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f))));
        _coords.push(bytes32(uint256(uint160(0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d))));
        _coords.push(bytes32(uint256(uint160(0xe2e7a17dFf93280dec073C995595155283e3C372))));
        _register(address(new SparkSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xA35b1B31Ce002FBF2058D22F30f95D405200A15b))));
        _register(address(new StaderStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38))));
        _register(address(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(NAV)), _coords);

        // 4. The claim. Same wei, and the read still works.
        uint256 g1 = gasleft();
        int256 afterNav = _nav();
        uint256 gasAfter = g1 - gasleft();

        assertEq(afterNav, before, "reclassification must not change NAV by a single wei");

        emit log_named_int("nav (unchanged)", before);
        emit log_named_uint("getAccountNav gas BEFORE", gasBefore);
        emit log_named_uint("getAccountNav gas AFTER ", gasAfter);
        if (gasAfter > gasBefore) {
            emit log_named_uint("gas INCREASE", gasAfter - gasBefore);
        } else {
            emit log_named_uint("gas SAVING", gasBefore - gasAfter);
        }
    }

    /// @notice After reclassification no holding is reported twice, and the reclassified ones are no longer
    ///         `Wallet`.
    /// @dev The identity half of the same event. Value neutrality alone would also hold if a token were
    ///      reported twice at half value or not at all, so the count and the kind have to be checked too.
    function test_reclassification_movesIdentityWithoutDuplicating() public {
        address newImpl = address(new NAVCalculator());
        vm.prank(ADMIN_AND_MANAGER);
        IUUPS(NAV).upgradeToAndCall(newImpl, "");

        INAVCalculator.Position[] memory pre = NAVCalculator(NAV).getAccountPositions(ACCOUNT, address(0));

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d))));
        _register(address(new AaveSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE95A203B1a91a908F9B9CE46459d101078c2c3cb))));
        _register(address(new AnkrStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497))));
        _register(address(new EthenaSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x35fA164735182de50811E8e2E824cFb9B6118ac2))));
        _coords.push(bytes32(uint256(uint160(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee))));
        _register(address(new EtherFiStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7))));
        _register(address(new KelpRestakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0))));
        _coords.push(bytes32(uint256(uint160(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84))));
        _register(address(new LidoStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x8c1BEd5b9a0928467c9B1341Da1D7BD5e10b6549))));
        _register(address(new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b))));
        _coords.push(bytes32(uint256(uint160(0x87b65C4aAFFA76881f9E96F3e7ED945ddFC3Cd7A))));
        _coords.push(bytes32(uint256(uint160(0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D))));
        _register(address(new MapleSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xcAFeAA466736ac01e0AC9Ca72644beF348694731))));
        _register(address(new NexusMutualVaultsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110))));
        _register(address(new RenzoRestakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8))));
        _register(address(new ReserveBasketsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xae78736Cd615f374D3085123A210448E74Fc6393))));
        _register(address(new RocketPoolStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0x83F20F44975D03b1b09e64809B757c47f942BEeA))));
        _coords.push(bytes32(uint256(uint160(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD))));
        _register(address(new SkySavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f))));
        _coords.push(bytes32(uint256(uint160(0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d))));
        _coords.push(bytes32(uint256(uint160(0xe2e7a17dFf93280dec073C995595155283e3C372))));
        _register(address(new SparkSavingsWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xA35b1B31Ce002FBF2058D22F30f95D405200A15b))));
        _register(address(new StaderStakedEthWalletMetaBalanceAdapter(NAV)), _coords);

        _coords = new bytes32[](0);
        _coords.push(bytes32(uint256(uint160(0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38))));
        _register(address(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(NAV)), _coords);

        INAVCalculator.Position[] memory post = NAVCalculator(NAV).getAccountPositions(ACCOUNT, address(0));

        // No stable key shared across DIFFERENT adapters — that, not "no shared key at all", is the
        // double-count shape. `positionInstanceId` is deliberately excluded from the stable identity key
        // (docs/howto/position-identity-schema.md) exactly so that N per-item rows from ONE adapter aggregate
        // into one reconciliation row, so two such rows sharing the key is correct behaviour.
        //
        // Measured before writing this: at this block the account ALREADY has 2 such pairs, both from the same
        // adapter (0xACdC33b6…) and differing only in `positionInstanceId`. A first version of this assertion
        // forbade any shared key and failed on that pre-existing, legitimate state — it would have been
        // reported as a defect in the reclassification, which it is not.
        for (uint256 i; i < post.length; ++i) {
            for (uint256 j = i + 1; j < post.length; ++j) {
                if (post[i].balanceAdapter == post[j].balanceAdapter) continue;
                bool same = post[i].balanceAsset.asset == post[j].balanceAsset.asset
                    && post[i].protocolSubId == post[j].protocolSubId && post[i].positionKind == post[j].positionKind
                    && keccak256(post[i].positionId) == keccak256(post[j].positionId);
                assertTrue(!same, "TWO ADAPTERS report one holding under the same reconciliation key");
            }
        }

        // The same number of legs, or more (an adapter may split a holding into legs); never fewer, which
        // would mean a holding stopped being reported.
        assertGe(post.length, pre.length, "reclassification must not drop a position");
        emit log_named_uint("positions before", pre.length);
        emit log_named_uint("positions after ", post.length);
    }
}
