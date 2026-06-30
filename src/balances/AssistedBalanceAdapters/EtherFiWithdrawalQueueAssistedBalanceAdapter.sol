// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {AssistedNftCacheAdapter} from "src/balances/AssistedBalanceAdapters/AssistedNftCacheAdapter.sol";
import {SingleAssetAssistedGetters} from "src/balances/AssistedBalanceAdapters/SingleAssetAssistedGetters.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ether.fi Withdrawals Balance Adapter (id-cached)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue. Requesting a withdrawal
///         burns eETH/weETH and mints a `WithdrawRequestNFT`; the queued ETH is then invisible to NAV (the NFT is
///         not `ERC721Enumerable` and exposes no owner→tokenIds view, so a pure-view adapter cannot discover the
///         positions). An off-chain assistant (holder of `ASSISTANT_ROLE`) submits the account's `tokenId`s via
///         `submitTokenIds`; this adapter then values them entirely from live on-chain reads, re-verifying ownership on
///         every read. The cache stores **only ids, never amounts**, so the assistant cannot fabricate value — at worst it omits an id (NAV
///         under-counts), never over-counts.
/// @dev Access control comes from {AssistedBalanceAdapter}: `DEFAULT_ADMIN_ROLE` administers roles and `ASSISTANT_ROLE`
///      gates the submit/clear mutators. Trust model and mutability rationale: see
///      `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md` (generalises the Merkl precedent, ADR 0007).
///      Emits ONE native-ETH `Supplied` leg per owned cached withdrawal request, all sharing a single static
///      positionId; each leg's `isLocked` reflects that request's own state (finalized → `false`, pending → `true`)
///      and its `tokenId` (the WithdrawRequestNFT id) rides in the typed `positionInstanceId`, never in `positionId`.
contract EtherFiWithdrawalQueueAssistedBalanceAdapter is
    AssistedNftCacheAdapter,
    SingleAssetAssistedGetters,
    IPositionDescribable
{
    //
    // State
    //

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.ETHERFI_WITHDRAWAL;

    /// @notice Hard cap on cached tokenIds per account (returned by the {_maxTokenIds} hook the shared
    ///         {AssistedNftCacheAdapter} base enforces at submit time). `_owedAmount` iterates the whole set on every NAV
    ///         read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the assistant must
    ///         GC claimed ids (`clearTokenId`) to stay under it. A real account never approaches 256 open requests.
    uint256 public constant MAX_TOKEN_IDS = 256;

    /// @notice ether.fi WithdrawRequestNFT (mainnet `0x7d57…4E2c`). Source of ownership + per-request data.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice ether.fi LiquidityPool — `amountForShare` converts a request's locked shares to current ETH.
    address public immutable LIQUIDITY_POOL;

    /// @notice NAVCalculator — used to look up the registered native-ETH Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param underlyingToken_    Payout asset (native-ETH sentinel).
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    /// @param admin_              Holder of `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`). Required.
    /// @param assistant_          Initial holder of `ASSISTANT_ROLE`, authorized to submit/clear tokenIds (the assistant
    ///                            agent). Optional (pass `address(0)` to grant later via `admin_`).
    constructor(
        address withdrawRequestNft_,
        address liquidityPool_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address assistant_
    ) AssistedNftCacheAdapter(admin_, assistant_) SingleAssetAssistedGetters(underlyingToken_) {
        if (withdrawRequestNft_ == address(0) || liquidityPool_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        LIQUIDITY_POOL = liquidityPool_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Cache hooks (AssistedNftCacheAdapter)
    //
    // The per-account tokenId set and its CRUD — submitTokenIds / submitTokenIdsBatch / clearTokenId / clearAccount /
    // tokenIdsOf, the events, the cap enforcement, and the delta replace — live in the shared AssistedNftCacheAdapter
    // base. This adapter supplies only the ownership read and the cap.
    //

    /// @inheritdoc AssistedNftCacheAdapter
    /// @dev Ownership read for the cache's write-time check: wraps `IEtherFiWithdrawRequestNFT.ownerOf` so a claimed /
    ///      burned / non-existent id (which `ownerOf` reverts on) returns `(0, false)` rather than bubbling.
    function _ownerOf(uint256 tokenId) internal view override returns (address, bool) {
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @inheritdoc AssistedNftCacheAdapter
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
        override(AssistedBalanceAdapter, IERC165)
        returns (bool)
    {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    function protocolName() external pure returns (string memory) {
        return "ether.fi";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "eETH"]` — category + the receipt-token symbol (matching the sibling queues). All
    ///      requests share the queue `positionId`; the per-request WithdrawRequestNFT id is the typed
    ///      `positionInstanceId` on each leg (ephemeral — burned on claim), NOT here.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "eETH";
    }

    // The single-asset getter triad (underlyingAssetsSupported / getAdapterBalanceForAsset / getAdapterBalances)
    // is provided by {SingleAssetAssistedGetters}, off the {_owedAmount} hook below.

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE native-ETH `Supplied` leg per owned cached withdrawal request, all sharing the static
    ///         `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`. Each leg's `isLocked` reflects that request's state
    ///         (finalized → `false`, pending → `true`) and its `tokenId` is the typed `positionInstanceId`.
    /// @dev Each cached id is valued live from on-chain reads (`_owedForToken`), re-verifying ownership every read:
    ///      requests not owned by `account` / invalid / claimed / burned value to 0 and emit no leg — the assistant
    ///      can only under-report. Zero-amount legs are skipped. The legs sum to `_owedAmount`'s total. The tokenId rides
    ///      in `positionInstanceId` (ephemeral — burned on claim), NOT in `positionId`, so multiple requests share the
    ///      static positionId and are distinguished by their `positionInstanceId` (and for NAV by summing). Dropped
    ///      entirely if the underlying asset is not registered in NAVCalculator.
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

    /// @dev ETH owed for a single request and whether it is finalized (claimable). `owed` is 0 if the request is
    ///      not live / not owned by `account` / invalid (and `finalized` is false in those cases). Mirrors ether.fi's
    ///      own claim math: finalized → exact `getClaimableAmount`; pending → the protocol's
    ///      `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei` estimate. All external reads try/catch to 0.
    function _owedForToken(address account, uint256 tokenId) internal view returns (uint256 owed, bool finalized) {
        IEtherFiWithdrawRequestNFT nft = IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT);

        // Ownership: a claimed/burned NFT makes ownerOf revert; a transferred one returns a different owner.
        try nft.ownerOf(tokenId) returns (address o) {
            if (o != account) return (0, false);
        } catch {
            return (0, false);
        }
        try nft.isValid(tokenId) returns (bool ok) {
            if (!ok) return (0, false);
        } catch {
            return (0, false);
        }

        try nft.isFinalized(tokenId) returns (bool f) {
            finalized = f;
        } catch {
            return (0, false);
        }

        if (finalized) {
            try nft.getClaimableAmount(tokenId) returns (uint256 claimable) {
                return (claimable, true);
            } catch {
                return (0, false);
            }
        }

        // Pending: estimate the claimable ETH the way ether.fi computes it at claim time.
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory req;
        try nft.getRequest(tokenId) returns (IEtherFiWithdrawRequestNFT.WithdrawRequest memory r) {
            req = r;
        } catch {
            return (0, false);
        }
        uint256 byShare;
        try IEtherFiLiquidityPool(LIQUIDITY_POOL).amountForShare(req.shareOfEEth) returns (uint256 s) {
            byShare = s;
        } catch {
            return (0, false);
        }
        uint256 gross = uint256(req.amountOfEEth) < byShare ? uint256(req.amountOfEEth) : byShare;
        uint256 fee = uint256(req.feeGwei) * 1 gwei;
        return (gross > fee ? gross - fee : 0, false);
    }
}

/// @notice Minimal interface for ether.fi's WithdrawRequestNFT.
interface IEtherFiWithdrawRequestNFT {
    /// @param amountOfEEth eEth amount locked at request time.
    /// @param shareOfEEth  eEth shares locked at request time.
    /// @param isValid      Whether the request is valid (not invalidated by the protocol).
    /// @param feeGwei      Withdrawal fee in gwei, subtracted from the claimable amount.
    struct WithdrawRequest {
        uint96 amountOfEEth;
        uint96 shareOfEEth;
        bool isValid;
        uint32 feeGwei;
    }

    function ownerOf(uint256 tokenId) external view returns (address);
    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory);
    function getClaimableAmount(uint256 tokenId) external view returns (uint256);
    function isFinalized(uint256 requestId) external view returns (bool);
    function isValid(uint256 requestId) external view returns (bool);
}

/// @notice Minimal interface for ether.fi's LiquidityPool.
interface IEtherFiLiquidityPool {
    /// @notice Current ETH value of `share` eEth shares.
    function amountForShare(uint256 share) external view returns (uint256);
}
