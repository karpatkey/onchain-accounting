// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Pool,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";

/// @notice Minimal Uniswap V3 factory interface — resolves the canonical pool address for a `(token0, token1, fee)`
///         triple. PancakeSwap V3's factory shares this `getPool` signature, so the assisted subclass needs no
///         override. Each fee tier is its own deployed pool contract, so the pool address uniquely identifies the
///         pair+fee — which is why it is used as the `positionId`.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title Uniswap V3 Pools Balance Adapter (id-cached, assisted)
/// @author KPK
/// @notice Reports an account's Uniswap V3 LP across *any* pool — the in-range liquidity (`Supplied`) and the
///         unclaimed fees (`Fees`) of the account's NFT positions. The NonfungiblePositionManager (NPM)
///         is not `ERC721Enumerable`-discoverable cheaply at scale, so rather than brute-forcing every NFT the
///         account holds, an off-chain assistant (holder of `ASSISTANT_ROLE`) submits the account's `tokenId`s via
///         `submitTokenIds`. This adapter then values them entirely from live on-chain reads, re-verifying NFT
///         ownership on every read. The cache stores **only ids, never amounts** — a faulty or compromised assistant
///         cannot fabricate value; at worst it omits an id (NAV under-counts), never over-counts. positionId is the
///         **pool contract address** (`abi.encode(factory.getPool(token0, token1, fee))`) — each fee tier is its own
///         deployed pool, so it uniquely identifies the pair+fee. The NFT id is not in positionId; it is carried as
///         the typed `positionInstanceId` on each emitted leg (not a label — labels are the verbose-only
///         `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]` breadcrumb via {IPositionDescribable.positionLabels}).
/// @dev Access control comes from {AssistedBalanceAdapter}: `DEFAULT_ADMIN_ROLE` administers roles and
///      `ASSISTANT_ROLE` gates the submit/clear mutators. `submitTokenIds` **reverts** `NotTokenOwner` for any id not
///      currently owned by the account (fail-loud writes); reads instead **discard** an id whose ownership changed or
///      whose NFT was burned (fail-open, so a single stale id never zeroes the whole account). See
///      `docs/decisions/0015-assisted-balance-adapter-family.md` (and the Merkl precedent, ADR 0007).
/// @dev Valuation = **instantaneous on-chain amounts** (ADR 0017). The in-range split is computed from the pool's
///      current `slot0().sqrtPriceX96`/`tick` (read live via the `_slot0` hook) and the position's `liquidity` — the
///      true token0/token1 composition you would withdraw at this block — and fees are the full unclaimed amount
///      (`feeGrowthInside`-since-poke + settled `tokensOwed`), correct only against the pool's REAL tick. This is the
///      same "report instantaneous amounts, NAVCalculator prices them with external oracles" model the V2/Curve/
///      Balancer LP adapters use. Imbalancing the pool can transiently move the reported amounts, but it cannot be
///      monetised: NAV is a read-only oracle consumed by an **asynchronous** sub/redeem layer (no atomic on-chain
///      consumer), and a forced imbalance is a donation that arbitrage reverses within a block — see ADR 0017 for the
///      full analysis and the revisit trigger (reinstate the oracle-reconstructed `sqrtPriceX96` only if NAV is ever
///      consumed synchronously on-chain). NOTE: this deliberately reinstates the `slot0` read that audit `[2]` once
///      replaced with oracle reconstruction; the async-consumer model (ADR 0017) supersedes that recommendation.
/// @dev `_slot0` is `virtual`: it reads `(sqrtPriceX96, tick)` from `IUniswapV3Pool(pool).slot0()`. PancakeSwap V3's
///      `slot0().feeProtocol` is `uint32` (not Uniswap's `uint8`), so the full-tuple decode differs — the
///      `PancakeSwapV3PoolsAssistedBalanceAdapter` subclass overrides `_slot0` with a matching ABI.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts, FixedPoint128 via
///      `UniswapV3PoolLib`) — combined work is GPL-2.0-or-later (ADR 0008).
contract UniswapV3PoolsAssistedBalanceAdapter is AssistedBalanceAdapter, IPositionDescribable {
    using Strings for uint256;

    //
    // State
    //

    /// @notice Hard cap on cached tokenIds per account. `getAdapterPositions` iterates the whole array on every NAV
    ///         read — each id costing an external `this.positionLegs` staticcall plus that position's live reads
    ///         (`slot0` + `positions`, and for an in-range position two `ticks()` + two `feeGrowthGlobal` reads) —
    ///         and an OOG there is NOT caught by NAVCalculator's try/catch, so a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the assistant must
    ///         GC closed positions (`clearTokenId`) to stay under it. A real account holds a handful of positions,
    ///         far below 256; NAV is also consumed asynchronously / off-chain (ADR 0017), so this is a belt-and-
    ///         suspenders bound rather than a hot on-chain path.
    uint256 public constant MAX_TOKEN_IDS = 256;

    /// @notice The Uniswap V3 NonfungiblePositionManager (chain-level constant; same for all V3 pools on a chain).
    address public immutable POSITION_MANAGER;

    /// @notice The Uniswap V3 factory (read once from the NPM at construction). Resolves the pool address used as
    ///         the `positionId` via `getPool(token0, token1, fee)`.
    address public immutable FACTORY;

    /// @notice NAVCalculator reference, used for the registered-asset registry and oracle price reads.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Human-readable protocol name for IPositionDescribable (e.g. "Uniswap V3"). Set once at construction.
    string internal _protocolName;

    /// @notice Candidate NFT tokenIds cached per account (the only thing the assistant supplies).
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

    /// @param positionManager_ The NonfungiblePositionManager address (per-chain canonical NPM). Must be a contract.
    /// @param protocolName_    Human-readable protocol name (e.g. "Uniswap V3").
    /// @param navCalculator_   The NAVCalculator contract for asset-registry + price access. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`). Required.
    /// @param assistant_       Initial holder of `ASSISTANT_ROLE`, authorized to submit/clear tokenIds. Optional
    ///                         (pass `address(0)` to grant later via `admin_`).
    constructor(
        address positionManager_,
        string memory protocolName_,
        address navCalculator_,
        address admin_,
        address assistant_
    ) AssistedBalanceAdapter(admin_, assistant_) {
        if (positionManager_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        require(positionManager_.code.length > 0, "PositionManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");
        POSITION_MANAGER = positionManager_;
        FACTORY = INonfungiblePositionManager(positionManager_).factory();
        // Fail deployment early on a misconfigured NPM: a zero/EOA factory would make every getPool() call revert
        // (ABI-decode on empty returndata) and brick this adapter's NAV reads.
        require(FACTORY.code.length > 0, "Factory must be a contract");
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        _protocolName = protocolName_;
    }

    //
    // Mutators (onlyRole(ASSISTANT_ROLE))
    //

    /// @notice Submit `account`'s **complete** set of candidate NFT tokenIds — this **replaces** the account's
    ///         cached set entirely (the prior ids are dropped first), so the assistant always submits the full list
    ///         to be considered, not a delta. Duplicates within the list collapse (dedup). **Reverts** `NotTokenOwner`
    ///         if any id is not currently owned by `account` and `TokenIdCacheFull` past `MAX_TOKEN_IDS` — writes are
    ///         fail-loud, and because they revert atomically, a bad list leaves the prior set untouched. Correctness
    ///         does not depend on the ownership check (reads re-verify and value only live, owned positions).
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyRole(ASSISTANT_ROLE) {
        _submit(account, abi.encode(tokenIds)); // friendly typed wrapper → shared replace chokepoint (base)
    }

    /// @notice Batch variant: for each account, its sublist **replaces** that account's cached set. `accounts` and
    ///         `tokenIds` must have the same length.
    function submitTokenIdsBatch(address[] calldata accounts, uint256[][] calldata tokenIds)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        bytes[] memory data = new bytes[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            data[i] = abi.encode(tokenIds[i]);
        }
        _submitBatch(accounts, data);
    }

    /// @inheritdoc AssistedBalanceAdapter
    /// @dev Decodes the `uint256[]` token-id list and replaces `account`'s cached set (clear then re-add, fail-loud).
    function _applyReplace(address account, bytes memory data) internal override {
        uint256[] memory ids = abi.decode(data, (uint256[]));
        _clearTokenIds(account);
        for (uint256 i; i < ids.length; ++i) {
            _addTokenId(account, ids[i]);
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for closed/transferred positions (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyRole(ASSISTANT_ROLE) {
        if (_tokenIdIdxPlus1[account][tokenId] == 0) return;
        _removeTokenId(account, tokenId);
        emit TokenIdCleared(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`.
    function clearAccount(address account) external onlyRole(ASSISTANT_ROLE) {
        _clearTokenIds(account);
        emit AccountCleared(account);
    }

    /// @dev Delete the account's cached id set (storage only, no event). Shared by `clearAccount` and the
    ///      replace-on-submit path.
    function _clearTokenIds(address account) private {
        uint256[] storage ids = _tokenIds[account];
        for (uint256 i; i < ids.length; ++i) {
            delete _tokenIdIdxPlus1[account][ids[i]];
        }
        delete _tokenIds[account];
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account];
    }

    /// @notice Protocol identifier reported on every emitted position. `virtual` so byte-compatible forks
    ///         (PancakeSwap V3) report their own slug while sharing the `abi.encode(address pool)` positionId
    ///         schema. Defaults to `uniswap-v3`.
    function _protocolId() internal pure virtual returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    /// @notice Protocol brand (broadest layer) reported on every emitted position. `virtual` so byte-compatible
    ///         forks (PancakeSwap V3) report their own brand. Defaults to `uniswap`.
    function _protocolBrand() internal pure virtual returns (bytes32) {
        return ProtocolIds.UNISWAP;
    }

    /// @notice Protocol sub-identifier (the specific product) reported on every emitted position. `virtual` so
    ///         byte-compatible forks (PancakeSwap V3) report their own slug. For the V3 adapters the ecosystem and
    ///         the sub are the same value. Defaults to `uniswap-v3`.
    function _protocolSubId() internal pure virtual returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the family's base advertisement
    ///      ({IAssistedBalanceAdapter}/{IBalanceAdapter}/{IAccessControl}/{IERC165}).
    function supportsInterface(bytes4 interfaceId) public view override(AssistedBalanceAdapter) returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external view returns (string memory) {
        return _protocolName;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Open-universe adapter: Uniswap V3 LP can pair any registered assets, so the universe of supported
    ///         assets is not enumerable ahead of time and this returns an empty array (same rationale as
    ///         `MerklRewardsAssistedBalanceAdapter`; registration only needs `supportsInterface(IBalanceAdapter)`).
    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    /// @inheritdoc IBalanceAdapter
    /// @dev For each cached tokenId still owned by `account`, emits up to 4 legs: `Supplied` x2 (in-range liquidity)
    ///      and `Fees` x2 (full unclaimed: feeGrowth-since-poke + settled `tokensOwed`) — dropping zeros,
    ///      unregistered/unpriced assets, and ids no longer owned, respecting `assetFilter`. positionId =
    ///      abi.encode(pool) (the stable pool address); the NFT id rides
    ///      in the typed `positionInstanceId` on each leg (an account's NFTs in the same pool share the positionId).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256[] memory ids = _tokenIds[account];
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Fetch the registry snapshot ONCE for the whole read (a single `getRegisteredAssets()` cross-contract call,
        // not one per NFT). It is then re-encoded into calldata on each `this.positionLegs(account, reg, ...)`
        // self-call below, so the per-NFT registry cost is the ABI copy, not a fresh fetch — the snapshot read itself
        // stays O(1) in the number of NFTs. (Any per-NFT blow-up is bounded by NAVCalculator's per-adapter try/catch,
        // which fails open and drops only this adapter's positions.)
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();

        // Up to 4 legs per NFT (liq0, liq1, fee0, fee1).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](ids.length * 4);
        uint256 count;

        for (uint256 i; i < ids.length; ++i) {
            // Per-NFT fault isolation (fail-open, ADR 0015): value each id behind an external `this.` call so a
            // revert in its live reads (slot0 / positions / ticks / feeGrowth on an exotic or stale pool) is caught
            // here and that ONE id is discarded — it never propagates out of getAdapterPositions, where
            // NAVCalculator's per-adapter try/catch would otherwise fail-open and drop the account's ENTIRE V3 set.
            // Mirrors the meta-adapter's `try this.instancePositions(...)` fan-out.
            try this.positionLegs(account, reg, ids[i], assetFilter) returns (
                INAVCalculator.PositionBalance[] memory legs
            ) {
                for (uint256 j; j < legs.length; ++j) {
                    temp[count++] = legs[j];
                }
            } catch {}
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
        return positions;
    }

    //
    // Internal — write
    //

    function _addTokenId(address account, uint256 tokenId) internal {
        if (_tokenIdIdxPlus1[account][tokenId] != 0) return; // already cached (idempotent no-op)
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The assistant
        // must GC closed positions (`clearTokenId`) to make room; a real account never approaches MAX_TOKEN_IDS open
        // positions. **Revert** rather than silently dropping the id — writes are fail-loud (like the ownership
        // check below), so a full cache surfaces to the assistant instead of silently omitting an owned position.
        if (_tokenIds[account].length >= MAX_TOKEN_IDS) revert TokenIdCacheFull(account, MAX_TOKEN_IDS);
        // Fail-loud ownership check: a non-owned (or burned) id is a caller mistake. `ownerOf` reverts for a
        // non-existent token; surface that as NotTokenOwner too.
        try INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId) returns (address o) {
            if (o != account) revert NotTokenOwner(account, tokenId);
        } catch {
            revert NotTokenOwner(account, tokenId);
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

    /// @notice Values one cached `tokenId` into its (up to 4) legs: `Supplied` x2 (in-range split) + `Fees` x2 (full
    ///         unclaimed). Returns an empty array if the id is not owned by `account`, its pool tokens are
    ///         unregistered, the triple has no canonical pool, or nothing is in the requested `assetFilter`.
    /// @dev `external` so `getAdapterPositions` can invoke it via `this.` inside a per-NFT try/catch — a revert in
    ///      any live read (slot0 / positions / ticks / feeGrowth) is then isolated to this one id (fail-open). Reads
    ///      `token0/token1/fee` from `positions(tokenId)`, resolves the pool, and values it from the pool's live
    ///      `slot0` (in-range split) + full unclaimed fees (see contract @dev / ADR 0017). NOT meant for external
    ///      callers; it is `external` only to enable the self-call isolation.
    function positionLegs(address account, INAVCalculator.Asset[] calldata reg, uint256 tokenId, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized(); // self-call-only (external solely for try/catch isolation)
        INAVCalculator.PositionBalance[] memory none = new INAVCalculator.PositionBalance[](0);

        // Re-verify ownership: a burned id reverts `ownerOf` (caught by the caller's try/catch → discarded); a
        // transferred id returns a different owner → empty.
        if (INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId) != account) return none;

        UniswapV3PoolLib.Position memory p = UniswapV3PoolLib.readPosition(POSITION_MANAGER, tokenId);

        // Both tokens must be registered for NAV to price the legs. `reg` is the registry snapshot fetched once by
        // `getAdapterPositions`; resolve both tokens from it. `assetFilter` only gates which legs are emitted below.
        (INAVCalculator.Asset memory a0, bool reg0) = RegisteredAssetLib.find(reg, p.token0);
        (INAVCalculator.Asset memory a1, bool reg1) = RegisteredAssetLib.find(reg, p.token1);
        if (!reg0 || !reg1) return none;
        bool f0reg = assetFilter == address(0) || assetFilter == p.token0;
        bool f1reg = assetFilter == address(0) || assetFilter == p.token1;
        if (!f0reg && !f1reg) return none;

        // positionId = the pool contract address (each (token0, token1, fee) is its own deployed Uniswap V3 pool).
        // The NFT id is NOT in the positionId; it rides in the typed `positionInstanceId` (set below). Drop the
        // position if the factory has no canonical pool for the triple (defensive: never emit a zero-pool identity
        // that collides across pools).
        address pool = IUniswapV3Factory(FACTORY).getPool(p.token0, p.token1, p.fee);
        if (pool == address(0)) return none;

        // Value from the pool's live slot0 (ADR 0017 — instantaneous on-chain amounts): `sqrtPriceX96` drives the
        // in-range principal split and `tick` selects the fee-growth branch for the full unclaimed-fee computation.
        // `_slot0` is virtual so PancakeSwap V3's `uint32 feeProtocol` ABI is handled by the subclass.
        (uint160 sqrtPriceX96, int24 tick) = _slot0(pool);
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) =
            UniswapV3PoolLib.positionAmounts(pool, p, sqrtPriceX96, tick);

        bytes memory positionId = abi.encode(pool);
        // The NFT id is the EPHEMERAL per-item coordinate — carried as the typed `positionInstanceId`, NOT a label
        // and NOT in positionId (which is the stable pool address; all of an account's NFTs in this pool share it).
        // The display breadcrumb is derived from positionId by `positionLabels`.
        bytes32 instanceId = bytes32(tokenId);

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](4);
        uint256 n;
        if (f0reg && liq0 > 0) tmp[n++] = _row(a0, liq0, positionId, PositionKind.Supplied, instanceId);
        if (f1reg && liq1 > 0) tmp[n++] = _row(a1, liq1, positionId, PositionKind.Supplied, instanceId);
        if (f0reg && fee0 > 0) tmp[n++] = _row(a0, fee0, positionId, PositionKind.Fees, instanceId);
        if (f1reg && fee1 > 0) tmp[n++] = _row(a1, fee1, positionId, PositionKind.Fees, instanceId);

        INAVCalculator.PositionBalance[] memory out = new INAVCalculator.PositionBalance[](n);
        for (uint256 k; k < n; ++k) {
            out[k] = tmp[k];
        }
        return out;
    }

    /// @dev Reads `(sqrtPriceX96, tick)` from the pool's `slot0`. `virtual` so a fork with a divergent `slot0()` ABI
    ///      overrides just this read — `PancakeSwapV3PoolsAssistedBalanceAdapter` does so for PancakeSwap V3's `uint32`
    ///      `feeProtocol` field (Uniswap V3 packs it as `uint8`).
    function _slot0(address pool) internal view virtual returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]` (e.g. `["AMM Liquidity Pool", "USDC/WETH 0.3%"]`) — the
    ///      leaf is read live from the pool decoded out of `positionId` (token0/token1 symbols + fee tier). An
    ///      unreadable symbol falls back to "?"; a reverting pool falls back to just `["AMM Liquidity Pool"]`. The
    ///      per-NFT id is the typed `positionInstanceId` on each leg, NOT a label. Empty for a short/malformed positionId.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory out) {
        if (positionId.length < 32) return new string[](0);
        string memory leaf = _poolLeaf(abi.decode(positionId, (address)));
        if (bytes(leaf).length == 0) {
            out = new string[](1);
            out[0] = "AMM Liquidity Pool";
            return out;
        }
        out = new string[](2);
        out[0] = "AMM Liquidity Pool";
        out[1] = leaf;
    }

    /// @dev "<sym0>/<sym1> <fee>%" read live from the pool (e.g. "USDC/WETH 0.3%"); "" if a core pool read reverts.
    function _poolLeaf(address pool) private view returns (string memory) {
        uint24 fee;
        try IUniswapV3Pool(pool).fee() returns (uint24 f) {
            fee = f;
        } catch {
            return "";
        }
        address t0;
        address t1;
        try IUniswapV3Pool(pool).token0() returns (address a) {
            t0 = a;
        } catch {
            return "";
        }
        try IUniswapV3Pool(pool).token1() returns (address a) {
            t1 = a;
        } catch {
            return "";
        }
        return string.concat(_symbol(t0), "/", _symbol(t1), " ", _feePercent(fee), "%");
    }

    /// @dev ERC20 symbol with a "?" fallback for non-standard tokens (e.g. bytes32 symbols) or reverts.
    function _symbol(address token) private view returns (string memory) {
        return LabelLib.symbol(token, "?");
    }

    /// @dev Formats a V3 fee (hundredths of a bip: 3000 = 0.3%, 500 = 0.05%, 100 = 0.01%, 10000 = 1%) as a percentage
    ///      string with trailing zeros trimmed.
    function _feePercent(uint24 fee) private pure returns (string memory) {
        uint256 whole = uint256(fee) / 10000;
        uint256 frac = uint256(fee) % 10000; // ten-thousandths of a percent
        if (frac == 0) return whole.toString();
        bytes memory f = bytes(frac.toString());
        bytes memory padded = new bytes(4); // frac < 10000, so it fits in 4 digits
        uint256 lead = 4 - f.length;
        for (uint256 i = 0; i < 4; i++) {
            padded[i] = i < lead ? bytes1("0") : f[i - lead];
        }
        uint256 end = 4;
        while (padded[end - 1] == bytes1("0")) {
            end--; // frac != 0 guarantees a non-zero digit, so this never underflows
        }
        bytes memory trimmed = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            trimmed[i] = padded[i];
        }
        return string.concat(whole.toString(), ".", string(trimmed));
    }

    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bytes memory positionId,
        PositionKind kind,
        bytes32 positionInstanceId
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: _protocolBrand(),
            protocolId: _protocolId(),
            protocolSubId: _protocolSubId(),
            positionId: positionId,
            positionKind: kind,
            isLocked: false, // LP liquidity + settled fees are always withdrawable now
            positionInstanceId: positionInstanceId
        });
    }
}
