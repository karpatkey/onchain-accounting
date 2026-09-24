// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    CoinbaseStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/CoinbaseStakedEthWalletMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {
    WalletTokenMetaBalanceAdapterBase
} from "src/balances/MetaBalanceAdapters/WalletTokenMetaBalanceAdapterBase.sol";
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

/// @dev The default adapter's inclusion list, reporting nothing as included — the post-exclusion steady state,
///      which is the only state in which this family reports at all.
contract NothingIncludedStub {
    function isSupportedByDefault(address) external pure returns (bool) {
        return false;
    }
}

/// @title Wallet-yield family — mainnet fork parity
/// @author KPK
/// @notice Proves the claim the whole reclassification rests on, against REAL token contracts: the amount each
///         adapter reports is bit-identical to `balanceOf`, so moving a holding from `ERC20DefaultBalanceAdapter`
///         to its protocol adapter changes identity and NOTHING ELSE.
/// @dev **Why a fork test and not more unit tests.** The unit suite proves parity against `Mock_ERC20`, which is
///      a plain balance mapping. The tokens this family governs are not: stETH is REBASING and stores shares,
///      not balances, so `balanceOf` is a computed conversion; several others are proxies or ERC-4626 wrappers.
///      A conversion bug in the base would be invisible against a mock and would move NAV in production. This
///      reads the real contracts at a pinned block.
///
///      **One file, not seventeen.** The repo convention is a fork test per adapter, and every member here is a
///      thin subclass of one shared base that differs only in constants — so seventeen files would re-test the
///      same code path seventeen times while each covering one token. This covers 22 token/adapter pairs across
///      16 adapters in one fork, which is strictly more coverage than the convention asks for. The per-adapter
///      identity assertions live next door in the unit table.
///
///      **Real holders where they exist.** Eleven pairs assert against balances the fund's own integration
///      accounts actually held at the pinned block, including two dust balances of 1 wei — kept deliberately,
///      because 1 wei is where a rounding conversion would show up first. The rest are dealt a balance, and
///      every case asserts `balanceOf > 0` BEFORE asserting parity so a token whose storage `deal` cannot reach
///      fails loudly instead of passing vacuously on an empty leg.
contract WalletYieldFamilyForkParityTest is TestEnvConfigurator {
    uint256 internal constant FORK_BLOCK = 26_040_000;

    Mock_NAVCalculator internal nav;

    struct Case {
        address adapter;
        address token;
        PositionKind kind;
        address holder; // address(0) => synthesise a balance with `deal`
        string label;
    }

    Case[] internal cases;

    function setUp() public {
        // The repo's fork helper, not a raw `vm.envString("MAINNET_URL")`: `getAlchemyUrl` is what resolves
        // an RPC in CI, and the `WithCadence` variant is what throttles under `FOUNDRY_PROFILE=slow`.
        // It must be the SELECT variant — `createForkWithCadence` creates a fork without selecting it.
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        nav = new Mock_NAVCalculator();
        // Armed BEFORE any adapter is constructed: `ERC20_DEFAULT_ADAPTER` is immutable, so an adapter built
        // while the mock still answers address(0) would be permanently disarmed.
        nav.setErc20DefaultBalanceAdapter(address(new NothingIncludedStub()));
        _case(
            address(new LidoStakedEthWalletMetaBalanceAdapter(address(nav))),
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            PositionKind.Staking,
            0x408ea1bC71ec2562ABCB27520cf7077718403496,
            "LidoStakedEth/wstETH"
        );
        _case(
            address(new LidoStakedEthWalletMetaBalanceAdapter(address(nav))),
            0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84,
            PositionKind.Staking,
            0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89,
            "LidoStakedEth/stETH"
        );
        _case(
            address(new StaderStakedEthWalletMetaBalanceAdapter(address(nav))),
            0xA35b1B31Ce002FBF2058D22F30f95D405200A15b,
            PositionKind.Staking,
            0x4F2083f5fBede34C2714aFfb3105539775f7FE64,
            "StaderStakedEth/ETHx"
        );
        _case(
            address(new AnkrStakedEthWalletMetaBalanceAdapter(address(nav))),
            0xE95A203B1a91a908F9B9CE46459d101078c2c3cb,
            PositionKind.Staking,
            address(0),
            "AnkrStakedEth/ankrETH"
        );
        _case(
            address(new EtherFiStakedEthWalletMetaBalanceAdapter(address(nav))),
            0x35fA164735182de50811E8e2E824cFb9B6118ac2,
            PositionKind.Staking,
            0x4F2083f5fBede34C2714aFfb3105539775f7FE64,
            "EtherFiStakedEth/eETH"
        );
        _case(
            address(new EtherFiStakedEthWalletMetaBalanceAdapter(address(nav))),
            0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee,
            PositionKind.Staking,
            0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89,
            "EtherFiStakedEth/weETH"
        );
        _case(
            address(new RenzoRestakedEthWalletMetaBalanceAdapter(address(nav))),
            0xbf5495Efe5DB9ce00f80364C8B423567e58d2110,
            PositionKind.Staking,
            address(0),
            "RenzoRestakedEth/ezETH"
        );
        _case(
            address(new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(address(nav))),
            0x8c1BEd5b9a0928467c9B1341Da1D7BD5e10b6549,
            PositionKind.Staking,
            address(0),
            "LiquidCollectiveStakedEth/lsETH"
        );
        _case(
            address(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(address(nav))),
            0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38,
            PositionKind.Staking,
            address(0),
            "StakeWiseV3OsToken/osETH"
        );
        _case(
            address(new RocketPoolStakedEthWalletMetaBalanceAdapter(address(nav))),
            0xae78736Cd615f374D3085123A210448E74Fc6393,
            PositionKind.Staking,
            0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89,
            "RocketPoolStakedEth/rETH"
        );
        _case(
            address(new KelpRestakedEthWalletMetaBalanceAdapter(address(nav))),
            0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7,
            PositionKind.Staking,
            0x408ea1bC71ec2562ABCB27520cf7077718403496,
            "KelpRestakedEth/rsETH"
        );
        _case(
            address(new SkySavingsWalletMetaBalanceAdapter(address(nav))),
            0x83F20F44975D03b1b09e64809B757c47f942BEeA,
            PositionKind.Supplied,
            address(0),
            "SkySavings/sDAI"
        );
        _case(
            address(new SkySavingsWalletMetaBalanceAdapter(address(nav))),
            0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD,
            PositionKind.Supplied,
            0x4F2083f5fBede34C2714aFfb3105539775f7FE64,
            "SkySavings/sUSDS"
        );
        _case(
            address(new AaveSavingsWalletMetaBalanceAdapter(address(nav))),
            0xE1753F2e00940cC31213dd92013cF019DFE4ca1d,
            PositionKind.Supplied,
            0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89,
            "AaveSavings/sGHO"
        );
        _case(
            address(new EthenaSavingsWalletMetaBalanceAdapter(address(nav))),
            0x9D39A5DE30e57443BfF2A8307A4256c8797A3497,
            PositionKind.Staking,
            0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6,
            "EthenaSavings/sUSDe"
        );
        _case(
            address(new SparkSavingsWalletMetaBalanceAdapter(address(nav))),
            0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f,
            PositionKind.Supplied,
            address(0),
            "SparkSavings/spETH"
        );
        _case(
            address(new SparkSavingsWalletMetaBalanceAdapter(address(nav))),
            0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d,
            PositionKind.Supplied,
            address(0),
            "SparkSavings/spUSDC"
        );
        _case(
            address(new SparkSavingsWalletMetaBalanceAdapter(address(nav))),
            0xe2e7a17dFf93280dec073C995595155283e3C372,
            PositionKind.Supplied,
            address(0),
            "SparkSavings/spUSDT"
        );
        _case(
            address(new MapleSavingsWalletMetaBalanceAdapter(address(nav))),
            0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b,
            PositionKind.Supplied,
            address(0),
            "MapleSavings/syrupUSDC"
        );
        _case(
            address(new MapleSavingsWalletMetaBalanceAdapter(address(nav))),
            0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D,
            PositionKind.Supplied,
            0x530Bfd7DE5D63329E2DF996cf5afB2616524936D,
            "MapleSavings/syrupUSDT"
        );
        _case(
            address(new ReserveBasketsWalletMetaBalanceAdapter(address(nav))),
            0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8,
            PositionKind.Supplied,
            address(0),
            "ReserveBaskets/ETH+"
        );
        _case(
            address(new NexusMutualVaultsWalletMetaBalanceAdapter(address(nav))),
            0xcAFeAA466736ac01e0AC9Ca72644beF348694731,
            PositionKind.Supplied,
            address(0),
            "NexusMutualVaults/RWIV"
        );
        for (uint256 i; i < cases.length; ++i) {
            nav.registerAssetFromERC20(cases[i].token);
        }
    }

    function _case(address adapter, address token, PositionKind kind, address holder, string memory label) internal {
        cases.push(Case({adapter: adapter, token: token, kind: kind, holder: holder, label: label}));
    }

    function _ins(address token) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(token)));
    }

    /// @notice Every pair reports exactly `balanceOf`, against the real token contract.
    function test_everyPairMatchesBalanceOfExactly() public {
        uint256 covered;
        for (uint256 i; i < cases.length; ++i) {
            Case memory c = cases[i];
            address account = c.holder;
            if (account == address(0)) {
                account = address(uint160(0xBEEF0000 + i));
                deal(c.token, account, 1234e6, true);
            }

            uint256 bal = IERC20(c.token).balanceOf(account);
            assertGt(bal, 0, string.concat(c.label, ": no balance to test; this case would pass vacuously"));

            INAVCalculator.PositionBalance[] memory p = WalletTokenMetaBalanceAdapterBase(c.adapter)
                .getAdapterPositionsForInstances(account, _ins(c.token), address(0));

            assertEq(p.length, 1, string.concat(c.label, ": expected exactly one leg"));
            assertEq(p[0].amount, bal, string.concat(c.label, ": amount must equal balanceOf EXACTLY"));
            assertEq(p[0].balanceAsset.asset, c.token, string.concat(c.label, ": balanceAsset must be the token"));
            assertFalse(p[0].isDebt, string.concat(c.label, ": must never be debt"));
            assertEq(
                uint256(uint8(p[0].positionKind)),
                uint256(uint8(c.kind)),
                string.concat(c.label, ": positionKind changed")
            );
            ++covered;
        }
        // A floor, so the suite cannot silently shrink to nothing if a token stops resolving.
        assertEq(covered, cases.length, "not every case was exercised");
        assertGe(cases.length, 22, "coverage shrank: a token/adapter pair was dropped");
    }

    /// @notice A zero balance drops the leg rather than emitting a zero-amount position.
    /// @dev Asserted on the real contracts because an ERC-4626 wrapper can return a non-zero `convertToAssets`
    ///      for a zero share balance; the family must key on the raw balance.
    function test_zeroBalanceEmitsNothing() public view {
        address empty = address(uint160(0xDEAD0001));
        for (uint256 i; i < cases.length; ++i) {
            Case memory c = cases[i];
            if (IERC20(c.token).balanceOf(empty) != 0) continue;
            INAVCalculator.PositionBalance[] memory p = WalletTokenMetaBalanceAdapterBase(c.adapter)
                .getAdapterPositionsForInstances(empty, _ins(c.token), address(0));
            assertEq(p.length, 0, string.concat(c.label, ": zero balance must emit no leg"));
        }
    }
}

