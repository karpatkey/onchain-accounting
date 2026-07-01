// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {WrapperFedBalanceAdapter} from "src/balances/WrapperFedBalanceAdapter.sol";
import {WrapperFedNftCacheAdapter} from "src/balances/WrapperFedBalanceAdapters/WrapperFedNftCacheAdapter.sol";
import {
    EtherFiWithdrawalValuationBase,
    IEtherFiWithdrawRequestNFT
} from "src/balances/WrapperFedBalanceAdapters/EtherFiWithdrawalValuationBase.sol";
import {SingleAssetAssistedGetters} from "src/balances/AssistedBalanceAdapters/SingleAssetAssistedGetters.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title ether.fi Withdrawals Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Wrapper-fed peer of `EtherFiWithdrawalQueueAssistedBalanceAdapter`: reports the in-flight ETH owed to an
///         account in ether.fi's withdrawal queue. Requesting a withdrawal burns eETH/weETH and mints a
///         `WithdrawRequestNFT`; the queued ETH is then invisible to a pure-view NAV scan (the NFT is not
///         `ERC721Enumerable` and exposes no owner→tokenIds view). A trusted **wrapper contract** (holder of
///         `WRAPPER_ROLE` — the {EtherFiWithdrawalQueueWrapper}) pushes the account's `requestId`s via `submit`
///         **atomically as it forwards the withdrawal request**, so the id cache is kept current on-chain in the same
///         transaction. This adapter values each cached id entirely from live on-chain reads, re-verifying ownership on
///         every read. The cache stores **only ids, never amounts**, so the wrapper cannot fabricate value — at worst
///         it omits an id (NAV under-counts), never over-counts.
/// @dev Access control + the `WRAPPER_ROLE`-gated {submit}/{remove} surface (plus a permissionless {pruneStale} for GC)
///      come from {WrapperFedNftCacheAdapter}. All valuation logic — the ether.fi contract addresses, position
///      identity, and per-request `min(amountOfEEth, amountForShare) − fee` / finalized `getClaimableAmount` math —
///      lives in the shared, feeder-agnostic {EtherFiWithdrawalValuationBase}, identical to the assistant-fed sibling;
///      only the feeder (`WRAPPER_ROLE` vs `ASSISTANT_ROLE`) and submit surface (incremental single add/remove vs
///      off-chain full-set replace) differ. The single-asset getter triad
///      (underlyingAssetsSupported / getAdapterBalanceForAsset / getAdapterBalances) is provided by
///      {SingleAssetAssistedGetters} off the {_owedAmount} hook below. Trust model + mutability rationale:
///      `docs/decisions/0020-wrapper-fed-etherfi-withdrawal-queue.md` (extends ADR 0014 / 0015). Emits ONE native-ETH
///      `Supplied` leg per owned cached withdrawal request, all sharing a single static positionId; each leg's
///      `isLocked` reflects that request's own state (finalized → `false`, pending → `true`) and its `tokenId` rides in
///      the typed `positionInstanceId`, never in `positionId`.
contract EtherFiWithdrawalQueueBalanceAdapter is
    WrapperFedNftCacheAdapter,
    EtherFiWithdrawalValuationBase,
    SingleAssetAssistedGetters,
    IPositionDescribable
{
    /// @notice Hard cap on cached tokenIds per account (returned by the {_maxTokenIds} hook the shared
    ///         {WrapperFedNftCacheAdapter} base enforces at submit time). `_owedAmount` iterates the whole set on every
    ///         NAV read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the wrapper GCs
    ///         claimed ids via {pruneStale}. A real account never approaches 256 open requests.
    uint256 public constant MAX_TOKEN_IDS = 256;

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param underlyingToken_    Payout asset (native-ETH sentinel).
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    /// @param admin_              Holder of `DEFAULT_ADMIN_ROLE` (administers `WRAPPER_ROLE`). Required.
    /// @param wrapper_            Initial holder of `WRAPPER_ROLE` — the {EtherFiWithdrawalQueueWrapper}. Optional (pass
    ///                            `address(0)` and grant after the wrapper is deployed, since the wrapper needs this
    ///                            adapter's address at construction).
    constructor(
        address withdrawRequestNft_,
        address liquidityPool_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address wrapper_
    )
        WrapperFedNftCacheAdapter(admin_, wrapper_)
        SingleAssetAssistedGetters(underlyingToken_)
        EtherFiWithdrawalValuationBase(withdrawRequestNft_, liquidityPool_, navCalculator_)
    {}

    //
    // Cache hooks (WrapperFedNftCacheAdapter)
    //

    /// @inheritdoc WrapperFedNftCacheAdapter
    /// @dev Ownership read for the cache's write-time check and {pruneStale}: wraps
    ///      `IEtherFiWithdrawRequestNFT.ownerOf` so a claimed / burned / non-existent id (which `ownerOf` reverts on)
    ///      returns `(0, false)` rather than bubbling.
    function _ownerOf(uint256 tokenId) internal view override returns (address, bool) {
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @inheritdoc WrapperFedNftCacheAdapter
    function _maxTokenIds() internal pure override returns (uint256) {
        return MAX_TOKEN_IDS;
    }

    //
    // Reads (view, anyone)
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(WrapperFedBalanceAdapter, IERC165)
        returns (bool)
    {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "ether.fi";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "eETH"]` — category + the receipt-token symbol (matching the assistant-fed sibling).
    ///      All requests share the queue `positionId`; the per-request WithdrawRequestNFT id is the typed
    ///      `positionInstanceId` on each leg (ephemeral — burned on claim), NOT here.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "eETH";
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE native-ETH `Supplied` leg per owned cached withdrawal request, all sharing the static
    ///         `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`. Each leg's `isLocked` reflects that request's state
    ///         (finalized → `false`, pending → `true`) and its `tokenId` is the typed `positionInstanceId`.
    /// @dev Each cached id is valued live from on-chain reads (`_owedForToken`), re-verifying ownership every read:
    ///      requests not owned by `account` / invalid / claimed / burned value to 0 and emit no leg — the wrapper can
    ///      only under-report. Zero-amount legs are skipped. The legs sum to `_owedAmount`'s total. Dropped entirely if
    ///      the underlying asset is not registered in NAVCalculator.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256[] memory ids = _cachedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        (INAVCalculator.Asset memory underlying, bool registered) = RegisteredAssetLib.find(reg, UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        bytes memory positionId = abi.encode(WITHDRAW_REQUEST_NFT);
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](ids.length);
        uint256 n;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint256 owed, bool finalized) = _owedForToken(account, ids[i]);
            if (owed == 0) {
                continue;
            }
            temp[n++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: owed,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: !finalized,
                positionInstanceId: bytes32(ids[i])
            });
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
    }

    //
    // Internal — valuation
    //

    /// @inheritdoc SingleAssetAssistedGetters
    /// @dev Total ETH owed across the account's cached tokenIds, valued from live on-chain reads. Never reverts.
    function _owedAmount(address account) internal view override returns (uint256 total) {
        uint256[] memory ids = _cachedTokenIds(account);
        for (uint256 i; i < ids.length; ++i) {
            (uint256 owed,) = _owedForToken(account, ids[i]);
            total += owed;
        }
    }
}
