// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice The Aave v4 Spoke views this adapter reads.
/// @dev Transcribed from the deployed Gold Spoke's ABI (`0x65407b940966954b23dfA3caA5C0702bB42984DC`,
///      `SPOKE_REVISION() == 1`). Every struct here is made of STATIC fields only, so each one ABI-decodes
///      byte-identically to the flat tuple the Spoke returns.
///
///      **There is no `IPool`-shaped equivalent of v3 here, and no token to read.** v4 has no `aToken` and no
///      `variableDebtToken`: a position is share accounting held inside the Spoke, keyed by a numeric
///      `reserveId`. v3's `aToken.balanceOf(user)` / `variableDebtToken.balanceOf(user)` have no v4 analogue,
///      and neither does `ProtocolDataProvider` — which is why the v3 meta-adapter cannot be re-pointed at a
///      Spoke and a separate adapter exists at all.
interface ISpoke {
    /// @param underlying The reserve's ERC20.
    /// @dev **A reserve id outside the Spoke's list REVERTS — it does NOT return `underlying == address(0)`.**
    ///      Measured on mainnet against the Gold Spoke (`getReserveCount() == 8`): `getReserve(8)`,
    ///      `getReserve(9)` and `getReserve(100)` all revert `0x2e5d6bb4` (`ReserveNotListed()`), as do
    ///      `getReserveConfig` and `getUserPosition` for the same ids. An earlier version of this docstring
    ///      claimed `address(0)`, which is why {AaveV4SpokesMetaBalanceAdapter} carries `address(0)` skips that
    ///      can never fire against a real Spoke, and why `MockSpoke` models a behaviour the protocol does not
    ///      have. Those skips are harmless dead code while ids `0 … getReserveCount()-1` are always listed, which
    ///      is true of revision 1; what is NOT handled is a reverting read inside that range. See the adapter's
    ///      `_instancePositions` note on the consequence.
    /// @param hub The Hub this reserve draws its liquidity from.
    /// @param assetId The reserve's asset id *on the Hub* (Hub-scoped, NOT the Spoke's `reserveId`).
    /// @param decimals The underlying's decimals.
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @param borrowable False for a collateral-only reserve (mainnet Gold Spoke: reserve 0, xAUt).
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    /// @notice A user's raw share accounting for one reserve.
    /// @dev The cheap "does this account touch this reserve at all" gate — see {AaveV4SpokesMetaBalanceAdapter}.
    /// @param drawnShares Debt principal, in shares.
    /// @param premiumShares Risk-premium debt, in shares.
    /// @param suppliedShares Supply, in shares.
    struct UserPosition {
        uint120 drawnShares;
        uint120 premiumShares;
        int200 premiumOffsetRay;
        uint120 suppliedShares;
        uint32 dynamicConfigKey;
    }

    function getReserveCount() external view returns (uint256);
    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);
    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory);

    /// @notice The user's supply for one reserve, in the underlying's BASE UNITS (shares already converted).
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    /// @notice The user's total debt for one reserve — principal + risk premium — in the underlying's BASE UNITS.
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    /// @notice `(usingAsCollateral, borrowing)` for one reserve.
    /// @dev `usingAsCollateral` is NOT `suppliedShares > 0`; see {AaveV4SpokesMetaBalanceAdapter} for why the
    ///      two genuinely differ in v4.
    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool, bool);
}

