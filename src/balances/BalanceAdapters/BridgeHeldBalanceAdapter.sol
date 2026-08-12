// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Bridge Escrow Held-Balance Adapter (ADR 0024)
/// @author KPK
/// @notice Reports the account's **delivered-but-unclaimed** funds sitting in the destination `BridgeEscrow`
///         custody (ADR 0024 "hold-then-claim"). Between `recordDelivery` (funds arrive on the destination and are
///         held by the escrow) and `claim` (MANAGER moves them to the safe), the value is not yet in the safe's
///         wallet, so the ordinary ERC20 balance adapter would miss it. This adapter closes that gap by reading the
///         escrow's per-account custody so NAV counts held value continuously across the bridge hop. On the
///         destination the two windows this adapter borders — destination held → safe balance — are disjoint: the
///         MANAGER-gated `claim` is the single block where value moves from "held" to "safe balance". **The
///         source-chain in-transit window is NOT disjoint from destination held**: `recordDelivery` starts the
///         held position, but source in-transit clears only at the later, separate `markInvoiceCompleted`, so a
///         cross-chain NAV that sums both escrows double-counts during that settlement gap. Netting source
///         in-transit against destination delivery (source `getActiveInvoices` × dest `isInvoiceCompleted`) or a
///         prompt settlement keeper is required to close it — the same operational requirement the source-side
///         in-transit accounting already carries; hold-then-claim does not remove it. Note: the
///         `isInvoiceCompleted(hash)` half only matches for bridges whose destination hash equals the source
///         hash; Stargate re-encodes a post-fee payload (different hash), so a Stargate lane must be netted on
///         the source `markInvoiceCompleted` signal, not by destination hash-matching.
/// @dev Immutable, view-only, per-chain: pin the destination `BridgeEscrow` for this chain in the constructor. Every
///      leg is `PositionKind.Supplied` with `isLocked = true` (the account owns the value but cannot use it until a
///      claim moves it to the safe). Only assets registered on `NAVCalculator` are emitted (unregistered held assets
///      cannot be priced). The custody amount is the escrow's measured balance-delta, so it can never over-report.
contract BridgeHeldBalanceAdapter is BalanceAdapterBase {
    /// @dev Single-product taxonomy: brand == protocolId == protocolSubId == `bridge-escrow`.
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.BRIDGE_ESCROW;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.BRIDGE_ESCROW;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.BRIDGE_ESCROW;

    /// @notice NAVCalculator, for looking up registered-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice The destination BridgeEscrow on this chain whose held custody this adapter reports.
    IBridgeEscrow public immutable BRIDGE_ESCROW;

    /// @dev NAV's native-asset sentinel (ERC-7528, matches `Balances.NATIVE_ADDRESS`). The escrow keys native
    ///      custody at `address(0)` (its registration convention), so this adapter maps `address(0)` → this
    ///      sentinel before every NAV metadata lookup/filter and maps back when querying the escrow, otherwise a
    ///      held native (ETH) delivery would be silently omitted from NAV.
    address private constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @param navCalculator The NAVCalculator address (registered-asset lookups).
    /// @param bridgeEscrow The BridgeEscrow proxy on this chain.
    constructor(address navCalculator, address bridgeEscrow) {
        if (navCalculator == address(0) || bridgeEscrow == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(navCalculator, "NAVCalculator");
        AddressCheckLib.requireContract(bridgeEscrow, "BridgeEscrow");
        NAV_CALCULATOR = INAVCalculator(navCalculator);
        BRIDGE_ESCROW = IBridgeEscrow(bridgeEscrow);
    }

    //
    // IPositionDescribable
    //

    function protocolName() external pure returns (string memory) {
        return ProtocolNames.BRIDGE_ESCROW;
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "Held (pending claim)";
        return out;
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice The assets the escrow can hold custody of on this chain (its registered bridge assets). The escrow's
    ///         `address(0)` native key is surfaced as NAV's ERC-7528 sentinel so the NAV registry indexes this
    ///         adapter under the same native address it prices under (otherwise it is undiscoverable for native).
    function underlyingAssetsSupported() external view override returns (address[] memory underlyingAssets) {
        (, address[] memory raw) = BRIDGE_ESCROW.registeredAssets();
        // Map the escrow's address(0) native key to NAV's sentinel AND merge duplicates, so a dual-native-key
        // (address(0) + sentinel) misconfig collapses to one entry — consistent with getAdapterBalances,
        // getAdapterPositions and the point getter, which all merge/sum both native keys.
        address[] memory tmp = new address[](raw.length);
        uint256 n;
        for (uint256 i; i < raw.length; ++i) {
            address a = raw[i] == address(0) ? NATIVE_ASSET : raw[i];
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (tmp[j] == a) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tmp[n++] = a;
        }
        underlyingAssets = new address[](n);
        for (uint256 i; i < n; ++i) {
            underlyingAssets[i] = tmp[i];
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice `asset` is the NAV-side address; the native sentinel (or `address(0)`) sums both native keys the
    ///         escrow might hold custody under (`address(0)` by convention, or the ERC-7528 sentinel).
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0)) return (0, false);
        // Native queried via either representation (`address(0)` — the escrow's key — or the ERC-7528 sentinel)
        // sums both keys the escrow might hold custody under. `address(0)` here means "the native asset", not
        // "no asset", consistent with this function's natspec and the escrow's registration convention.
        if (asset == address(0) || asset == NATIVE_ASSET) {
            return (
                BRIDGE_ESCROW.getHeldBalanceForAsset(address(0), account)
                    + BRIDGE_ESCROW.getHeldBalanceForAsset(NATIVE_ASSET, account),
                false
            );
        }
        return (BRIDGE_ESCROW.getHeldBalanceForAsset(asset, account), false);
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Per-asset held custody for the account (credit; skips zeros). The escrow's `address(0)` native key
    ///         is surfaced as NAV's native sentinel so consumers see a consistent native address.
    function getAdapterBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));
        (address[] memory raw, uint256[] memory rawAmounts) = BRIDGE_ESCROW.getHeldBalancesForAccount(account);

        // Normalize the escrow's address(0) native key to NAV's sentinel AND merge duplicates, so a dual-native-key
        // (address(0) + sentinel) misconfig collapses to one entry — consistent with getAdapterPositions and the
        // point getter, which also merge/sum both native keys.
        address[] memory tmpA = new address[](raw.length);
        uint256[] memory tmpV = new uint256[](raw.length);
        uint256 n;
        for (uint256 i; i < raw.length; ++i) {
            address a = raw[i] == address(0) ? NATIVE_ASSET : raw[i];
            bool found;
            for (uint256 j; j < n; ++j) {
                if (tmpA[j] == a) {
                    tmpV[j] += rawAmounts[i];
                    found = true;
                    break;
                }
            }
            if (!found) {
                tmpA[n] = a;
                tmpV[n] = rawAmounts[i];
                ++n;
            }
        }

        assets = new address[](n);
        amounts = new uint256[](n);
        isDebt = new bool[](n); // all false (credit)
        for (uint256 i; i < n; ++i) {
            assets[i] = tmpA[i];
            amounts[i] = tmpV[i];
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice One `Supplied` (`isLocked = true`) leg per held asset that is also registered on NAVCalculator, under
    ///         `positionId = abi.encode(bridgeEscrow, token)` (the canonical `bridge-escrow` decode schema); the
    ///         held token also rides in `balanceAsset`.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        (address[] memory heldAssets, uint256[] memory heldAmounts) = BRIDGE_ESCROW.getHeldBalancesForAccount(account);
        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](heldAssets.length);
        uint256 count;
        for (uint256 i; i < heldAssets.length; ++i) {
            // Map the escrow's native key (address(0)) to NAV's native sentinel before filtering/lookup, else a
            // held ETH delivery would fail the (0xEeee != address(0)) find and be silently dropped from NAV.
            address asset = heldAssets[i] == address(0) ? NATIVE_ASSET : heldAssets[i];
            uint256 amount = heldAmounts[i];
            if (amount == 0) continue;
            if (assetFilter != address(0) && assetFilter != asset) continue;

            (INAVCalculator.Asset memory assetMeta, bool found) = RegisteredAssetLib.find(registered, asset);
            if (!found) continue; // unregistered assets cannot be priced — skip (under-report, safe direction)

            // Merge into an existing leg for the same normalized asset instead of emitting a second one — a
            // misconfigured escrow that keyed native under BOTH address(0) and the sentinel would otherwise
            // produce two legs with an identical stable identity key (same positionId), colliding for an
            // identity-keyed reconciliation consumer.
            bool merged;
            for (uint256 j; j < count; ++j) {
                if (tmp[j].balanceAsset.asset == assetMeta.asset) {
                    tmp[j].amount += amount;
                    merged = true;
                    break;
                }
            }
            if (merged) continue;

            tmp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: assetMeta,
                balanceAdapter: address(this),
                amount: amount,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                // Canonical `bridge-escrow` positionId decode schema: (address escrow, address token) — see
                // ProtocolIds.sol and docs/howto/position-identity-schema.md. `asset` is the NAV-normalized token.
                positionId: abi.encode(address(BRIDGE_ESCROW), asset),
                positionKind: PositionKind.Supplied,
                isLocked: true,
                positionInstanceId: bytes32(0)
            });
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }
}
