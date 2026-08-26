// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SingleAssetBalanceAdapterBase} from "../../SingleAssetBalanceAdapterBase.sol";
import {IBalanceAdapter} from "../../IBalanceAdapter.sol";
import {IPositionDescribable} from "../../IPositionDescribable.sol";
import {IPositionEnumerable} from "../../IPositionEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Cap Protocol cUSD Interface
/// @notice Minimal interface for interacting with Cap protocol's cUSD token.
interface ICUsd {
    /// @notice Get the amount of underlying asset received for burning cUSD.
    /// @param asset The underlying asset address (e.g. USDC)
    /// @param amountIn The amount of cUSD to burn
    /// @return amountOut The amount of underlying asset received
    /// @return fee The protocol fee amount
    function getBurnAmount(address asset, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee);
}

/// @title Cap Balance Adapter Base
/// @author KPK
/// @notice Shared base for Cap protocol's **one-leg-per-adapter** balance adapters: each concrete adapter reports a
///         single Cap token, valued in `UNDERLYING_TOKEN` (USDC) through cUSD's burn quote, as exactly one
///         `PositionBalance` shape with a UNIFORM two-segment label.
/// @dev **Why one adapter per leg rather than one adapter for the protocol.** A single `CapBalanceAdapter` used to
///      serve both legs and branch its labels on the positionId — `["Stablecoin", "cUSD"]` for held cUSD,
///      `["Savings", "stcUSD"]` for staked stcUSD. Both segments were string LITERALS, but a DIFFERENT literal per
///      position, and `AssetKindRegistry`'s label overrides are keyed by ADAPTER: one
///      `setAdapterLabels(cap, ["Synthetic Dollar", "cUSD"])` necessarily rewrote BOTH legs, so correcting either one
///      silently corrupted the other, at both indices. That is not a defect of the override mechanism — a
///      per-adapter table cannot express a per-position value, and giving it one would be exactly the per-position
///      bookkeeping the design exists to avoid. Splitting the contract is what makes each segment a per-adapter
///      constant again, and therefore safely overridable. Cap was the ONLY adapter in `src/balances/` in this state.
///
///      **What is deliberately NOT split: the protocol taxonomy.** All three levels stay `ProtocolIds.CAP` on both
///      adapters, and `protocolName()` stays `ProtocolNames.CAP` on both. The taxonomy identifies the PROTOCOL, and
///      consumers group configured adapters by the display name — two names here would manufacture exactly the
///      phantom-sibling split {IPositionDescribable.protocolName} exists to prevent, and a second `protocolSubId`
///      would claim a second positionId DECODE SCHEMA when both legs encode the same shape
///      (`abi.encode(address token)`). The leg distinction is carried where it already was: `positionId` and
///      `positionKind`. `test/ProtocolNameConsistency.t.sol` pins the shared name over adapter code.
///
///      **Each adapter reports its own leg only, and the sum is unchanged.** The pre-split aggregate getters
///      (`getAdapterBalances` / `getAdapterBalanceForAsset`) returned cUSD + stcUSD combined from one contract;
///      each adapter now returns its own leg, so a consumer summing over the registered adapter set gets the same
///      total. The NAV path is unaffected in shape as well as value: `getAdapterPositions` already emitted the two
///      legs as separate `PositionBalance` entries with these same `positionId` / `positionKind` / `protocolId`
///      values, so a snapshot keyed on those fields is byte-identical across the split.
///
///      Immutable, like every plain adapter: the constructor pins everything and there is no admin surface.
abstract contract CapBalanceAdapterBase is SingleAssetBalanceAdapterBase, IPositionEnumerable {
    //
    // Constants
    //

    /// @notice 3-level protocol identity for Cap (brand / id / sub-id). Cap is a single product with no
    ///         sub-protocols, so all three levels collapse to the same `ProtocolIds.CAP` slug; the cUSD vs.
    ///         stcUSD leg distinction is carried by `positionId` and `positionKind`, not by the taxonomy — and
    ///         not by the adapter split either, which is a DISPLAY concern (see the contract note).
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.CAP;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.CAP;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.CAP;

    //
    // State
    //

    /// @notice Cap protocol cUSD token (ERC20 + burn-quote interface). Held by BOTH legs: it is the leg token for
    ///         the stablecoin adapter and the burn-quote oracle for the savings one.
    ICUsd public immutable CUSD;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param cUsd_ The address of the Cap cUSD token.
    /// @param usdc_ The address of USDC — the asset positions are denominated in.
    /// @param navCalculator_ The address of the NAVCalculator contract.
    constructor(address cUsd_, address usdc_, address navCalculator_) SingleAssetBalanceAdapterBase(usdc_) {
        if (cUsd_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(cUsd_, "cUSD");
        AddressCheckLib.requireContract(usdc_, "USDC");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        CUSD = ICUsd(cUsd_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Per-leg hooks
    //

    /// @notice The Cap token this adapter reports — the `positionId` coordinate and the only address
    ///         {positionLabels} will describe.
    function _positionToken() internal view virtual returns (address);

    /// @notice The `PositionKind` this leg reports: held cUSD is `Supplied`, staked stcUSD is `Staking`.
    function _positionKind() internal pure virtual returns (PositionKind);

    /// @notice This leg's two label segments, both compile-time literals and both the SAME for every position this
    ///         adapter can emit — which is the property that makes each independently overridable.
    function _labelPair() internal pure virtual returns (string memory category, string memory leaf);

    //
    // IPositionDescribable
    //

    /// @inheritdoc IPositionDescribable
    /// @dev Shared by both legs on purpose — see the contract note on why the split is a display concern and not a
    ///      protocol-identity one.
    function protocolName() external pure returns (string memory) {
        return ProtocolNames.CAP;
    }

    /// @inheritdoc IPositionDescribable
    /// @dev Answers the leg's fixed `[category, leaf]` pair for this adapter's own token, and `[]` for anything
    ///      else — including any malformed positionId, since this is a display-only view that must never revert
    ///      and a configuration view may probe it with an arbitrary word.
    ///
    ///      **The three guards below are load-bearing and survive the split unchanged.** Narrowing the accepted
    ///      set from two tokens to one does not weaken any of the reasons they exist, because the hostile input is
    ///      the CALLER's word, not the adapter's own leg count.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory) {
        // Exactly one word. The id this adapter emits (and the one {positionIds} advertises) is
        // `abi.encode(token)`, so a shorter buffer is unusable and a LONGER one is a foreign multi-word coordinate
        // whose first word could coincide with this leg's token — `abi.decode` ignores the tail, so `>= 32` would
        // label it as a Cap leg.
        if (positionId.length != 32) return new string[](0);
        // Decode as a raw word, not `abi.decode(positionId, (address))`: Solidity's decoder REVERTS on an address
        // whose upper 96 bits are dirty, which would turn a foreign positionId (e.g. a bytes32 pool/market id
        // copied from another adapter) into a revert. A dirty word is a non-Cap coordinate, so it takes the same
        // `[]` exit as any other unrecognised token — deliberately NOT truncated to its low 160 bits, which could
        // spell this leg's token by coincidence and mislabel a foreign id as a Cap leg.
        uint256 raw = abi.decode(positionId, (uint256));
        if (raw >> 160 != 0) return new string[](0);
        if (address(uint160(raw)) != _positionToken()) return new string[](0);
        string[] memory out = new string[](2);
        (out[0], out[1]) = _labelPair();
        return out;
    }

    //
    // IPositionEnumerable
    //

    /// @inheritdoc IPositionEnumerable
    /// @dev One shape: this adapter's single leg token, pinned at construction, so the set is fixed for the life of
    ///      this immutable adapter — there is no governed instance list and nothing account-dependent.
    ///
    ///      These are the SAME bytes `getAdapterPositions` puts in `PositionBalance.positionId`
    ///      (`abi.encode(_positionToken())`), which is what makes the configuration view joinable against real
    ///      positions — the guarantee {IPositionEnumerable} requires.
    ///
    ///      **Join on the bytes, not on the index**, and note this array is deliberately NOT index-aligned with
    ///      `getAdapterPositions`: that function omits the leg entirely when its balance is zero, so this
    ///      one-element array can pair with an EMPTY position list. The shape is reported unconditionally because
    ///      it describes what the adapter CAN report, not what anyone holds — and, for the same reason, listing it
    ///      does not imply USDC is registered on the NAVCalculator (without that registration
    ///      `getAdapterPositions` emits nothing for any account).
    function positionIds() external view override returns (bytes[] memory ids) {
        ids = new bytes[](1);
        ids[0] = abi.encode(_positionToken());
    }

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionEnumerable} to the base set. `super`-chains rather than restating the base list, which
    ///      is why {BalanceAdapterBase}'s `supportsInterface` is `public` — an `external` one cannot be reached
    ///      through `super`. Stays `pure`: the answer is a compile-time comparison, and a `pure` base cannot be
    ///      widened to `view` by an override anyway. Kept `virtual` so the chain the base opened does not
    ///      dead-end here.
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IPositionEnumerable).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice This leg's USDC-denominated position, or an empty array when the balance is zero, USDC is not
    ///         registered on the NAVCalculator, or the asset filter excludes USDC.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        // Symmetric with {SingleAssetBalanceAdapterBase.getAdapterBalances}, which guards the same case: a token
        // whose `balanceOf(address(0))` is non-zero (a burn sink) must not be reported as somebody's position.
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);
        // Cheap leg read first: the common case is a zero balance, so bail before touching the asset registry.
        uint256 amount = _owedAmount(account);
        if (amount == 0) return new INAVCalculator.PositionBalance[](0);

        // Only the USDC asset is reported; if it isn't registered, the position cannot be valued.
        (INAVCalculator.Asset memory underlyingAsset, bool found) =
            RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), UNDERLYING_TOKEN);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlyingAsset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: abi.encode(_positionToken()),
            positionKind: _positionKind(),
            isLocked: false,
            positionInstanceId: bytes32(0)
        });
    }

    //
    // Internal helpers
    //

    /// @notice USDC received for burning `cUsdAmount` of cUSD, net of Cap's protocol fee (0 for a zero amount).
    /// @dev The single valuation primitive both legs bottom out in, which is what keeps the two adapters' quotes
    ///      identical to the pre-split per-leg quotes and to each other (vigilo L-01).
    function _usdcForCUsd(uint256 cUsdAmount) internal view returns (uint256) {
        if (cUsdAmount == 0) return 0;
        (uint256 usdcAmount,) = CUSD.getBurnAmount(UNDERLYING_TOKEN, cUsdAmount);
        return usdcAmount;
    }
}
