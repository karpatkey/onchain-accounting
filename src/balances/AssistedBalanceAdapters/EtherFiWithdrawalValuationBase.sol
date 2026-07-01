// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title EtherFiWithdrawalValuationBase
/// @author KPK
/// @notice Feeder-agnostic valuation core for ether.fi withdrawal-queue adapters: the ether.fi contract addresses,
///         the position-identity constants, and the per-request live valuation math ({_owedForToken}) that mirrors
///         ether.fi's own claim computation. Factored out so a cache/feeder layer (assistant-fed or wrapper-fed) can
///         be layered on top without duplicating the valuation — the wrapper-fed
///         {EtherFiWithdrawalQueueBalanceAdapter} builds on this. Mirrors the intent of
///         `NexusMutualStakingValuationBase` for its family.
/// @dev Holds only immutables + pure/library reads; contributes **no** access control and **no** cache — those come
///      from the feeder layer. The valuation stores nothing: every read is live and re-verifies ownership, so the
///      feeder can only under-report (ADR 0015 / 0020). Requesting a withdrawal burns eETH/weETH and mints a
///      `WithdrawRequestNFT`; the queued ETH is then invisible to a pure-view NAV scan (the NFT is not
///      `ERC721Enumerable`), which is why a feeder must supply the account's `tokenId`s.
abstract contract EtherFiWithdrawalValuationBase {
    /// @notice Position-identity taxonomy — identical to the assistant-fed sibling so both adapters report the same
    ///         ether.fi withdrawal-queue identity (`etherfi` / `etherfi-withdrawal`).
    bytes32 internal constant PROTOCOL_BRAND = ProtocolIds.ETHERFI;
    bytes32 internal constant PROTOCOL_ID = ProtocolIds.ETHERFI;
    bytes32 internal constant PROTOCOL_SUB_ID = ProtocolIds.ETHERFI_WITHDRAWAL;

    /// @notice ether.fi WithdrawRequestNFT (mainnet `0x7d57…4E2c`). Source of ownership + per-request data.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice ether.fi LiquidityPool — `amountForShare` converts a request's locked shares to current ETH.
    address public immutable LIQUIDITY_POOL;

    /// @notice NAVCalculator — used to look up the registered native-ETH Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    constructor(address withdrawRequestNft_, address liquidityPool_, address navCalculator_) {
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

    /// @dev ETH owed for a single request and whether it is finalized (claimable). `owed` is 0 if the request is
    ///      not live / not owned by `account` / invalid (and `finalized` is false in those cases). Mirrors ether.fi's
    ///      own claim math: finalized → exact `getClaimableAmount`; pending → the protocol's
    ///      `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei` estimate. All external reads try/catch to 0, so
    ///      this never reverts — a claimed/burned id (whose `ownerOf` reverts) simply values to 0.
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
