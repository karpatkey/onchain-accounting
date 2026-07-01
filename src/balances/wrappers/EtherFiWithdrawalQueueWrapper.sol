// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title EtherFiWithdrawalQueueWrapper
/// @author KPK
/// @notice `DEPOSITOR_ROLE`-gated forwarder around ether.fi's withdrawal queue that keeps the wrapper-fed
///         {EtherFiWithdrawalQueueAssistedBalanceAdapter} id-cache current **on-chain, atomically**. Any address the
///         admin grants `DEPOSITOR_ROLE` gets its ether.fi withdrawal requests tracked automatically as it
///         requests/claims through this wrapper. The adapter grants this contract `WRAPPER_ROLE`, and **only** this
///         contract mutates the adapter cache (`submit` / `remove` / `pruneStale` are all `WRAPPER_ROLE`-gated on the
///         adapter) — depositors never hold a role on the adapter.
///
/// @dev **This contract is used in two DIFFERENT execution modes — read this carefully.**
///
///      1. **`requestWithdraw` — a normal CALL.** The DEPOSITOR calls the wrapper directly. The wrapper checks
///         `DEPOSITOR_ROLE` (from its own storage), pulls the exact `amount` of eETH from the DEPOSITOR
///         (`transferFrom` — the DEPOSITOR must approve this wrapper first), sets the exact-amount allowance to the
///         `LIQUIDITY_POOL` (`forceApprove`), forwards to `LiquidityPool.requestWithdraw(recipient = msg.sender, amount)`
///         — so the minted `WithdrawRequestNFT` is always owned by the caller — and then `submit`s the returned
///         `requestId` for the caller into the adapter (the wrapper holds `WRAPPER_ROLE`). The wrapper custodies no eETH
///         between calls. There is no `recipient` parameter: the NFT recipient / tracked account is always
///         `msg.sender`, so the position is always owned by the tracked account and the adapter's live ownership
///         re-verification always passes for it.
///
///      2. **`claimWithdraw` — a DELEGATECALL from the owning Safe.** ether.fi's
///         `WithdrawRequestNFT.claimWithdraw(tokenId)` hard-requires `ownerOf(tokenId) == msg.sender` and **ignores
///         ERC721 approvals**, so the wrapper cannot claim on the DEPOSITOR's behalf via a normal CALL. The DEPOSITOR's
///         Safe must **delegatecall** this function: then `address(this)` is the Safe, `msg.sender` seen by the NFT is
///         the Safe (== the owner ✓), and ETH flows straight to the Safe. Immutables (`WITHDRAW_REQUEST_NFT`, `ADAPTER`,
///         `SELF`) are embedded in bytecode, so they are readable under delegatecall. The function takes **no role
///         guard** — under delegatecall the wrapper's storage/roles are the Safe's and would not resolve — and it
///         touches **no** wrapper storage. To prune the now-burned id it makes a *regular* call to this wrapper's own
///         deployed address (`SELF`) — `EtherFiWithdrawalQueueWrapper(SELF).pruneStale(tokenId)` — so the adapter's
///         `WRAPPER_ROLE`-gated `pruneStale` is invoked **by the wrapper**, not by the delegatecalling Safe (which holds
///         no role on the adapter). See `docs/decisions/0020-wrapper-fed-etherfi-withdrawal-queue.md`.
///
///      A direct CALL to `claimWithdraw` by a non-owner simply reverts inside the NFT ("Not the owner of the NFT"),
///      and a delegatecall of `requestWithdraw` reverts on the `DEPOSITOR_ROLE`/`WRAPPER_ROLE` checks — so the two
///      modes fail safe if invoked the wrong way. EOA depositors cannot use the delegatecalled claim (an EOA cannot
///      delegatecall); they claim directly on ether.fi. The intended DEPOSITORs are Safe/Avatar accounts.
contract EtherFiWithdrawalQueueWrapper is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to request/claim through the wrapper (and thereby have its ether.fi withdrawals tracked).
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice This wrapper's own deployed address, pinned at construction. Because it is an immutable it is baked into
    ///         the bytecode, so it still reads as the wrapper's real address when `claimWithdraw` runs under
    ///         delegatecall (where `address(this)` is the Safe) — letting the claim route `pruneStale` back through the
    ///         wrapper. Mirrors the UUPS `__self` pattern.
    address public immutable SELF;

    /// @notice The wrapper-fed balance adapter this wrapper feeds (holds `WRAPPER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice ether.fi LiquidityPool — the `requestWithdraw` target that pulls eETH and mints the WithdrawRequestNFT.
    address public immutable LIQUIDITY_POOL;

    /// @notice ether.fi WithdrawRequestNFT — the `claimWithdraw` target (delegatecalled from the owning Safe).
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice eETH token — pulled from the DEPOSITOR on `requestWithdraw` and approved to the LiquidityPool.
    address public immutable EETH;

    /// @param adapter_            The wrapper-fed {EtherFiWithdrawalQueueAssistedBalanceAdapter}. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool. Must be a contract.
    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param eeth_               eETH token. Must be a contract.
    /// @param admin_              Holder of `DEFAULT_ADMIN_ROLE` (administers `DEPOSITOR_ROLE`). Required.
    constructor(address adapter_, address liquidityPool_, address withdrawRequestNft_, address eeth_, address admin_) {
        if (
            adapter_ == address(0) || liquidityPool_ == address(0) || withdrawRequestNft_ == address(0)
                || eeth_ == address(0) || admin_ == address(0)
        ) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(adapter_, "adapter");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(eeth_, "eETH");

        SELF = address(this);
        ADAPTER = adapter_;
        LIQUIDITY_POOL = liquidityPool_;
        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        EETH = eeth_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Request a withdrawal of `amount` eETH from ether.fi and track the resulting WithdrawRequestNFT for the
    ///         caller. **Normal CALL** (see contract NatSpec). The WithdrawRequestNFT is always minted to (and tracked
    ///         for) `msg.sender`.
    /// @param amount eETH to withdraw (pulled from `msg.sender` — the DEPOSITOR must approve this wrapper first).
    /// @return requestId The minted WithdrawRequestNFT id (tracked for `msg.sender`).
    function requestWithdraw(uint256 amount) external onlyRole(DEPOSITOR_ROLE) returns (uint256 requestId) {
        // Pull the eETH from the DEPOSITOR, then set the exact-amount allowance for the LiquidityPool (it pulls eETH
        // from this wrapper on requestWithdraw). forceApprove tolerates tokens that require resetting a non-zero
        // allowance.
        IERC20(EETH).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(EETH).forceApprove(LIQUIDITY_POOL, amount);

        // recipient = msg.sender: the NFT is always owned by the tracked account, so the adapter's live ownership
        // re-verification always passes for it.
        requestId = ILiquidityPool(LIQUIDITY_POOL).requestWithdraw(msg.sender, amount);
        IEtherFiWithdrawalFeed(ADAPTER).submit(msg.sender, requestId);
    }

    /// @notice Claim withdrawal request `tokenId` from ether.fi and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe** (see contract NatSpec): ether.fi's claim hard-requires `ownerOf(tokenId) == msg.sender`.
    ///         Under delegatecall `msg.sender` seen by the NFT is the Safe (== owner), the ETH flows to the Safe, and
    ///         the now-burned id is pruned from the adapter cache via {pruneStale} — reached by a regular call to this
    ///         wrapper's own address (`SELF`) so the adapter is mutated by the wrapper (`WRAPPER_ROLE`), never by the
    ///         Safe. Touches no wrapper storage / roles (both would be the Safe's under delegatecall).
    /// @param tokenId The WithdrawRequestNFT id to claim (owned by the delegatecalling Safe).
    function claimWithdraw(uint256 tokenId) external {
        IWithdrawRequestNFTClaim(WITHDRAW_REQUEST_NFT).claimWithdraw(tokenId);
        // Regular call to SELF (the wrapper's real address, which survives delegatecall as an immutable) — msg.sender
        // seen by pruneStale is the Safe (the account the id was submitted for), and pruneStale forwards to the adapter
        // AS the wrapper. The prune succeeds only because the claim just burned the NFT (provably no longer owned).
        EtherFiWithdrawalQueueWrapper(SELF).pruneStale(tokenId);
    }

    /// @notice Prune `tokenId` from `msg.sender`'s adapter cache by forwarding to the adapter's `WRAPPER_ROLE`-gated
    ///         `pruneStale` (this wrapper is the role holder). The adapter removes the id **only if** it is no longer
    ///         owned by `msg.sender` (e.g. burned on claim / transferred away), so this can never delete a live
    ///         position — it is therefore safe to leave open to any caller (a caller can only GC its own stale ids).
    ///         Called by {claimWithdraw} (via the `SELF` self-call) and usable standalone to GC a stale id.
    /// @param tokenId The WithdrawRequestNFT id to stop tracking for `msg.sender`.
    function pruneStale(uint256 tokenId) external {
        IEtherFiWithdrawalFeed(ADAPTER).pruneStale(msg.sender, tokenId);
    }
}

/// @notice Minimal interface for ether.fi's LiquidityPool — only the function the wrapper forwards.
interface ILiquidityPool {
    /// @notice Burns `amount` eETH from `msg.sender` and mints a WithdrawRequestNFT to `recipient`.
    /// @return requestId The minted WithdrawRequestNFT id.
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256 requestId);
}

/// @notice Minimal interface for ether.fi's WithdrawRequestNFT — only the claim entrypoint the wrapper forwards.
interface IWithdrawRequestNFTClaim {
    /// @notice Claims request `tokenId`; requires `ownerOf(tokenId) == msg.sender`, burns the NFT, sends ETH to owner.
    function claimWithdraw(uint256 tokenId) external;
}

/// @notice Minimal interface for the wrapper-fed balance adapter's feed surface used by this wrapper.
interface IEtherFiWithdrawalFeed {
    function submit(address account, uint256 tokenId) external;
    function pruneStale(address account, uint256 tokenId) external;
}
