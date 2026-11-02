// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    IEtherFiWithdrawRequestNFT,
    IEtherFiLiquidityPool
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice ERC721 transfer surface of ether.fi's WithdrawRequestNFT (for seeding a real finalized request into the
///         test Safe in the claim test).
interface IWithdrawRequestNFTTransfer {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Minimal adapter-feed surface (the permissionless, msg.sender-keyed submit).
interface IAdapterSubmit {
    function submit(uint256 tokenId) external;
}

/// @notice Minimal smart-account mock: DELEGATECALLs the wrapper's request/claim (so ether.fi sees msg.sender == this
///         Safe) and can receive ETH. `track` is a plain CALL to the permissionless adapter's `submit` (msg.sender ==
///         this Safe), used to seed a request the Safe already owns.
contract ForkSafe {
    function doRequestDelegate(address wrapper, uint256 amount) external returns (uint256) {
        (bool ok, bytes memory ret) = wrapper.delegatecall(abi.encodeWithSignature("requestWithdraw(uint256)", amount));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    function doClaimDelegate(address wrapper, uint256 tokenId) external {
        (bool ok, bytes memory ret) = wrapper.delegatecall(abi.encodeWithSignature("claimWithdraw(uint256)", tokenId));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function track(address adapter, uint256 tokenId) external {
        IAdapterSubmit(adapter).submit(tokenId);
    }

    /// @dev ether.fi's LiquidityPool mints the WithdrawRequestNFT via `_safeMint`, which requires the recipient to
    ///      implement this hook (real karpatkey Safes do via their fallback handler).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @title EtherFiWithdrawalQueueAssistant end-to-end fork test (real ether.fi contracts + real funds)
/// @notice Exercises the full wrapper flow against mainnet ether.fi at a pinned block:
///         - **deposit**: a test Safe funded with **real eETH** (sourced from the weETH wrapper, a ~1.7M-eETH holder)
///           delegatecalls `requestWithdraw`, which calls the real LiquidityPool directly — a real `WithdrawRequestNFT`
///           is minted to the Safe and tracked by the adapter, valued from live reads;
///         - **claim**: a **real finalized** request (#80154, worth ~0.2531 ETH, owned by `0xcFFab3…`) is transferred
///           into the Safe, tracked via the wrapper, then claimed via a delegatecalled `claimWithdraw` — real ETH lands
///           in the Safe and the id is removed from the adapter cache.
/// @dev The wrapper is delegatecall-only, so the depositor/claimant is a contract we control (`ForkSafe`), funded from
///      real on-chain holders — this is the delegatecall analogue of using a real EOA holder.
contract EtherFiWithdrawalQueueAssistantForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address public constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev weETH wrapper — holds ~1.7M eETH at FORK_BLOCK; used as the real eETH source for the deposit test.
    address public constant EETH_WHALE = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    /// @dev A real **finalized, unclaimed** withdrawal request at FORK_BLOCK (owner `0xcFFab3…`).
    address public constant FINALIZED_HOLDER = 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4;
    uint256 public constant FINALIZED_TOKEN_ID = 80_154;
    uint256 public constant FINALIZED_CLAIMABLE = 253_077_459_762_665_833; // getClaimableAmount(80154) at FORK_BLOCK

    uint256 public constant FORK_BLOCK = 25_410_000;

    EtherFiWithdrawalQueueAssistedBalanceAdapter public adapter;
    EtherFiWithdrawalQueueAssistant public wrapper;
    ForkSafe public safe;

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");

        // Deploy adapter (wrapper unknown yet) → wrapper → grant WRAPPER_ROLE to the wrapper.
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this)
        );
        wrapper = new EtherFiWithdrawalQueueAssistant(address(adapter), LIQUIDITY_POOL, WITHDRAW_REQUEST_NFT, EETH);

        safe = new ForkSafe();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Independent live recompute of a pending request, mirroring ether.fi's claim math.
    function _liveOwedPending(uint256 tokenId) internal view returns (uint256) {
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory r =
            IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).getRequest(tokenId);
        uint256 byShare = IEtherFiLiquidityPool(LIQUIDITY_POOL).amountForShare(r.shareOfEEth);
        uint256 gross = uint256(r.amountOfEEth) < byShare ? uint256(r.amountOfEEth) : byShare;
        uint256 fee = uint256(r.feeGwei) * 1 gwei;
        return gross > fee ? gross - fee : 0;
    }

    // ---- Deposit: real eETH → requestWithdraw → real NFT minted to the Safe → tracked + valued ----

    function test_requestWithdraw_realEeth_mintsToSafe_andTracks() public {
        uint256 amount = 1 ether;

        // Fund the Safe with real eETH from the whale.
        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(address(safe), 2 ether);
        assertGe(IERC20(EETH).balanceOf(address(safe)), amount, "safe holds eETH");

        // Delegatecalled request: real LiquidityPool pulls eETH from the Safe and mints a real WithdrawRequestNFT to it.
        uint256 id = safe.doRequestDelegate(address(wrapper), amount);

        assertEq(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(id), address(safe), "NFT minted to the Safe");
        assertFalse(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).isFinalized(id), "fresh request is pending");

