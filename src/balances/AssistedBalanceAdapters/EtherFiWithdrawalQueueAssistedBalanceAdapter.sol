// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedNftIdCache} from "./AssistedNftIdCache.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ether.fi Withdrawals Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue. Requesting a withdrawal burns
///         eETH/weETH and mints a `WithdrawRequestNFT`; the queued ETH is then invisible to a pure-view NAV scan (the
///         NFT is not `ERC721Enumerable`). The canonical feeder is `EtherFiWithdrawalQueueWrapper`, which the owner
///         Safe delegatecalls so the adapter sees `msg.sender = Safe = owner`: it pushes the `requestId` on
///         `requestWithdraw` and pops it on `claimWithdraw`, atomically. Each cached id is valued live, re-verifying
///         ownership every read; the cache stores **ids only, never amounts**.
/// @dev Permissionless wrapper-fed member ([ADR 0018](../../../docs/decisions/0018-wrapper-fed-assisted-balance-adapters.md)),
///      extending {AssistedNftIdCache} (single leg, internally-safe valuation → no self-call fan-out needed). Supersedes
///      the earlier off-chain-agent (ASSISTANT_ROLE) ether.fi adapter of ADR 0014. The default {_removable} (removable
///      iff no longer owned) is exactly right: ether.fi's `claimWithdraw` **burns** the NFT, so a claimed id is no
///      longer owned and becomes removable, while a still-pending (owned) id cannot be dropped (CoordinateStillLive) —
///      hence the wrapper claims first, then removes. Emits ONE native-ETH `Supplied` leg per owned cached request,
///      all sharing `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`; `isLocked = !finalized`; the tokenId rides in
///      `positionInstanceId`.
contract EtherFiWithdrawalQueueAssistedBalanceAdapter is AssistedNftIdCache, IPositionDescribable {
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
    constructor(address withdrawRequestNft_, address liquidityPool_, address underlyingToken_, address navCalculator_)
        AssistedNftIdCache(underlyingToken_, navCalculator_)
    {
        if (withdrawRequestNft_ == address(0) || liquidityPool_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        LIQUIDITY_POOL = liquidityPool_;
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

    /// @inheritdoc AssistedNftIdCache
    function _maxTokenIds() internal pure override returns (uint256) {
        return MAX_TOKEN_IDS;
    }

    /// @inheritdoc AssistedNftIdCache
    function _maxLegsPerId() internal pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AssistedNftIdCache
    /// @dev Wraps `ownerOf` so a claimed / burned / non-existent id (which `ownerOf` reverts on) returns `(0, false)`.
    function _ownerOf(uint256 tokenId) internal view override returns (address owner, bool ok) {
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @inheritdoc AssistedNftIdCache
    /// @notice ONE native-ETH `Supplied` leg for the owned cached request (finalized → `isLocked=false`, pending →
    ///         `true`); the tokenId rides in `positionInstanceId`, sharing `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`.
    /// @dev Mirrors ether.fi's claim math: finalized → exact `getClaimableAmount`; pending →
    ///      `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei`. All external reads try/catch to 0 (never reverts).
    function _valueTokenId(address account, uint256 tokenId, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
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

    /// @dev ETH owed for a single request and whether it is finalized (claimable). `owed` is 0 if not live / not owned
    ///      by `account` / invalid. All external reads try/catch to 0.
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
