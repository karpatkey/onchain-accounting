// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedCoordCache} from "./AssistedCoordCache.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ether.fi Withdrawals Balance Adapter (id-cached, assistant-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue. Requesting a withdrawal burns
///         eETH/weETH and mints a `WithdrawRequestNFT`; the queued ETH is then invisible to a pure-view NAV scan. The
///         canonical feeder is `EtherFiWithdrawalQueueAssistant`, which the owner Safe delegatecalls so the adapter sees
///         `msg.sender = Safe = owner`: it pushes the `requestId` on `requestWithdraw` and pops it on `claimWithdraw`,
///         atomically. Each cached id is valued live, re-verifying ownership every read; the cache stores **ids only,
///         never amounts**.
/// @dev Member of the assistant-fed assisted family ([ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)),
///      extending the single {AssistedCoordCache}: the coordinate is `abi.encode(tokenId)`. Supersedes the earlier
///      off-chain-agent (ASSISTANT_ROLE) ether.fi adapter of ADR 0014. {_removable} = "no longer owned by the caller":
///      ether.fi's `claimWithdraw` **burns** the NFT, so a claimed id becomes removable while a still-owned (pending)
///      id cannot be dropped (CoordinateStillLive) — the assistant claims first, then removes. Emits ONE native-ETH
///      `Supplied` leg per owned cached request, `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`, `isLocked = !finalized`,
///      the tokenId in `positionInstanceId`.
contract EtherFiWithdrawalQueueAssistedBalanceAdapter is AssistedCoordCache, IPositionDescribable {
    /// @notice Hard cap on cached tokenIds per account (read-loop gas bound). A real account never approaches it.
    uint256 public constant MAX_TOKEN_IDS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.ETHERFI_WITHDRAWAL;

    /// @notice ether.fi WithdrawRequestNFT. Source of ownership + per-request data.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice ether.fi LiquidityPool — `amountForShare` converts a request's locked shares to current ETH.
    address public immutable LIQUIDITY_POOL;

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param underlyingToken_    Payout asset (native-ETH sentinel). Must be non-zero.
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    /// @param admin_              `DEFAULT_ADMIN_ROLE` holder (grants the keeper's `SUBMITTER_ROLE`). Must be non-zero.
    constructor(
        address withdrawRequestNft_,
        address liquidityPool_,
        address underlyingToken_,
        address navCalculator_,
        address admin_
    ) AssistedCoordCache(underlyingToken_, navCalculator_, admin_) {
        if (withdrawRequestNft_ == address(0) || liquidityPool_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        LIQUIDITY_POOL = liquidityPool_;
    }

    //
    // Typed owner feed surface (msg.sender-keyed; the keeper path is in the base, ADR 0030)
    //

    /// @notice Track `tokenId` for the caller (idempotent). **Reverts** `CoordinateNotOwned` if not owned by the caller,
    ///         `CoordinateCacheFull` past {MAX_TOKEN_IDS}.
    function submit(uint256 tokenId) external {
        _submitCoord(abi.encode(tokenId));
    }

    /// @notice Stop tracking `tokenId` for the caller (after claim burns it). **Reverts** `CoordinateNotCached` if not
    ///         tracked, `CoordinateStillLive` if still owned (not yet claimed).
    function remove(uint256 tokenId) external {
        _removeCoord(abi.encode(tokenId));
    }

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory ids) {
        bytes[] memory coords = _cachedCoords(account);
        ids = new uint256[](coords.length);
        for (uint256 i; i < coords.length; ++i) {
            ids[i] = abi.decode(coords[i], (uint256));
        }
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure override returns (string memory) {
        return "ether.fi";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "eETH"]` — category + the receipt-token symbol.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "eETH";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Hooks
    //

    /// @inheritdoc AssistedCoordCache
    function _maxCoords() internal pure override returns (uint256) {
        return MAX_TOKEN_IDS;
    }

    /// @inheritdoc AssistedCoordCache
    function _maxLegsPerCoord() internal pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AssistedCoordCache
    function _coordId(bytes memory coord) internal pure override returns (uint256) {
        return abi.decode(coord, (uint256));
    }

    /// @inheritdoc AssistedCoordCache
    function _validateCoord(address account, bytes memory coord) internal view override {
        uint256 tokenId = abi.decode(coord, (uint256));
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert CoordinateNotOwned(account, tokenId);
    }

    /// @inheritdoc AssistedCoordCache
    function _coordLength() internal pure override returns (uint256) {
        return 32;
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Owner-side: removable once claimed (`claimWithdraw` burns the NFT, so `ownerOf` reverts and the id reads as
    ///      unowned), or while ether.fi has the request invalidated — it values 0 then, and the owner can re-submit if
    ///      the protocol re-validates it. A failed `isValid` read keeps the id.
    function _removable(address account, bytes memory coord) internal view override returns (bool) {
        uint256 tokenId = abi.decode(coord, (uint256));
        (address owner, bool ok) = _ownerOf(tokenId);
        // Keep this check FIRST: ether.fi's `isValid` reverts for a burned id.
        if (!(ok && owner == account)) return true;
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).isValid(tokenId) returns (bool valid) {
            return !valid;
        } catch {
            return false;
        }
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Dead when `ownerOf` succeeds with another owner (transferred away), or when `ownerOf` reverts (burned)
    ///      AND `getRequest` succeeds with an emptied request — a claim burns the NFT and deletes the request. A
    ///      request `account` still owns is never dead here, whatever `getRequest` says. Invalidation is NOT death:
    ///      ether.fi can re-validate a request.
    function _isDead(address account, bytes memory coord) internal view override returns (bool) {
        uint256 tokenId = abi.decode(coord, (uint256));
        IEtherFiWithdrawRequestNFT nft = IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT);
        try nft.ownerOf(tokenId) returns (address o) {
            return o != account;
        } catch {}
        try nft.getRequest(tokenId) returns (IEtherFiWithdrawRequestNFT.WithdrawRequest memory r) {
            return r.amountOfEEth == 0 && r.shareOfEEth == 0;
        } catch {
            return false;
        }
    }

    /// @inheritdoc AssistedCoordCache
    /// @notice ONE native-ETH `Supplied` leg for the owned cached request; `isLocked = !finalized`.
    /// @dev Mirrors ether.fi's claim math: finalized → `getClaimableAmount`; pending →
    ///      `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei`.
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        uint256 tokenId = abi.decode(coord, (uint256));
        (uint256 owed, bool finalized) = _owedForToken(account, tokenId);
        if (owed == 0) return new INAVCalculator.PositionBalance[](0);
        INAVCalculator.PositionBalance[] memory legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: owed,
            isDebt: false,
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: abi.encode(WITHDRAW_REQUEST_NFT),
            positionKind: PositionKind.Supplied,
            isLocked: !finalized,
            positionInstanceId: bytes32(tokenId)
        });
        return legs;
    }

    /// @dev Ownership read wrapping `ownerOf` so a claimed / burned / non-existent id returns `(0, false)`.
    function _ownerOf(uint256 tokenId) internal view returns (address owner, bool ok) {
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @dev ETH owed for a single request and whether it is finalized. 0 if not live / not owned by `account`. All
    ///      external reads try/catch to 0.
    function _owedForToken(address account, uint256 tokenId) internal view returns (uint256 owed, bool finalized) {
        IEtherFiWithdrawRequestNFT nft = IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT);

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
