// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ezETH Custom Price Oracle
/// @notice USD price of Renzo's ezETH = (RestakeManager TVL / ezETH supply) (ETH per ezETH, 18 dec) × the NAV's
///         ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; `_rate()` derives the ezETH/ETH rate from Renzo and returns 0 (→ stale) if
///      `calculateTVLs()` reverts or supply is 0.
/// @dev Staleness gap: calculateTVLs() reads Renzo's internal oracles, whose freshness is not independently
///      checked here. Only the NAV base/USD staleness is verified. This is an architectural constraint of
///      Renzo on mainnet; the L2 adapter (ezETH_L2_CustomPriceFeed) avoids this by using xRenzoDeposit.getRate() directly.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract ezETH_CustomPriceFeed is BaseCustomPriceFeed {
    using Math for uint256;

    /// @notice Renzo RestakeManager (exposes calculateTVLs()).
    IRestakeManager public immutable RESTAKE_MANAGER;

    constructor(address ezEth_, address restakeManager_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(ezEth_, nav_, baseAsset_)
    {
        RESTAKE_MANAGER = IRestakeManager(OracleArgumentChecks.assertNonZeroAddress(restakeManager_));
    }

    /// @notice Smallest byte length a canonical `(uint256[][], uint256[], uint256)` reply can have: three head
    ///         words plus one length word for EACH dynamic member, even when both are empty.
    /// @dev 96 (the head alone) is NOT the floor, and using it left a 64-byte window in which a reply the ABI
    ///      decoder would have rejected was published as a live rate. Found in review.
    uint256 private constant MIN_REPLY_BYTES = 160;

    /// @notice Head word 0 for this signature: the offset of the first dynamic member, immediately after the
    ///         three-word head. solc's encoder emits this unconditionally, which makes it an exact discriminator.
    uint256 private constant HEAD0_OFFSET = 0x60;

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev Reads ONLY the third return value of `calculateTVLs()` — `totalTVL` — and never decodes the two
    ///      arrays in front of it.
    ///
    ///      **Why not `try`/`catch`.** This used to be
    ///      `try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256)`, with a
    ///      `catch { return 0; }` intended to mark the feed stale on any failure. It does not do that. Solidity
    ///      decodes the reply in the CALLING frame, after the call has returned, so a decode failure reverts past
    ///      the `catch` — and a nested `uint256[][]` is the most failure-prone shape there is: a bad head offset,
    ///      an absurd length, or an empty reply all revert. `RESTAKE_MANAGER` is an ERC-1967 proxy, so the empty
    ///      case is not hypothetical: an implementation slot pointing at a code-less address makes the
    ///      `delegatecall` SUCCEED and return nothing, which the decoder then rejects. The `catch` never runs and
    ///      `_rate()` — a view whose entire contract is "return 0 to mark the price stale" — reverts instead.
    ///
    ///      **Why a fixed 96-byte output window.** ABI-encoded return data places static values inline in the
    ///      head and dynamic ones as offsets into the tail, so for `(uint256[][], uint256[], uint256)` the head
    ///      is exactly `[offset][offset][totalTVL]` and `totalTVL` sits at head word 2 regardless of how large
    ///      the arrays are. Copying 96 bytes gets it without following either offset. That also bounds the cost:
    ///      the EVM copies `min(returndatasize(), 96)` and discards the rest, so Renzo's per-operator/per-token
    ///      arrays — genuinely large, and growing with the operator set — can no longer be charged to this
    ///      frame's memory expansion. Assigning `(bool, bytes memory)` would have `returndatacopy`d all of it.
    ///
    ///      The `>= 96` check is what replaces the decoder's own bounds check, and it is the reason no value can
    ///      be invented from a short reply: the output window is written before the call and read only when the
    ///      callee actually produced three words.
    ///
    ///      No gas cap is applied. `RESTAKE_MANAGER` is a constructor-pinned immutable, not a caller-supplied or
    ///      governance-mutable address, and this is the feed's only external read; a ceiling here would make an
    ///      honest-but-expensive `calculateTVLs` unrecoverable by supplying more gas, which is the trade
    ///      {GasStipendLib} documents against.
    function _rate() internal view override returns (uint256) {
        bool ok;
        uint256 size;
        uint256 head0;
        uint256 totalTVL;
        address restakeManager = address(RESTAKE_MANAGER);
        bytes4 selector = IRestakeManager.calculateTVLs.selector;
        assembly ("memory-safe") {
            // Scratch space (0x00–0x3f) is free for transient use, but the reply needs three words, so take a
            // 96-byte window at the free-memory pointer WITHOUT bumping it — nothing allocates across this block.
            let out := mload(0x40)
            // Zero the window first: on a short reply the EVM writes nothing, and unwritten memory here is not
            // guaranteed to be clean. Without this, `totalTVL` could pick up an earlier allocation's bytes; the
            // `size` check below rejects that case, but the read happens before it and must not be garbage-in.
            mstore(out, 0)
            mstore(add(out, 0x20), 0)
            mstore(add(out, 0x40), 0)
            mstore(0x00, selector)
            ok := staticcall(gas(), restakeManager, 0x00, 0x04, out, 0x60)
            size := returndatasize()
            head0 := mload(out) // head word 0 — the first dynamic member's offset
            totalTVL := mload(add(out, 0x40)) // head word 2 — see the note above on ABI head layout
        }
        // Length alone is not shape, and the head alone is not the length floor. Dropping the typed decode
        // dropped BOTH of its structural checks, and re-establishing only one of them left a 96..159-byte
        // window — shorter than any canonical encoding of this signature — in which a malformed reply was
        // published as a live rate.
        // For `(uint256[][], uint256[], uint256)` the head is exactly three words, so solc's encoder emits
        // `0x60` as word 0 unconditionally — a cheap, exact discriminator. If Renzo ever upgrades
        // `calculateTVLs()` to a different return shape (it is an ERC-1967 proxy), this reads STALE, which is
        // the safe direction for a credit asset, rather than publishing whatever sits at byte offset 64.
        if (!ok || size < MIN_REPLY_BYTES || head0 != HEAD0_OFFSET) return 0;

        uint256 supply = IERC20(UNDERLYING).totalSupply();
        if (supply == 0) return 0;
        return totalTVL.mulDiv(1e18, supply, Math.Rounding.Floor);
    }
}

interface IRestakeManager {
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}
