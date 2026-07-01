// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ether.fi Withdrawals Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue. Requesting a withdrawal burns
///         eETH/weETH and mints a `WithdrawRequestNFT`; the queued ETH is then invisible to a pure-view NAV scan (the
///         NFT is not `ERC721Enumerable` and exposes no owner→tokenIds view). A trusted **wrapper contract** (holder of
///         `WRAPPER_ROLE` — the `EtherFiWithdrawalQueueWrapper`) pushes/pops the account's `requestId`s via
///         `submit` / `remove` / `pruneStale` **atomically as it forwards the withdrawal request/claim**, so the id
///         cache is kept current on-chain in the same transaction — no off-chain agent. This adapter values each cached
///         id entirely from live on-chain reads, re-verifying ownership on every read. The cache stores **only ids,
///         never amounts**, so the wrapper cannot fabricate value — at worst it omits an id (NAV under-counts), never
///         over-counts.
/// @dev Self-contained (no shared base contracts — the family abstractions will be re-extracted later). It is a member
///      of the assisted balance-adapter family (ADR 0015) in its **wrapper-fed** form: `DEFAULT_ADMIN_ROLE` administers
///      `WRAPPER_ROLE`, which is the sole mutator of the id cache. Supersedes the earlier off-chain-agent
///      (`ASSISTANT_ROLE`) ether.fi adapter of ADR 0014. The family invariant holds: cache ids only, value live,
///      re-verify ownership per read → the wrapper can only under-report. Trust model + rationale:
///      `docs/decisions/0020-wrapper-fed-etherfi-withdrawal-queue.md`. Emits ONE native-ETH `Supplied` leg per owned
///      cached withdrawal request, all sharing a single static `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`; each
///      leg's `isLocked` reflects that request's own state (finalized → `false`, pending → `true`) and its `tokenId`
///      rides in the typed `positionInstanceId`, never in `positionId`.
contract EtherFiWithdrawalQueueAssistedBalanceAdapter is AccessControl, IBalanceAdapter, IPositionDescribable {
    using EnumerableSet for EnumerableSet.UintSet;

    //
    // Roles / constants
    //

    /// @notice Role allowed to feed the cache (submit/remove/pruneStale). Held by the wrapper contract.
    bytes32 public constant WRAPPER_ROLE = keccak256("WRAPPER_ROLE");

    /// @notice Hard cap on cached tokenIds per account. `_owedAmount` / `getAdapterPositions` iterate the whole set on
    ///         every NAV read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would
    ///         brick the account's NAV scan. Bounding the cache at submit time keeps reads gas-bounded; the wrapper GCs
    ///         claimed ids via {pruneStale}. A real account never approaches 256 open requests.
    uint256 public constant MAX_TOKEN_IDS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.ETHERFI;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.ETHERFI_WITHDRAWAL;

    //
    // Immutables
    //

    /// @notice ether.fi WithdrawRequestNFT (mainnet `0x7d57…4E2c`). Source of ownership + per-request data.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice ether.fi LiquidityPool — `amountForShare` converts a request's locked shares to current ETH.
    address public immutable LIQUIDITY_POOL;

    /// @notice The single asset this adapter reports (native-ETH sentinel — what ether.fi pays on claim).
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered native-ETH Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Cache
    //

    /// @notice Candidate `WithdrawRequestNFT` tokenIds cached per account (the only thing the wrapper supplies). An
    ///         `EnumerableSet.UintSet` gives dedup, O(1) membership/removal, and `values()` enumeration.
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool (for `amountForShare`). Must be a contract.
    /// @param underlyingToken_    Payout asset (native-ETH sentinel). Must be non-zero.
    /// @param navCalculator_      NAVCalculator. Must be a contract.
    /// @param admin_              Holder of `DEFAULT_ADMIN_ROLE` (administers `WRAPPER_ROLE`). Required.
    /// @param wrapper_            Initial holder of `WRAPPER_ROLE` — the `EtherFiWithdrawalQueueWrapper`. Optional (pass
    ///                            `address(0)` and grant after the wrapper is deployed, since the wrapper needs this
    ///                            adapter's address at construction).
    constructor(
        address withdrawRequestNft_,
        address liquidityPool_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address wrapper_
    ) {
        if (
            withdrawRequestNft_ == address(0) || liquidityPool_ == address(0) || underlyingToken_ == address(0)
                || navCalculator_ == address(0) || admin_ == address(0)
        ) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        LIQUIDITY_POOL = liquidityPool_;
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (wrapper_ != address(0)) _grantRole(WRAPPER_ROLE, wrapper_);
    }

    //
    // Writes (WRAPPER_ROLE)
    //

    /// @notice Track `tokenId` for `account` (idempotent). Called by the wrapper right after it forwards a request that
    ///         minted the WithdrawRequestNFT. **Reverts** `NotTokenOwner` if `tokenId` is not currently owned by
    ///         `account`, and `TokenIdCacheFull` if a new id would grow the set past the cap.
    function submit(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        _addTokenId(account, tokenId);
    }

    /// @notice Stop tracking `tokenId` for `account` (idempotent — a no-op if not cached).
    function remove(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        _removeTokenId(account, tokenId);
    }

    /// @notice Drop `tokenId` from `account`'s cache **only if** it is no longer owned by `account` (burned on claim,
    ///         transferred away, or non-existent). `WRAPPER_ROLE`-gated like {submit}/{remove} — the wrapper is the sole
    ///         cache mutator — but it additionally verifies the id is provably stale, so it can only ever GC a dead
    ///         entry, never delete a live position. The wrapper reaches this from a delegatecalled `claimWithdraw` via a
    ///         regular self-call so the caller here is the wrapper (the role holder), not the depositor Safe.
    /// @dev **Reverts** `NotTokenOwner` if `tokenId` is still owned by `account` (nothing to prune).
    function pruneStale(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        (address owner, bool ok) = _ownerOf(tokenId);
        if (ok && owner == account) revert NotTokenOwner(account, tokenId);
        _removeTokenId(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`. Admin-gated rescue (e.g. to reset a mis-fed account); the normal
    ///         path is the wrapper's per-position {submit}/{remove}.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
        emit AccountCleared(account);
    }

    //
    // Reads
    //

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account].values();
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
        return (_owedAmount(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 total = account == address(0) ? 0 : _owedAmount(account);
        if (total == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE native-ETH `Supplied` leg per owned cached withdrawal request, all sharing the static
    ///         `positionId = abi.encode(WITHDRAW_REQUEST_NFT)`. Each leg's `isLocked` reflects that request's state
    ///         (finalized → `false`, pending → `true`) and its `tokenId` is the typed `positionInstanceId`.
    /// @dev Each cached id is valued live from on-chain reads (`_owedForToken`), re-verifying ownership every read:
    ///      requests not owned by `account` / invalid / claimed / burned value to 0 and emit no leg. Zero-amount legs
    ///      are skipped. Dropped entirely if the underlying asset is not registered in NAVCalculator.
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

        uint256[] memory ids = _tokenIds[account].values();
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

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure override returns (string memory) {
        return "ether.fi";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "eETH"]` — category + the receipt-token symbol. All requests share the queue
    ///      `positionId`; the per-request WithdrawRequestNFT id is the typed `positionInstanceId`, NOT here.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "eETH";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //
    // Internal — cache mutation
    //

    /// @dev Add a single id (idempotent; cap + fail-loud ownership check). Re-adding an already-cached id is a no-op.
    function _addTokenId(address account, uint256 tokenId) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        if (set.contains(tokenId)) return;
        if (set.length() >= MAX_TOKEN_IDS) revert TokenIdCacheFull(account, MAX_TOKEN_IDS);
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        set.add(tokenId);
        emit TokenIdSubmitted(account, tokenId);
    }

    /// @dev Drop a cached tokenId. Idempotent — no event when the id was not cached.
    function _removeTokenId(address account, uint256 tokenId) private {
        if (_tokenIds[account].remove(tokenId)) emit TokenIdCleared(account, tokenId);
    }

    //
    // Internal — valuation
    //

    /// @dev Total ETH owed across the account's cached tokenIds, valued from live on-chain reads. Never reverts.
    function _owedAmount(address account) internal view returns (uint256 total) {
        uint256[] memory ids = _tokenIds[account].values();
        for (uint256 i; i < ids.length; ++i) {
            (uint256 owed,) = _owedForToken(account, ids[i]);
            total += owed;
        }
    }

    /// @dev Ownership read for the write-time check and {pruneStale}: wraps `ownerOf` so a claimed / burned /
    ///      non-existent id (which `ownerOf` reverts on) returns `(0, false)` rather than bubbling.
    function _ownerOf(uint256 tokenId) private view returns (address, bool) {
        try IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).ownerOf(tokenId) returns (address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @dev ETH owed for a single request and whether it is finalized (claimable). `owed` is 0 if the request is not
    ///      live / not owned by `account` / invalid. Mirrors ether.fi's own claim math: finalized → exact
    ///      `getClaimableAmount`; pending → `min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei`. All external
    ///      reads try/catch to 0, so this never reverts.
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
