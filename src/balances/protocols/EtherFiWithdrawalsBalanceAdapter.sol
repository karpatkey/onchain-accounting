// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
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
///         positions). An off-chain agent submits the account's `tokenId`s via `submitTokenIds`; this adapter then
///         values them entirely from live on-chain reads, re-verifying ownership on every read. The cache stores
///         **only ids, never amounts**, so the owner cannot fabricate value — at worst it omits an id (NAV
///         under-counts), never over-counts.
/// @dev Trust model and mutability rationale: see `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`
///      (generalises the Merkl precedent, ADR 0007). One aggregated native-ETH `Supplied` leg per account.
contract EtherFiWithdrawalsBalanceAdapter is IBalanceAdapter, Ownable, IPositionDescribable {
    //
    // State
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.ETHERFI_WITHDRAWAL;

    /// @notice Hard cap on cached tokenIds per account. `_ethOwed` iterates the whole array on every NAV read,
    ///         and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the agent must
    ///         GC claimed ids (`clearTokenId`) to stay under it. A real account never approaches 256 open requests.
    uint256 public constant MAX_TOKEN_IDS = 256;

    /// @notice ether.fi WithdrawRequestNFT (mainnet `0x7d57…4E2c`). Source of ownership + per-request data.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice ether.fi LiquidityPool — `amountForShare` converts a request's locked shares to current ETH.
    address public immutable LIQUIDITY_POOL;

    /// @notice Underlying asset the queue pays out, native ETH (sentinel). Must be a registered NAV asset.
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered native-ETH Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Candidate withdrawal-request tokenIds cached per account (the only thing the owner supplies).
    mapping(address account => uint256[] tokenIds) private _tokenIds;

    /// @dev `idxPlus1` = index of `tokenId` in `_tokenIds[account]` plus 1. Zero ⇒ not present (dedup + O(1) removal).
    mapping(address account => mapping(uint256 tokenId => uint256)) private _tokenIdIdxPlus1;

    //
    // Events
    //

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    //
    // Constructor
    //

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param underlyingToken_    Payout asset (native-ETH sentinel).
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    /// @param initialOwner_       Owner authorized to submit/clear tokenIds (the OIV Safe / agent role).
    constructor(
        address withdrawRequestNft_,
        address liquidityPool_,
        address underlyingToken_,
        address navCalculator_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (
            withdrawRequestNft_ == address(0) || liquidityPool_ == address(0) || underlyingToken_ == address(0)
                || navCalculator_ == address(0)
        ) {
            revert InvalidArguments();
        }
        require(withdrawRequestNft_.code.length > 0, "WithdrawRequestNFT must be a contract");
        require(liquidityPool_.code.length > 0, "LiquidityPool must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        LIQUIDITY_POOL = liquidityPool_;
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Mutators (onlyOwner)
    //

    /// @notice Add candidate withdrawal-request tokenIds for `account`. Idempotent (dedup). Ids not currently owned
    ///         by `account` are skipped at write time as light hygiene; correctness does not depend on it — reads
    ///         re-verify ownership every time and value only live, owned, valid requests.
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyOwner {
        if (account == address(0)) revert InvalidArguments();
        for (uint256 i; i < tokenIds.length; ++i) {
            _addTokenId(account, tokenIds[i]);
        }
    }

    /// @notice Batch variant across accounts. `accounts` and `tokenIds` must have the same length.
    function submitTokenIdsBatch(address[] calldata accounts, uint256[][] calldata tokenIds) external onlyOwner {
        if (accounts.length != tokenIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert InvalidArguments();
            for (uint256 j; j < tokenIds[i].length; ++j) {
                _addTokenId(accounts[i], tokenIds[i][j]);
            }
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for claimed/transferred requests (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyOwner {
        if (_tokenIdIdxPlus1[account][tokenId] == 0) return;
        _removeTokenId(account, tokenId);
        emit TokenIdCleared(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`.
    function clearAccount(address account) external onlyOwner {
        uint256[] storage ids = _tokenIds[account];
        for (uint256 i; i < ids.length; ++i) {
            delete _tokenIdIdxPlus1[account][ids[i]];
        }
        delete _tokenIds[account];
        emit AccountCleared(account);
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not staleness-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "ether.fi";
    }

    function describePosition(bytes calldata) external pure returns (string memory) {
        return "ETH Withdrawal Queue";
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        return (_ethOwed(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 owed = account == address(0) ? 0 : _ethOwed(account);
        if (owed == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = owed;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice One aggregated native-ETH `Supplied` leg = total ETH owed across the account's live, owned, valid
    ///         ether.fi withdrawal requests. `positionId` is empty (account-global, like the other WQ adapters).
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

        // Cheap path first: bail before fetching/scanning getRegisteredAssets when there is nothing owed
        // (the common case — no cached ids, or all stale/claimed).
        uint256 total = _ethOwed(account);
        if (total == 0) return new INAVCalculator.PositionBalance[](0);

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.Asset memory underlying;
        bool registered;
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == UNDERLYING_TOKEN) {
                underlying = reg[i];
                registered = true;
                break;
            }
        }
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: total,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: "",
            positionKind: PositionKind.Supplied
        });
    }

    //
    // Internal — write
    //

    function _addTokenId(address account, uint256 tokenId) internal {
        if (_tokenIdIdxPlus1[account][tokenId] != 0) return; // already cached
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The
        // owner must GC claimed ids to make room; a real account never approaches MAX_TOKEN_IDS open requests.
        if (_tokenIds[account].length >= MAX_TOKEN_IDS) return;
        // Light hygiene: only store ids currently owned by `account`. Not load-bearing — reads re-verify.
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            if (o != account) return;
        } catch {
            return;
        }
        _tokenIds[account].push(tokenId);
        _tokenIdIdxPlus1[account][tokenId] = _tokenIds[account].length;
        emit TokenIdSubmitted(account, tokenId);
    }

    function _removeTokenId(address account, uint256 tokenId) internal {
        uint256 idxPlus1 = _tokenIdIdxPlus1[account][tokenId];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        uint256[] storage list = _tokenIds[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            uint256 lastId = list[lastIdx];
            list[idx] = lastId;
            _tokenIdIdxPlus1[account][lastId] = idx + 1;
        }
        list.pop();
        delete _tokenIdIdxPlus1[account][tokenId];
    }

    //
    // Internal — valuation
    //

    /// @dev Total ETH owed across the account's cached tokenIds, valued from live on-chain reads. Never reverts.
    function _ethOwed(address account) internal view returns (uint256 total) {
        uint256[] memory ids = _tokenIds[account];
        for (uint256 i; i < ids.length; ++i) {
            total += _owedForToken(account, ids[i]);
        }
    }

    /// @dev ETH owed for a single request, or 0 if it is not live / not owned by `account` / invalid. Mirrors
    ///      ether.fi's own claim math: finalized → exact `getClaimableAmount`; pending → the protocol's
    ///      `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei` estimate. All external reads try/catch to 0.
    function _owedForToken(address account, uint256 tokenId) internal view returns (uint256) {
        IEtherFiWithdrawRequestNFT nft = IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT);

        // Ownership: a claimed/burned NFT makes ownerOf revert; a transferred one returns a different owner.
        try nft.ownerOf(tokenId) returns (address o) {
            if (o != account) return 0;
        } catch {
            return 0;
        }
        try nft.isValid(tokenId) returns (bool ok) {
            if (!ok) return 0;
        } catch {
            return 0;
        }

        bool finalized;
        try nft.isFinalized(tokenId) returns (bool f) {
            finalized = f;
        } catch {
            return 0;
        }

        if (finalized) {
            try nft.getClaimableAmount(tokenId) returns (uint256 claimable) {
                return claimable;
            } catch {
                return 0;
            }
        }

        // Pending: estimate the claimable ETH the way ether.fi computes it at claim time.
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory req;
        try nft.getRequest(tokenId) returns (IEtherFiWithdrawRequestNFT.WithdrawRequest memory r) {
            req = r;
        } catch {
            return 0;
        }
        uint256 byShare;
        try IEtherFiLiquidityPool(LIQUIDITY_POOL).amountForShare(req.shareOfEEth) returns (uint256 s) {
            byShare = s;
        } catch {
            return 0;
        }
        uint256 gross = uint256(req.amountOfEEth) < byShare ? uint256(req.amountOfEEth) : byShare;
        uint256 fee = uint256(req.feeGwei) * 1 gwei;
        return gross > fee ? gross - fee : 0;
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
