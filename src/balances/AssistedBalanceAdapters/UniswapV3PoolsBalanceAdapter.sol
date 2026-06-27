// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {
    INonfungiblePositionManager,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";

/// @notice Minimal Uniswap V3 factory interface — resolves the canonical pool address for a `(token0, token1, fee)`
///         triple. PancakeSwap V3's factory shares this `getPool` signature, so the assisted subclass needs no
///         override. Each fee tier is its own deployed pool contract, so the pool address uniquely identifies the
///         pair+fee — which is why it is used as the `positionId`.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title Uniswap V3 Pools Balance Adapter (id-cached, assisted)
/// @author KPK
/// @notice Reports an account's Uniswap V3 LP across *any* pool — both the in-range liquidity (`Supplied`) and the
///         settled `tokensOwed` fees (`Fees`) of the account's NFT positions. The NonfungiblePositionManager (NPM)
///         is not `ERC721Enumerable`-discoverable cheaply at scale, so rather than brute-forcing every NFT the
///         account holds, an off-chain assistant (holder of `ASSISTANT_ROLE`) submits the account's `tokenId`s via
///         `submitTokenIds`. This adapter then values them entirely from live on-chain reads, re-verifying NFT
///         ownership on every read. The cache stores **only ids, never amounts** — a faulty or compromised assistant
///         cannot fabricate value; at worst it omits an id (NAV under-counts), never over-counts. positionId is the
///         **pool contract address** (`abi.encode(factory.getPool(token0, token1, fee))`) — each fee tier is its own
///         deployed pool, so it uniquely identifies the pair+fee. The NFT id is not in positionId; it is surfaced as
///         the last adapter-supplied display **label** (`["Liquidity Pool", "<pool>", "NFT #<id>"]`).
/// @dev Access control comes from {AssistedBalanceAdapter}: `DEFAULT_ADMIN_ROLE` administers roles and
///      `ASSISTANT_ROLE` gates the submit/clear mutators. `submitTokenIds` **reverts** `NotTokenOwner` for any id not
///      currently owned by the account (fail-loud writes); reads instead **discard** an id whose ownership changed or
///      whose NFT was burned (fail-open, so a single stale id never zeroes the whole account). See
///      `docs/decisions/0015-assisted-balance-adapter-family.md` (and the Merkl precedent, ADR 0007).
/// @dev Manipulation resistance ([2]): the in-range split is driven by a `sqrtPriceX96`
///      *reconstructed from the two tokens' registered oracle prices* (`NAV_CALCULATOR.getPriceData`), NOT the
///      pool's `slot0` spot. This makes reported amounts a pure function of the same oracles NAV prices with, so an
///      attacker who atomically moves the pool price cannot move the reported value (honors the repo's "never trust
///      an AMM spot price" rule). A position whose tokens are unregistered/unpriced/stale is dropped (returns no
///      legs) rather than valued off a manipulable spot. Because `slot0` is no longer read, byte-compatible forks
///      with a divergent `slot0()` ABI (PancakeSwap V3) need no special handling.
/// @dev Fees ([M-A1]): only the position's settled `tokensOwed` are reported. The uncollected-since-poke component
///      derives from `feeGrowthInside`, which is correct only relative to the pool's REAL tick; deriving it from the
///      oracle-reconstructed tick can pick a branch inconsistent with the on-chain `feeGrowthOutside` anchoring and
///      over-report a phantom fee. Since this adapter intentionally avoids `slot0`, that component is omitted — a
///      conservative under-report that upholds the assisted family's never-over-report invariant. See
///      docs/audits/2026-06-vigilo-adapter-audit.md §M-A1.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts) —
///      combined work is GPL-2.0-or-later (ADR 0008).
contract UniswapV3PoolsBalanceAdapter is AssistedBalanceAdapter, IPositionDescribable {
    using Strings for uint256;

    //
    // State
    //

    /// @notice Hard cap on cached tokenIds per account. `getAdapterPositions` iterates the whole array on every NAV
    ///         read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the assistant must
    ///         GC closed positions (`clearTokenId`) to stay under it. A real account never approaches 256 positions.
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

    /// @notice Add candidate NFT tokenIds for `account`. Idempotent (dedup). **Reverts** `NotTokenOwner` if any id is
    ///         not currently owned by `account` — writes are fail-loud. Correctness does not depend on it (reads
    ///         re-verify ownership and value only live, owned positions), but a non-owned id is a caller mistake.
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyRole(ASSISTANT_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        for (uint256 i; i < tokenIds.length; ++i) {
            _addTokenId(account, tokenIds[i]);
        }
    }

    /// @notice Batch variant across accounts. `accounts` and `tokenIds` must have the same length.
    function submitTokenIdsBatch(address[] calldata accounts, uint256[][] calldata tokenIds)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        if (accounts.length != tokenIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert InvalidArguments();
            for (uint256 j; j < tokenIds[i].length; ++j) {
                _addTokenId(accounts[i], tokenIds[i][j]);
            }
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
    ///         `MerklRewardsBalanceAdapter`; registration only needs `supportsInterface(IBalanceAdapter)`).
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
    ///      and `Fees` x2 (settled `tokensOwed`) — dropping zeros, unregistered/unpriced assets, and ids no longer
    ///      owned, respecting `assetFilter`. positionId = abi.encode(pool) (the stable pool address); the NFT id is a
    ///      display-only `labels` entry (an account's NFTs in the same pool share the positionId).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256[] memory ids = _tokenIds[account];
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Fetch the registry snapshot ONCE for the whole read (not once per NFT): the loop below resolves every
        // position's tokens from this single in-memory array, so the read stays O(NFTs + registrySize) rather than
        // O(NFTs × registrySize) — important on an account near MAX_TOKEN_IDS with a large registry.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();

        // Up to 4 legs per NFT (liq0, liq1, fee0, fee1).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](ids.length * 4);
        uint256 count;

        for (uint256 i; i < ids.length; ++i) {
            count = _appendPositionLegs(account, reg, ids[i], assetFilter, temp, count);
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

    /// @dev Appends the (up to 4) legs for one cached `tokenId` to `temp`, returning the new count. An id that is no
    ///      longer owned by `account`, whose pool tokens are unregistered/unpriced/stale, or that is in no requested
    ///      asset, contributes nothing (discarded, never reverts). Mirrors the legacy per-pool valuation, but reads
    ///      `token0/token1/fee` from `positions(tokenId)` so no pool address is needed.
    function _appendPositionLegs(
        address account,
        INAVCalculator.Asset[] memory reg,
        uint256 tokenId,
        address assetFilter,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 count
    ) internal view returns (uint256) {
        // Re-verify ownership every read: discard (do not revert) an id whose NFT was burned or transferred away.
        try INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId) returns (address o) {
            if (o != account) return count;
        } catch {
            return count;
        }

        (
            ,,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);

        // Both tokens must be registered: valuing the LP split needs *both* oracle prices, regardless of which
        // leg(s) `assetFilter` ultimately emits. `assetFilter` only gates emission below (f0reg/f1reg).
        // `reg` is the registry snapshot fetched once by `getAdapterPositions`; resolve both tokens from it.
        (INAVCalculator.Asset memory a0, bool reg0) = _findAsset(reg, token0);
        (INAVCalculator.Asset memory a1, bool reg1) = _findAsset(reg, token1);
        if (!reg0 || !reg1) return count;
        bool f0reg = assetFilter == address(0) || assetFilter == token0;
        bool f1reg = assetFilter == address(0) || assetFilter == token1;
        if (!f0reg && !f1reg) return count;

        // [2] Reconstruct the price from the registered oracles instead of reading the manipulable slot0. Drop the
        // position if either feed is missing/zero/stale — an LP can't be valued manipulation-safely without both
        // fair prices (the stale asset is already surfaced in NAV.stalePriceAssets).
        // `getPriceData` REVERTS (`PriceFeedNotSet`) for a registered asset whose feeds were all removed; catch it
        // and discard only THIS position. Without the guard the revert escapes `getAdapterPositions`, where
        // PriceFeedLib's single per-adapter try/catch would drop the account's ENTIRE Uniswap V3 LP set rather than
        // the one unpriced pool — re-establishing the per-position isolation the old meta-adapter had per instance.
        INAVCalculator.PriceFeedData memory pd0;
        INAVCalculator.PriceFeedData memory pd1;
        try NAV_CALCULATOR.getPriceData(token0) returns (INAVCalculator.PriceFeedData memory _pd0) {
            pd0 = _pd0;
        } catch {
            return count;
        }
        try NAV_CALCULATOR.getPriceData(token1) returns (INAVCalculator.PriceFeedData memory _pd1) {
            pd1 = _pd1;
        } catch {
            return count;
        }
        if (pd0.price <= 0 || pd1.price <= 0 || pd0.stale || pd1.stale) return count;
        uint160 sqrtPriceX96 = UniswapV3PoolLib.sqrtPriceX96FromOraclePrices(
            uint256(pd0.price), pd0.decimals, a0.decimals, uint256(pd1.price), pd1.decimals, a1.decimals
        );

        // positionId = the pool contract address (each (token0, token1, fee) is its own deployed Uniswap V3 pool).
        // The NFT id is NOT in the positionId; it rides in the display labels (built once per NFT below). Drop the
        // position if the factory has no canonical pool for the triple (defensive: never emit a zero-pool identity
        // that would collide across unrelated positions).
        address pool = IUniswapV3Factory(FACTORY).getPool(token0, token1, fee);
        if (pool == address(0)) return count;
        bytes memory positionId = abi.encode(pool);
        // Labels: [category, pool address, NFT id] — NFT id last (per-leg, adapter-supplied; see _toVerbose).
        string[] memory labels = _labels(pool, tokenId);

        // Principal split: tick-boundary sqrt ratios for the in-range amount calc, valued off the
        // oracle-reconstructed sqrtPriceX96 (not the manipulable slot0; `sqrtPriceX96 < getSqrtRatioAtTick(t)` is
        // exactly equivalent to `currentTick < t`).
        uint256 liq0;
        uint256 liq1;
        if (liquidity > 0) {
            (liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
            );
        }

        // Fees: report only the position's settled `tokensOwed` (audit M-A1 — the uncollected-since-poke component
        // is deliberately NOT computed; see the contract-level @dev).
        if (f0reg && liq0 > 0) temp[count++] = _row(a0, liq0, positionId, PositionKind.Supplied, labels);
        if (f1reg && liq1 > 0) temp[count++] = _row(a1, liq1, positionId, PositionKind.Supplied, labels);
        if (f0reg && tokensOwed0 > 0) temp[count++] = _row(a0, tokensOwed0, positionId, PositionKind.Fees, labels);
        if (f1reg && tokensOwed1 > 0) temp[count++] = _row(a1, tokensOwed1, positionId, PositionKind.Fees, labels);
        return count;
    }

    /// @dev `["Liquidity Pool", "<pool address>", "NFT #<tokenId>"]` — the per-leg display hierarchy.
    function _labels(address pool, uint256 tokenId) private pure returns (string[] memory out) {
        out = new string[](3);
        out[0] = "Liquidity Pool";
        out[1] = Strings.toHexString(pool);
        out[2] = string.concat("NFT #", tokenId.toString());
    }

    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bytes memory positionId,
        PositionKind kind,
        string[] memory labels
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: _protocolId(),
            positionId: positionId,
            positionKind: kind,
            isLocked: false, // LP liquidity + settled fees are always withdrawable now
            labels: labels
        });
    }

    //
    // Internal — registry helpers (previously inherited from MetaBalanceAdapter)
    //

    /// @notice Looks up an asset's metadata in a pre-fetched registry snapshot (so the caller scans the registry
    ///         once per NFT and resolves both pool tokens from the same in-memory array).
    /// @return asset The Asset struct (zeroed if not found).
    /// @return found True if the asset is registered in NAVCalculator.
    function _findAsset(INAVCalculator.Asset[] memory reg, address asset)
        private
        pure
        returns (INAVCalculator.Asset memory, bool found)
    {
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return (reg[i], true);
        }
        return (INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), false);
    }
}