        uint256[] memory ids = adapter.tokenIdsOf(address(safe));
        assertEq(ids.length, 1);
        assertEq(ids[0], id, "requestId tracked for the Safe");

        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE_ETH);
        assertEq(owed, _liveOwedPending(id), "adapter equals an independent live read (delta 0)");
        assertApproxEqAbs(owed, amount, 0.01 ether, "pending value ~ requested eETH");
    }

    // ---- Claim: real finalized request → track → delegatecalled claim pays the Safe → id removed ----

    function test_claimWithdraw_realFinalizedRequest_paysSafe_andRemoves() public {
        // Seed the real finalized request into the Safe (WithdrawRequestNFT is a transferable ERC721).
        vm.prank(FINALIZED_HOLDER);
        IWithdrawRequestNFTTransfer(WITHDRAW_REQUEST_NFT)
            .transferFrom(FINALIZED_HOLDER, address(safe), FINALIZED_TOKEN_ID);
        assertEq(
            IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(FINALIZED_TOKEN_ID),
            address(safe),
            "request now owned by the Safe"
        );

        // Track it via the wrapper (submit forwarder) and check the adapter values it at the finalized claimable amount.
        safe.track(address(adapter), FINALIZED_TOKEN_ID);
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE_ETH);
        assertEq(owed, FINALIZED_CLAIMABLE, "finalized request valued at getClaimableAmount");

        // Delegatecalled claim: ether.fi sends the ETH to the owner (the Safe), burns the NFT; the wrapper removes it.
        uint256 balBefore = address(safe).balance;
        safe.doClaimDelegate(address(wrapper), FINALIZED_TOKEN_ID);

        assertEq(address(safe).balance, balBefore + FINALIZED_CLAIMABLE, "real ETH paid to the Safe");
        assertEq(adapter.tokenIdsOf(address(safe)).length, 0, "claimed id removed from the adapter cache");
        (uint256 owedAfter,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE_ETH);
        assertEq(owedAfter, 0, "nothing owed after claim");
    }

    // ---- More happy paths (real funds/accounts) ----

    /// @notice Two real-eETH deposits are tracked independently and their live pending values aggregate; two pending
    ///         legs with distinct request ids.
    function test_requestWithdraw_multipleDeposits_aggregate() public {
        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(address(safe), 5 ether);

        uint256 id1 = safe.doRequestDelegate(address(wrapper), 1 ether);
        uint256 id2 = safe.doRequestDelegate(address(wrapper), 2 ether);
        assertTrue(id1 != id2, "distinct request ids");

        assertEq(adapter.tokenIdsOf(address(safe)).length, 2, "both requests tracked");

        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE_ETH);
        assertEq(owed, _liveOwedPending(id1) + _liveOwedPending(id2), "aggregate == sum of independent live reads");
        assertApproxEqAbs(owed, 3 ether, 0.02 ether, "~ 1 + 2 eETH pending");

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(address(safe), address(0));
        assertEq(p.length, 2, "two per-request legs");
        assertTrue(p[0].isLocked && p[1].isLocked, "both pending -> locked");
        assertTrue(p[0].positionInstanceId != p[1].positionInstanceId, "distinct positionInstanceIds");
    }

    /// @notice The real finalized request valued via getAdapterPositions for its real owner: one native-ETH leg,
    ///         isLocked=false, amount == getClaimableAmount, tracked through the wrapper's submit forwarder.
    function test_getAdapterPositions_realFinalizedRequest_isLockedFalse() public {
        vm.prank(FINALIZED_HOLDER);
        adapter.submit(FINALIZED_TOKEN_ID);

        (uint256 owed,) = adapter.getAdapterBalanceForAsset(FINALIZED_HOLDER, NATIVE_ETH);
        assertEq(owed, FINALIZED_CLAIMABLE, "finalized -> getClaimableAmount");

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(FINALIZED_HOLDER, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, FINALIZED_CLAIMABLE);
        assertFalse(p[0].isLocked, "finalized request -> not locked");
        assertEq(p[0].balanceAsset.asset, NATIVE_ETH);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertEq(p[0].protocolSubId, ProtocolIds.ETHERFI_WITHDRAWAL);
        assertEq(p[0].positionInstanceId, bytes32(FINALIZED_TOKEN_ID));
    }

    /// @notice A pending real-eETH deposit and a transferred-in real finalized request coexist and aggregate; claiming
    ///         the finalized one leaves the pending one tracked.
    function test_pendingDeposit_andFinalizedClaim_coexist() public {
        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(address(safe), 2 ether);
        uint256 pendingId = safe.doRequestDelegate(address(wrapper), 1 ether);

        vm.prank(FINALIZED_HOLDER);
        IWithdrawRequestNFTTransfer(WITHDRAW_REQUEST_NFT)
            .transferFrom(FINALIZED_HOLDER, address(safe), FINALIZED_TOKEN_ID);
        safe.track(address(adapter), FINALIZED_TOKEN_ID);

        assertEq(adapter.tokenIdsOf(address(safe)).length, 2, "pending + finalized tracked");
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE_ETH);
        assertEq(owed, _liveOwedPending(pendingId) + FINALIZED_CLAIMABLE, "pending estimate + finalized claimable");

        uint256 balBefore = address(safe).balance;
        safe.doClaimDelegate(address(wrapper), FINALIZED_TOKEN_ID);
        assertEq(address(safe).balance, balBefore + FINALIZED_CLAIMABLE, "real ETH from the finalized claim");

        uint256[] memory left = adapter.tokenIdsOf(address(safe));
        assertEq(left.length, 1, "only the pending request remains tracked");
        assertEq(left[0], pendingId);
    }
}
