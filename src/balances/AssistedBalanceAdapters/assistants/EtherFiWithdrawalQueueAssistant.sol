// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BalanceAdapterAssistant} from "src/balances/AssistedBalanceAdapters/assistants/BalanceAdapterAssistant.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title EtherFiWithdrawalQueueAssistant
/// @author KPK
/// @notice Delegatecall-only logic the owning Safe runs to request/claim ether.fi withdrawals while keeping the
///         assistant-fed {EtherFiWithdrawalQueueAssistedBalanceAdapter} id-cache current **on-chain, atomically**. Both
///         entrypoints are DELEGATECALLed by the Safe, so `address(this)` is the Safe: ether.fi sees `msg.sender = Safe`
///         and the adapter (permissionless, `msg.sender`-keyed) records against that same Safe — no roles, no
///         self-calls, no custody.
/// @dev Extends {BalanceAdapterAssistant} for `SELF` / {onlyDelegateCall} / immutable `ADAPTER`. A direct (non-delegate)
///      call reverts `NotDelegateCall`. ether.fi's `claimWithdraw` hard-requires `ownerOf == msg.sender` (no
///      claim-on-behalf), which the delegatecall satisfies (Safe == owner). Because the adapter's `remove` requires the
///      request to be **claimed** (the NFT burned → no longer owned → removable), {claimWithdraw} claims **first**, then
///      removes. EOAs cannot delegatecall, so the intended callers are Safe/Avatar accounts (gated at the Safe layer).
///      See [ADR 0018](../../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md).
contract EtherFiWithdrawalQueueAssistant is BalanceAdapterAssistant {
    using SafeERC20 for IERC20;

    /// @notice ether.fi LiquidityPool — the `requestWithdraw` target that pulls eETH and mints the WithdrawRequestNFT.
    address public immutable LIQUIDITY_POOL;

    /// @notice ether.fi WithdrawRequestNFT — the `claimWithdraw` target.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice eETH token — the Safe approves this to the LiquidityPool inside the delegatecalled `requestWithdraw`.
    address public immutable EETH;

    /// @param adapter_            The assistant-fed {EtherFiWithdrawalQueueAssistedBalanceAdapter}. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool. Must be a contract.
    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param eeth_               eETH token. Must be a contract.
    constructor(address adapter_, address liquidityPool_, address withdrawRequestNft_, address eeth_)
        BalanceAdapterAssistant(adapter_)
    {
        if (liquidityPool_ == address(0) || withdrawRequestNft_ == address(0) || eeth_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(eeth_, "eETH");
        LIQUIDITY_POOL = liquidityPool_;
        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        EETH = eeth_;
    }

    /// @notice Request a withdrawal of `amount` eETH from ether.fi and track the resulting WithdrawRequestNFT for the
    ///         Safe. **Must be DELEGATECALLed by the owning Safe.** Approves the LiquidityPool for the Safe's eETH and
    ///         calls it with `recipient = address(this) = Safe` (NFT minted to the Safe), then submits the returned
    ///         `requestId` (adapter keyed on `msg.sender = Safe`).
    /// @param amount eETH to withdraw (pulled directly from the delegatecalling Safe).
    /// @return requestId The minted WithdrawRequestNFT id (tracked for the Safe).
    function requestWithdraw(uint256 amount) external onlyDelegateCall returns (uint256 requestId) {
        IERC20(EETH).forceApprove(LIQUIDITY_POOL, amount);
        requestId = ILiquidityPool(LIQUIDITY_POOL).requestWithdraw(address(this), amount);
        IEtherFiWithdrawalQueueAssistedBalanceAdapter(ADAPTER).submit(requestId);
    }

    /// @notice Claim withdrawal request `tokenId` from ether.fi and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe** (ether.fi's claim hard-requires `ownerOf == msg.sender`). Claims **first** (burns the NFT,
    ///         ETH to the Safe), **then** removes — the adapter's `remove` requires the request to be claimed (no longer
    ///         owned).
    /// @param tokenId The WithdrawRequestNFT id to claim (owned by the delegatecalling Safe).
    function claimWithdraw(uint256 tokenId) external onlyDelegateCall {
        IWithdrawRequestNFTClaim(WITHDRAW_REQUEST_NFT).claimWithdraw(tokenId);
        // Best-effort untrack — never block the claim. Normally the id is tracked and the burned NFT makes it
        // removable, but a request cleared via `clearAccount` or acquired outside the assistant is not tracked and
        // `remove` reverts `CoordinateNotCached` (and, defensively, `CoordinateStillLive` if it somehow re-resolves as
        // owned). Swallow both; bubble anything else.
        try IEtherFiWithdrawalQueueAssistedBalanceAdapter(ADAPTER).remove(tokenId) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            if (sel != CoordinateStillLive.selector && sel != CoordinateNotCached.selector) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}

/// @notice Minimal interface for ether.fi's LiquidityPool — only the function the assistant forwards.
interface ILiquidityPool {
    /// @notice Burns `amount` eETH from `msg.sender` and mints a WithdrawRequestNFT to `recipient`.
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256 requestId);
}

/// @notice Minimal interface for ether.fi's WithdrawRequestNFT — only the claim entrypoint the assistant forwards.
interface IWithdrawRequestNFTClaim {
    /// @notice Claims request `tokenId`; requires `ownerOf(tokenId) == msg.sender`, burns the NFT, sends ETH to owner.
    function claimWithdraw(uint256 tokenId) external;
}

/// @notice Minimal interface for the assistant-fed balance adapter's feed surface (keyed on `msg.sender`).
interface IEtherFiWithdrawalQueueAssistedBalanceAdapter {
    function submit(uint256 tokenId) external;
    function remove(uint256 tokenId) external;
}
