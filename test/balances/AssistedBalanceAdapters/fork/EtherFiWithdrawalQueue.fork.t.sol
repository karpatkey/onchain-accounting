// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    IEtherFiWithdrawRequestNFT,
    IEtherFiLiquidityPool
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NotTokenOwner} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title EtherFiWithdrawalQueueAssistedBalanceAdapter (wrapper-fed) fork test
/// @notice Fork test against ether.fi's real WithdrawRequestNFT + LiquidityPool on mainnet.
/// @dev The NFT isn't enumerable, so the wrapper (here, the test acting as the `WRAPPER_ROLE` holder) submits a real
///      tokenId; the adapter values it entirely from live on-chain reads. Holder 0xcFFab3… owns request #80154 at
///      FORK_BLOCK (pending, isValid, fee 0), worth `min(amountOfEEth, amountForShare(shareOfEEth)) − fee` ETH. The
///      valuation math is identical to the assistant-fed sibling; only the feeder differs.
contract EtherFiWithdrawalQueueAssistedBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address public constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    /// @dev ERC-7528 native-ETH sentinel — what ether.fi pays on claim and how the adapter denominates.
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public constant FORK_BLOCK = 25_387_000;

    address public constant HOLDER = 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4;
    uint256 public constant TOKEN_ID = 80_154;
    uint256 public constant EXPECTED_ETH = 253_077_459_762_665_832; // ~0.2531 ETH, pending estimate at FORK_BLOCK

    EtherFiWithdrawalQueueAssistedBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");

        // admin = wrapper = this test, so it plays the wrapper and submits the real tokenId.
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this), address(this)
        );
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Independent live recompute of the same request, mirroring ether.fi's claim math.
    function _liveOwed(uint256 tokenId) internal view returns (uint256) {
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory r =
            IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).getRequest(tokenId);
        uint256 byShare = IEtherFiLiquidityPool(LIQUIDITY_POOL).amountForShare(r.shareOfEEth);
        uint256 gross = uint256(r.amountOfEEth) < byShare ? uint256(r.amountOfEEth) : byShare;
        uint256 fee = uint256(r.feeGwei) * 1 gwei;
        return gross > fee ? gross - fee : 0;
    }

    // ---- Real pending request: strict equality vs live read + pinned value ----

    function test_realHolder_pendingValuation() public {
        assertEq(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(TOKEN_ID), HOLDER, "owner mismatch");
        assertFalse(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).isFinalized(TOKEN_ID), "should be pending");

        // Before: the request exists on-chain but is not tracked, so the adapter reports 0.
        (uint256 before_,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(before_, 0, "adapter reports 0 before the id is submitted");
        assertEq(adapter.tokenIdsOf(HOLDER).length, 0, "nothing tracked before");

        adapter.submit(HOLDER, TOKEN_ID);

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, _liveOwed(TOKEN_ID), "adapter must equal an independent live read (delta 0)");
        assertEq(amount, EXPECTED_ETH, "adapter must equal the pinned value");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_identity() public {
        // Before: no legs reported for the holder.
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0, "no legs before submit");

        adapter.submit(HOLDER, TOKEN_ID);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertGe(p.length, 1);
        bytes memory expectedId = abi.encode(adapter.WITHDRAW_REQUEST_NFT());
        uint256 sum;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, NATIVE_ETH);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolSubId, ProtocolIds.ETHERFI_WITHDRAWAL);
            assertEq(p[i].protocolId, ProtocolIds.ETHERFI);
            assertEq(p[i].positionId, expectedId, "static positionId shared across per-request legs");
            assertEq(uint8(p[i].positionKind), uint8(PositionKind.Supplied));
            assertFalse(p[i].isDebt);
            assertTrue(p[i].isLocked, "request #80154 is pending -> locked leg");
            _assertRequestLeg(p[i]);
            sum += p[i].amount;
        }
        assertEq(sum, EXPECTED_ETH, "per-request legs sum to the aggregate total");
    }

    function _assertRequestLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 2, "static breadcrumb = [category, symbol]");
        assertEq(labels[0], "Withdrawal Queue");
        assertEq(labels[1], "eETH");
        assertTrue(leg.positionInstanceId != bytes32(0), "positionInstanceId carries the tokenId");
    }

    // ---- Negative cases against the real contracts ----

    function test_unsubmitted_reportsZero() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0);
    }

    function test_submit_revertsOnIdNotOwnedByAccount() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, stranger, TOKEN_ID));
        adapter.submit(stranger, TOKEN_ID);
        assertEq(adapter.tokenIdsOf(stranger).length, 0);
    }
}
