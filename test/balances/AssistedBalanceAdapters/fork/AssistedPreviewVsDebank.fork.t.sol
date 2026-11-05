// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title previewPositions vs DeBank, for real holders
/// @notice Reads `assisted-preview-debank.json` (written by `script/test/assisted-debank-snapshot.py`: DeBank's live
///         amounts and the holders' live coordinates at one block), forks that block, deploys fresh adapters and checks
///         that `previewPositions(holder, coords)` sums to DeBank's amount within {TOLERANCE_BPS}. Covers the ether.fi
///         withdrawal queue ("Locked / Withdraw Request") and Nexus Mutual staking ("Staked", stake + rewards). StakeWise
///         exit positions are not reported by DeBank; they are pinned against the vault's own reads in the
///         per-adapter fork tests.
contract AssistedPreviewVsDebankForkTest is BalanceAdapterTestBase {
    string internal constant FIXTURE = "test/integration/assisted-preview-debank.json";
    uint256 internal constant TOLERANCE_BPS = 50; // 0.5%; DeBank is read seconds before the pinned block, and any state
    // change in that window fails loudly (never silently)

    address internal constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address internal constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address internal constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address internal constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    string internal json;

    function setUp() public override {
        json = vm.readFile(FIXTURE);
        super.setUp();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(vm.parseJsonUint(json, ".block"));
    }

    function _coords(uint256[] memory ids) internal pure returns (bytes memory) {
        bytes[] memory coords = new bytes[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            coords[i] = abi.encode(ids[i]);
        }
        return abi.encode(coords);
    }

    function _sum(INAVCalculator.PositionBalance[] memory legs) internal pure returns (uint256 total) {
        for (uint256 i; i < legs.length; ++i) {
            total += legs[i].amount;
        }
    }

    function test_previewPositions_matchesDebank() public {
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        balances.registerAssetForTest(NXM, 18, "NXM");
        IAssistedBalanceAdapter etherfi = IAssistedBalanceAdapter(
            address(
                new EtherFiWithdrawalQueueAssistedBalanceAdapter(
                    WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this)
                )
            )
        );
        IAssistedBalanceAdapter nexus = IAssistedBalanceAdapter(
            address(
                new NexusMutualStakingPoolsAssistedBalanceAdapter(
                    STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
                )
            )
        );

        uint256 n;
        uint256 etherfiCases;
        uint256 nexusCases;
        while (vm.keyExistsJson(json, string.concat(".cases[", vm.toString(n), "]"))) {
            string memory key = string.concat(".cases[", vm.toString(n), "]");
            string memory member = vm.parseJsonString(json, string.concat(key, ".member"));
            address holder = vm.parseJsonAddress(json, string.concat(key, ".holder"));
            uint256[] memory ids = vm.parseJsonUintArray(json, string.concat(key, ".ids"));
            uint256 expected = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".debankWei")));

            bool isEtherfi = keccak256(bytes(member)) == keccak256("etherfi");
            if (isEtherfi) ++etherfiCases;
            else ++nexusCases;
            IAssistedBalanceAdapter a = isEtherfi ? etherfi : nexus;
            uint256 got = _sum(a.previewPositions(holder, _coords(ids)));
            uint256 diff = got > expected ? got - expected : expected - got;
            emit log_named_uint(string.concat(member, " diff (1e-6 of DeBank)"), diff * 1e6 / expected);
            assertLe(
                diff * 10_000,
                expected * TOLERANCE_BPS,
                string.concat(
                    member,
                    " ",
                    vm.toString(holder),
                    ": preview ",
                    vm.toString(got),
                    " vs DeBank ",
                    vm.toString(expected)
                )
            );
            ++n;
        }
        assertGt(etherfiCases, 0, "fixture has ether.fi cases");
        assertGt(nexusCases, 0, "fixture has Nexus cases");
    }
}