/// @title cbETH wallet-yield parity, on BASE
/// @notice The 17th family member, which the mainnet table above structurally cannot cover.
/// @dev **Why this is a separate contract rather than another `_case` row.** The parity table above forks
///      eth-mainnet, and `CoinbaseStakedEthWalletMetaBalanceAdapter` is the one family member enabled ONLY on
///      Base (`script/config/nav-config/meta-balance-adapters/8453.json`). A mainnet row would therefore test a
///      configuration that is not deployed anywhere, which is worse than no row: it would satisfy the
///      per-adapter fork-coverage rule while asserting nothing about the chain the adapter actually runs on.
///      So this takes a second fork context, and cbETH is asserted against its real Base address.
///
///      The block is `chains.8453.forkBlock` from `test/integration/accounts.json` — the same pin the
///      integration suite uses — so a snapshot refresh moves this test with it rather than leaving a second,
///      independently-rotting block constant in the tree.
contract CoinbaseStakedEthWalletBaseForkTest is TestEnvConfigurator {
    /// @dev `chains.8453.forkBlock` in `test/integration/accounts.json`.
    uint256 internal constant BASE_FORK_BLOCK = 49_853_005;

    /// @dev cbETH on Base, from the `CoinbaseStakedEthWalletMeta` instance list in `8453.json`.
    address internal constant CBETH_BASE = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

    Mock_NAVCalculator internal nav;
    CoinbaseStakedEthWalletMetaBalanceAdapter internal adapter;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("base-mainnet"), BASE_FORK_BLOCK);
        nav = new Mock_NAVCalculator();
        // Armed BEFORE the adapter is constructed: `ERC20_DEFAULT_ADAPTER` is immutable, so an adapter built
        // while the mock still answers address(0) would be permanently disarmed.
        nav.setErc20DefaultBalanceAdapter(address(new NothingIncludedStub()));
        adapter = new CoinbaseStakedEthWalletMetaBalanceAdapter(address(nav));
        // REQUIRED, and its absence is a silent empty leg rather than a revert: the family skips any token the
        // NAV does not report as a registered asset, so without this the parity assertion below fails with
        // "expected exactly one leg: 0 != 1" and nothing says why. The mainnet table above does the same thing
        // per case.
        nav.registerAssetFromERC20(CBETH_BASE);
    }

    function _ins() internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(CBETH_BASE)));
    }

    /// @notice The reported amount is the raw `balanceOf`, exactly, with the reclassified identity.
    function test_cbEthOnBase_matchesBalanceOfExactly() public {
        address account = address(uint160(0xCB27));
        deal(CBETH_BASE, account, 3.5 ether, true);

        uint256 bal = IERC20(CBETH_BASE).balanceOf(account);
        // Asserted BEFORE parity, so a `deal` that cannot reach this token's storage fails loudly instead of
        // passing vacuously against an empty leg — the same guard the mainnet table uses.
        assertGt(bal, 0, "cbETH: no balance to test; this case would pass vacuously");

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(account, _ins(), address(0));

        assertEq(p.length, 1, "cbETH: expected exactly one leg");
        assertEq(p[0].amount, bal, "cbETH: amount must equal balanceOf EXACTLY");
        assertEq(p[0].balanceAsset.asset, CBETH_BASE, "cbETH: balanceAsset must be the token itself");
        assertFalse(p[0].isDebt, "cbETH: must never be debt");
        assertEq(uint256(uint8(p[0].positionKind)), uint256(uint8(PositionKind.Staking)), "cbETH: kind must be Staking");
        assertEq(p[0].balanceAdapter, address(adapter), "cbETH: balanceAdapter must be address(this)");
    }

    /// @notice A zero balance drops the leg rather than emitting a zero-amount position.
    /// @dev The probe address is KECCAK-DERIVED, not `0x…dEaD`. The first version used the burn address and
    ///      failed with "1 != 0" — because on Base that address really does hold cbETH, so the test was
    ///      measuring a live balance rather than an empty one. The mainnet table sidesteps this by `continue`-ing
    ///      past any non-empty address, which is fine across 22 cases but would make a single-case test silently
    ///      vacuous. So instead: derive an address nothing can hold, and ASSERT it is empty first, so a future
    ///      collision fails loudly and names the reason instead of looking like a broken adapter.
    function test_cbEthOnBase_zeroBalanceEmitsNothing() public view {
        address empty = address(uint160(uint256(keccak256("cbETH-empty-probe"))));
        assertEq(IERC20(CBETH_BASE).balanceOf(empty), 0, "probe address unexpectedly holds cbETH; pick another");

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositionsForInstances(empty, _ins(), address(0));
        assertEq(p.length, 0, "cbETH: a zero balance must emit no leg at all");
    }
}