/// @title Aave V4 Spokes Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave v4 **Spoke**
///         (Gold, Bluechip, Forex, …). The set of Spokes to query is configured on NAVCalculator and passed as
///         `bytes32` coordinates — here each coordinate is the **Spoke address** (widened to bytes32). Within a
///         Spoke, reserves are enumerated trustlessly by numeric id via `getReserveCount()`/`getReserve(id)`, so
///         reserves are NOT separate coordinates. Emits up to two legs per reserve (Collateral/Supplied +
///         Borrowed), mirroring what {AaveV3InstancesMetaBalanceAdapter} emits for v3. See ADR 0010.
/// @dev **One coordinate per Spoke is load-bearing, not a convenience.** A v4 health factor is *Spoke-scoped*:
///      an avatar with positions on three Spokes has three independent health factors and three independent
///      liquidation risks. A Spoke that is not configured is not merely unlabelled — it is absent from NAV.
///
///      **The instance set is a governed allowlist, and deliberately not auto-enumerated** — same rationale as
///      the v3 adapter (see BALANCE_ADAPTERS.md §6.1). Balances are read trustlessly from the Spoke, so
///      auto-including an arbitrary Spoke would let an untrusted contract report a fabricated balance in a
///      NAV-registered asset. Propose Spokes off-chain; MANAGER approves them.
///
///      **`positionKind` is not cosmetic on v4, and this is the trap it makes visible.** v4's `supply` does
///      **not** auto-enable collateral: without a subsequent `setUsingAsCollateral(reserveId, true, account)`
///      the Spoke reports the account's `totalCollateralValue` as ZERO while its `suppliedShares` are non-zero,
///      so the position looks healthy while unlevered and any borrow reverts `HealthFactorBelowThreshold`. The
///      tokens are really there, so NAV must count them: such a leg is reported as `Supplied` (credit, priced,
///      summed) rather than `Collateral`. The two are told apart by `getUserReserveStatus`, never by
///      `suppliedShares > 0`.
///
///      **Never `getUserAccountData` for amounts.** That view answers in Aave's internal Value / RayValue
///      scales against Aave's own oracle. Adapters report *token amounts* and NAV applies its own price
///      (IBalanceAdapter) — routing a v4 position through Aave's valuation would silently swap the price stack
///      for one leg of the portfolio. Its `activeCollateralCount` is useless as an emptiness fast-path for the
///      same reason the paragraph above gives: it reads zero for a real, unenabled supply.
contract AaveV4SpokesMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the Spoke address. Emits up to two rows per registered reserve: Collateral or Supplied
    ///      (`getUserSuppliedAssets`) and Borrowed (`getUserTotalDebt`, principal + risk premium already summed
    ///      by the Spoke). Skips unregistered reserves and respects `assetFilter`.
    ///
    ///      **`getUserPosition` is the per-reserve gate.** One call yields all three share counters, and an
    ///      account with zero of each cannot have a non-zero converted balance on either side — assets are
    ///      derived *from* those shares. So an untouched reserve costs one gate call instead of three balance
    ///      reads, which matters because a Spoke's reserve list is unbounded (`MAX_USER_RESERVES_LIMIT` is
    ///      65535 on the deployed Spoke) and this whole fan-out runs under a per-instance gas stipend. The
    ///      invariant is asserted against the real Spoke rather than assumed — see the fork suite's
    ///      `test_gate_zeroSharesImpliesZeroAssets`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        ISpoke spoke = ISpoke(_toAddress(instance));
        // **EVERY LEG CARRIES ITS reserveId IN `positionInstanceId`, AND THAT IS LOAD-BEARING.** One Spoke can
        // list the SAME underlying at two reserve ids against two different Hubs — Bluechip carries USDC at
        // reserve 4 (Prime) and reserve 7 (Core), USDT at 5 and 10, all four borrowable, which is how one Spoke
        // quotes two borrow rates. Those legs share every field of the stable reconciliation key
        // (`chainId, protocolSubId, positionId, balanceAsset.asset, positionKind` —
        // docs/howto/position-identity-schema.md), so without a discriminator they are literally
        // indistinguishable. Measured on mainnet 2026-09-17: 37 accounts hold USDC debt on BOTH Bluechip
        // reserves and 31 hold USDT on both.
        //
        // The direction of the error is what makes this worth a redeploy rather than a note. The queue and NFT
        // adapters also emit duplicate keys, but their legs are CREDITS, so a consumer that upserts by the key
        // under-counts. These are DEBT, so the same consumer drops a borrow and OVER-reports — the direction
        // this repo treats as critical. NAV itself is unaffected (`PriceFeedLib` sums rows).
        //
        // Why the discriminator goes here and NOT into `positionId`: `positionIds()` maps each governed instance
        // through {_instancePositionId} and {IPositionEnumerable} requires those ids to be byte-identical to the
        // ones emitted, so ONE instance must yield exactly ONE positionId. Folding reserveId into positionId
        // would make a Spoke emit N of them and break that contract. `positionInstanceId` is the field the schema
        // reserves for exactly this per-item coordinate, and it is what the withdrawal queues and NFT adapters
        // already use. Consumers must still SUM across a shared key; this gives them the means to tell the rows
        // apart when they need to.
        //
        // positionId is the Spoke itself — one position per Spoke, which is also the unit the health factor is
        // scoped to. The reserve is NOT in positionId; each reserve's legs are distinguished by balanceAsset +
        // positionKind (the multi-leg convention). Unlike v3 — whose coordinate is a ProtocolDataProvider and
        // whose positionId is the Pool resolved from it — the v4 coordinate is already the contract users
        // transact against, so the base `_instancePositionId` needs no override and no chain read.
        bytes memory pid = _instancePositionId(instance);

        uint256 count;
        uint256 reserveCount = spoke.getReserveCount();
        // Up to 2 legs per reserve: one supply-side (Collateral or Supplied) + one Borrowed.
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](reserveCount * 2);

        for (uint256 id; id < reserveCount; ++id) {
            // KNOWN GAP, recorded rather than silently carried: a reserve read that REVERTS inside
            // `0 … reserveCount-1` is not handled here. `_positionsForInstances` catches it, `consumed` is small
            // so `GasStipendLib.exhausted` reads false, and the Spoke is recorded as ZERO legs while
            // `getAdapterPositions` returns success with clean flags — dropping any borrow leg, which raises
            // reported NAV. Unreachable on Spoke revision 1 (every id below the count is listed; verified on
            // mainnet), and not fixable in place because this adapter is immutable and already deployed.
            address underlying = spoke.getReserve(id).underlying;
            // Dead against a real Spoke — an unlisted id reverts rather than returning zero (see {ISpoke.Reserve}).
            // Kept because it costs one comparison and `address(0)` must never be published as an underlying.
            if (underlying == address(0)) continue;

            ISpoke.UserPosition memory up = spoke.getUserPosition(id, account);
            bool hasDebt = up.drawnShares > 0 || up.premiumShares > 0;
            bool hasSupply = up.suppliedShares > 0;
            // Account does not touch this reserve: skip before spending a single balance read on it.
            if (!hasDebt && !hasSupply) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(underlying);

            // A borrow this adapter cannot report must never leave the account's supplies standing alone: the
            // position would count as pure credit, overstated by the whole borrow. Checked BEFORE `assetFilter`
            // and independently of it, and that asymmetry is deliberate — the two cases differ in kind:
            //
            //   - Unregistered reserve — nobody can price that borrow, on any path, so emitting the supplies
            //     alone states a figure no consumer is able to offset. Dropping the whole Spoke is the safe
            //     direction, and that is what the guard below does.
            //   - Excluded by `assetFilter` — the borrow is perfectly priceable and merely outside the caller's
            //     query. A per-asset read is a PROJECTION, not a sub-portfolio valuation: ask for asset X and
            //     you get the legs denominated in X. Omitting the Borrowed leg is the requested answer.
            //
            // Scope, so this is not mistaken for a live NAV hazard: no NAV figure is ever computed with a
            // filter. `getAccountNav`, `getAccountNavForAdapters` and `getAccountNavVerbose` take no filter and
            // reach `PriceFeedLib.computeNav` with `address(0)`. The only non-zero-filter entrypoints are
            // `NAVCalculator.getAccountPositionsForAsset` / `…ForAssetVerbose`, which return `Position[]`.
            //
            // An unregistered SUPPLY is the opposite direction and is simply skipped: omitting credit
            // understates NAV, which is safe, and is what the v3 adapter does with the same case.
            if (!found) {
                if (hasDebt) return new INAVCalculator.PositionBalance[](0);
                continue;
            }

            if (assetFilter != address(0) && underlying != assetFilter) continue;

            if (hasSupply) {
                uint256 supplied = spoke.getUserSuppliedAssets(id, account);
                if (supplied > 0) {
                    // Shares round down to zero assets only for dust, but a zero-amount leg is still a leg —
                    // re-check rather than trusting the gate, exactly as the v3 adapter checks its balances.
                    (bool usingAsCollateral,) = spoke.getUserReserveStatus(id, account);
                    INAVCalculator.PositionBalance memory leg = _leg(
                        assetInfo,
                        supplied,
                        false,
                        pid,
                        usingAsCollateral ? PositionKind.Collateral : PositionKind.Supplied
                    );
                    leg.positionInstanceId = bytes32(id);
                    temp[count++] = leg;
                }
            }

            if (hasDebt) {
                // `getUserTotalDebt` already sums principal and risk premium. Reporting them as two legs would
                // produce rows with an identical reconciliation key (same Spoke positionId, same reserve
                // balanceAsset, same Borrowed kind), which is not univocal — and the sum is what NAV needs.
                uint256 debt = spoke.getUserTotalDebt(id, account);
                if (debt > 0) {
                    INAVCalculator.PositionBalance memory leg = _leg(assetInfo, debt, true, pid, PositionKind.Borrowed);
                    leg.positionInstanceId = bytes32(id);
                    temp[count++] = leg;
                }
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Unpopulated reserve ids are compacted out rather than published as `address(0)`.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        ISpoke spoke = ISpoke(_toAddress(instance));
        uint256 reserveCount = spoke.getReserveCount();
        address[] memory buf = new address[](reserveCount);
        uint256 n;
        for (uint256 id; id < reserveCount; ++id) {
            address underlying = spoke.getReserve(id).underlying;
            if (underlying != address(0)) buf[n++] = underlying;
        }
        assets = new address[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = buf[i];
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Spoke", <collateral-only reserve symbols>]` — e.g. `["Spoke", "XAUt"]` for the mainnet
    ///      Gold Spoke. positionId is the Spoke, so the label is per-Spoke, not per-reserve (the reserve token
    ///      lives in `balanceAsset`). Collapses to `["Spoke"]` when the leaf is unavailable; empty array for a
    ///      malformed positionId (see {_pidAddress}).
    ///
    ///      **Why the collateral-only reserves, and not the Spoke's own name.** Every Spoke answers
    ///      `eip712Domain()` with the generic string `"Spoke"` and reverts `name()`/`symbol()`, so there is no
    ///      on-chain name that distinguishes one Spoke from another — measured against the deployed Gold Spoke.
    ///      What distinguishes a Spoke *is* its risk perimeter, and the non-borrowable (collateral-only)
    ///      reserves are the short, stable summary of it: the Gold Spoke's is exactly `xAUt`. Borrowable
    ///      reserves are the wrong choice — the Gold Spoke has seven stablecoins, which would render one
    ///      unreadable leaf shared with every other stablecoin Spoke.
    ///
    ///      Display only, and fails open in both directions: a Spoke with no collateral-only reserve, or one
    ///      where governance later makes its collateral asset borrowable, renders `["Spoke"]` rather than a
    ///      wrong name. The leaf is unbounded in the number of reserves scanned, which is what
    ///      {LABEL_LEAF_GAS} is for — an oversized Spoke drops to the category alone instead of spending a
    ///      caller's read.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        (address spoke, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        // External self-call so a revert anywhere in the reserve-scan/config/symbol chain fails open to the
        // category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.spokeCollateralSymbols{gas: LABEL_LEAF_GAS}(spoke) returns (string memory leaf) {
            return _labels("Spoke", leaf);
        } catch {
            return _labels("Spoke", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the Spoke's label leaf —
    ///         the joined symbols of its collateral-only (non-borrowable) reserves, e.g. `"XAUt"`.
    /// @param spoke The Spoke address.
    /// @return The label leaf, or "" if the Spoke has no readable collateral-only reserve.
    function spokeCollateralSymbols(address spoke) external view returns (string memory) {
        ISpoke s = ISpoke(spoke);
        uint256 reserveCount = s.getReserveCount();
        address[] memory collateralOnly = new address[](reserveCount);
        uint256 n;
        for (uint256 id; id < reserveCount; ++id) {
            address underlying = s.getReserve(id).underlying;
            if (underlying == address(0)) continue;
            if (s.getReserveConfig(id).borrowable) continue;
            collateralOnly[n++] = underlying;
        }
        address[] memory tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = collateralOnly[i];
        }
        // Returns "" for an empty array, which `_labels` collapses to `["Spoke"]`.
        return _joinTokenSymbols(tokens);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V4;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V4_LENDING;
    }
}
