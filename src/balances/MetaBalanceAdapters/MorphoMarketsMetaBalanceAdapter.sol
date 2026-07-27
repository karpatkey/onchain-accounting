// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Morpho Markets Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's positions on *any* Morpho market. The set of
///         markets to query is configured on NAVCalculator (per-adapter, MANAGER-gated) and passed as `bytes32`
///         instance coordinates — here the coordinate is the Morpho **marketId** itself (used directly, not an
///         address). Emits up to three gross rows per market (collateral, loan-supply, loan-borrow).
///         See ADR 0010 (meta-adapters) and ADR 0004 (projected balances).
contract MorphoMarketsMetaBalanceAdapter is MetaBalanceAdapter {
    using Math for uint256;
    using MorphoBalancesLib for IMorpho;

    /// @notice The Morpho singleton (protocol-global).
    IMorpho public immutable MORPHO;

    /// @param morpho_ The Morpho contract address.
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address morpho_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        AddressCheckLib.requireContract(morpho_, "Morpho");
        MORPHO = IMorpho(morpho_);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the Morpho marketId. Returns up to three rows (each guarded by `> 0`): collateral,
    ///      loan-supplied (credit), loan-borrowed (debt). Skips unregistered assets and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        Id marketId = Id.wrap(instance);
        MarketParams memory mp = MORPHO.idToMarketParams(marketId);
        address collateral = mp.collateralToken;
        address loan = mp.loanToken;

        (INAVCalculator.Asset memory collAsset, bool collReg) = _getAssetInfo(collateral);
        (INAVCalculator.Asset memory loanAsset, bool loanReg) = _getAssetInfo(loan);

        bool collateralEligible = collReg && (assetFilter == address(0) || assetFilter == collateral);
        bool loanEligible = loanReg && (assetFilter == address(0) || assetFilter == loan);
        if (!collateralEligible && !loanEligible) {
            return new INAVCalculator.PositionBalance[](0);
        }

        Position memory pos = MORPHO.position(marketId, account);

        // A debt this adapter cannot report must never leave the collateral standing alone: the position would
        // count as pure credit and NAV be over-reported by the whole borrow. Checked on registration only, NOT
        // the assetFilter — a filtered view showing collateral while hiding an unreportable debt over-reports
        // the same way. Under-reporting the whole position is the safe direction.
        if (!loanReg && pos.borrowShares != 0) {
            // Gate on the REALISED borrow, not the raw share count: dust shares left by a repay-by-assets, or a
            // degenerate market whose totalBorrowAssets was driven to 0 by a bad-debt seizure while shares
            // remain, would otherwise erase an entire healthy collateral position.
            (, uint256 unreportableBorrow) = _loanLegs(mp, pos);
            if (unreportableBorrow > 0) return new INAVCalculator.PositionBalance[](0);
        }

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](3);
        uint256 count;

        if (collateralEligible && uint256(pos.collateral) > 0) {
            temp[count++] = _leg(collAsset, uint256(pos.collateral), false, pid, PositionKind.Collateral);
        }

        if (loanEligible) {
            (uint256 supplied, uint256 borrowed) = _loanLegs(mp, pos);
            if (supplied > 0) {
                temp[count++] = _leg(loanAsset, supplied, false, pid, PositionKind.Supplied);
            }
            if (borrowed > 0) {
                temp[count++] = _leg(loanAsset, borrowed, true, pid, PositionKind.Borrowed);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(instance));
        assets = new address[](2);
        assets[0] = mp.collateralToken;
        assets[1] = mp.loanToken;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market", "<collateral>/<loan>"]` where the leaf is built from the two token symbols. If the
    ///      marketId cannot be resolved the leaf is empty and collapses to `["Market"]` (see {_labels}). Returns an
    ///      empty array for a malformed positionId — see {_pidWord}, NOT {_pidAddress}: a marketId is a keccak hash,
    ///      so almost every real one has bits set above 160 and a range check would reject it.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        (bytes32 marketId, bool ok) = _pidWord(pid);
        if (!ok) return new string[](0);
        string memory leaf = "";
        try MORPHO.idToMarketParams(Id.wrap(marketId)) returns (MarketParams memory mp) {
            // `idToMarketParams` is a plain mapping getter, so an id with NO market returns an all-zero struct
            // instead of reverting — the `catch` arm never fires for it. Both symbol reads would then fail open to
            // "?" and the adapter would answer `["Market", "?/?"]`: a confident two-segment breadcrumb, byte-
            // identical to a real market whose tokens both have unreadable symbols, for a market that does not
            // exist on this chain. Gate on `loanToken` — every real market has one, whereas an "idle" market
            // legitimately has `collateralToken == address(0)`, so only `loanToken` can carry the check.
            if (mp.loanToken != address(0)) {
                leaf = string.concat(_symbol(mp.collateralToken), "/", _symbol(mp.loanToken));
            }
        } catch {}
        return _labels("Market", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO_MARKETS;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Morpho market instance is a raw bytes32 marketId, not an address.
    function _instancePositionId(bytes32 instance) internal pure override returns (bytes memory) {
        return abi.encode(instance);
    }

    /// @notice Projected loan-token supply/borrow amounts for the account (ADR 0004: expectedMarketBalances).
    ///         Supply rounds down (avoid overstating credit); borrow rounds up (avoid understating debt).
    function _loanLegs(MarketParams memory mp, Position memory pos)
        private
        view
        returns (uint256 supplied, uint256 borrowed)
    {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MORPHO.expectedMarketBalances(mp);
        if (totalSupplyShares != 0 && pos.supplyShares != 0) {
            supplied = totalSupplyAssets.mulDiv(pos.supplyShares, totalSupplyShares, Math.Rounding.Floor);
        }
        if (totalBorrowShares != 0 && pos.borrowShares != 0) {
            borrowed = totalBorrowAssets.mulDiv(pos.borrowShares, totalBorrowShares, Math.Rounding.Ceil);
        }
    }

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens or a codeless address (e.g. an idle
    ///         market with no collateral token) — so the concatenated leaf stays well-formed (no leading `/` segment).
    function _symbol(address token) private view returns (string memory) {
        return LabelLib.symbol(token, "?");
    }
}
