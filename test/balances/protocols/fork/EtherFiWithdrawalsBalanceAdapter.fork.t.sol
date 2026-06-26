// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalsBalanceAdapter,
    IEtherFiWithdrawRequestNFT,
    IEtherFiLiquidityPool
} from "src/balances/protocols/EtherFiWithdrawalsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title EtherFiWithdrawalsBalanceAdapterForkTest
/// @notice Fork test against ether.fi's real WithdrawRequestNFT + LiquidityPool on mainnet.
/// @dev The NFT isn't enumerable, so the agent (here, the test acting as owner) submits a real tokenId; the
///      adapter values it entirely from live on-chain reads. Holder 0xcFFab3… owns request #80154 at FORK_BLOCK
///      (pending, isValid, fee 0), worth `min(amountOfEEth, amountForShare(shareOfEEth)) − fee` ETH. The test
///      asserts the adapter both against the pinned value AND against an independent live read (delta 0).
contract EtherFiWithdrawalsBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address public constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    /// @dev ERC-7528 native-ETH sentinel — what ether.fi pays on claim and how the adapter denominates.
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public constant FORK_BLOCK = 25_387_000;

    address public constant HOLDER = 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4;
    uint256 public constant TOKEN_ID = 80_154;
    uint256 public constant EXPECTED_ETH = 253_077_459_762_665_832; // ~0.2531 ETH, pending estimate at FORK_BLOCK

    EtherFiWithdrawalsBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();

        // Native ETH registered directly (the codeless sentinel can't be probed for decimals()/symbol()).
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");

        // owner = this test, so it plays the agent and submits the real tokenId.
        adapter = new EtherFiWithdrawalsBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this)
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
        // Sanity: the request is the state we pinned against.
        assertEq(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(TOKEN_ID), HOLDER, "owner mismatch");
        assertFalse(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).isFinalized(TOKEN_ID), "should be pending");

        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ID;
        adapter.submitTokenIds(HOLDER, ids);

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, _liveOwed(TOKEN_ID), "adapter must equal an independent live read (delta 0)");
        assertEq(amount, EXPECTED_ETH, "adapter must equal the pinned value");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_identity() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ID;
        adapter.submitTokenIds(HOLDER, ids);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, EXPECTED_ETH);
        assertEq(p[0].balanceAsset.asset, NATIVE_ETH);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].protocolId, ProtocolIds.ETHERFI_WITHDRAWAL);
        assertEq(p[0].positionId.length, 0);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isDebt);
    }

    // ---- Negative cases against the real contracts ----

    function test_unsubmitted_reportsZero() public view {
        // Adapter only reports cached ids; without a submission there is nothing to value.
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0);
    }

    function test_submit_skipsIdNotOwnedByAccount() public {
        // Submitting HOLDER's real id under a different account is rejected at write (ownerOf != account).
        address stranger = makeAddr("stranger");
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ID;
        adapter.submitTokenIds(stranger, ids);
        assertEq(adapter.tokenIdsOf(stranger).length, 0);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(stranger, NATIVE_ETH);
        assertEq(amount, 0);
    }
}
