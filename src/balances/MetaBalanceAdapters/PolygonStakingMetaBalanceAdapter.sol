// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {InvalidArguments} from "src/errors.sol";

/// @notice Interface for a Polygon PoS `ValidatorShare` contract (the per-validator delegation pool on Ethereum L1).
interface IValidatorShare {
    /// @notice An account's delegated principal and its unclaimed rewards, both in the staking token (POL).
    /// @dev One call for both legs. The alternative — `getTotalStake` plus `getLiquidRewards` — is two external
    ///      calls returning the same two numbers, and `getTotalStake`'s second return value (the exchange rate) is
    ///      not needed here because the first is already denominated in POL rather than in shares.
    function getStakeAndRewards(address user) external view returns (uint256 stakeAmount, uint256 liquidRewards);

    /// @notice The StakeManager validator id this share contract belongs to. Used only for the display label.
    function validatorId() external view returns (uint256);
}

/// @title Polygon Staking Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's Polygon PoS delegations across *any* validator —
///         emitting two gross legs per validator: `Staking` (delegated principal) and `Rewards` (unclaimed
///         rewards), both denominated in POL. The instance coordinate is the `ValidatorShare` address widened to
///         bytes32; the active validator set lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`).
///         Identity is encoded as `abi.encode(address(validatorShare))`. See ADR 0010.
/// @dev **These contracts live on Ethereum L1, not on Polygon.** Polygon PoS staking is settled by the
///      `StakeManager` at `0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908` on mainnet, which mints one
///      `ValidatorShare` per validator; delegators hold share tokens there. So this is a chain-1 adapter even
///      though the protocol is named after another chain.
///
///      **The staking token is POL, and it is independently checkable.** `StakeManager.token()` returns
///      `0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6` (POL). It is passed in rather than derived because that is
///      the family idiom (see {StakeWiseV3VaultsMetaBalanceAdapter}), and because reading it would mean pinning
///      the StakeManager too. Note that `ValidatorShare.polToken()` is NOT a usable source — it returns
///      `address(0)` on the live contracts (verified on-chain 2026-08-26).
///
///      **All 209 live `ValidatorShare`s share one implementation** (`0xbe63b977…e9e8`, verified 2026-08-26), and
///      `getStakeAndRewards` answers on 209/209, so the ABI assumed here is uniform across the validator set
///      rather than true only of the ones configured today.
///
///      **UNBONDING POSITIONS ARE NOT REPORTED — a deliberate, bounded under-report.** When a delegator starts an
///      unstake, the shares leave `getStakeAndRewards` and land in a per-account nonce-indexed queue
///      (`unbondNonces(account)` plus `unbonds_new(account, nonce)`, valued through `withdrawExchangeRate()`).
///      Reading it means iterating an unbounded nonce range per instance per account, on a path that is already
///      O(instances). It is omitted because the resulting error is an UNDER-report, which is the safe direction
///      under this repo's convention, and because DeBank does not surface those positions either — so a covered
///      account mid-unbond reads low against the same reference we reconcile with. If it is ever added, it needs
///      its own `isLocked = true` leg and a bound on the nonce walk.
contract PolygonStakingMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice The Polygon staking token all delegations are denominated in (POL on mainnet).
    address public immutable UNDERLYING_TOKEN;

    /// @notice Gas cap for the display-only `validatorId()` probe.
    /// @dev Mirrors {LabelLib}'s `METADATA_READ_GAS`. `positionLabels` must never revert nor let a hostile instance
    ///      burn the caller's gas, and this read is not routed through LabelLib because that library reads STRINGS;
    ///      `validatorId()` returns a `uint256`.
    uint256 private constant VALIDATOR_ID_READ_GAS = 100_000;

    /// @param underlyingToken_ The Polygon staking token (POL on mainnet; `StakeManager.token()`).
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address underlyingToken_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        if (underlyingToken_ == address(0)) revert InvalidArguments();
        UNDERLYING_TOKEN = underlyingToken_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the `ValidatorShare` address. Emits a `Staking` leg (delegated principal) and a `Rewards`
    ///      leg (unclaimed rewards), both denominated in POL and both non-debt, dropping zeros. Returns empty if
    ///      POL is unregistered or filtered out by `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        (INAVCalculator.Asset memory asset, bool found) = _getAssetInfo(UNDERLYING_TOKEN);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        // Both legs from one call. `stakeAmount` is already POL, not shares — no exchange-rate conversion applies.
        (uint256 staked, uint256 rewards) = IValidatorShare(_toAddress(instance)).getStakeAndRewards(account);

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;
        if (staked > 0) {
            temp[count++] = _leg(asset, staked, false, pid, PositionKind.Staking);
        }
        if (rewards > 0) {
            temp[count++] = _leg(asset, rewards, false, pid, PositionKind.Rewards);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `["Validator", <leaf>]`.
    ///
    ///      **Tier 1 — `"Validator #<validatorId>"`.** This does NOT use the ERC20 `name()` every other
    ///      address-keyed meta-adapter leans on, because `ValidatorShare.name()` is useless as an identifier here:
    ///      the live contracts return a per-validator-but-opaque string (`"Delegated POL #c0"` for validator 192),
    ///      and nothing ties the `#c0` suffix to the validator id a user would recognise. `validatorId()` is the
    ///      real coordinate — it is what the StakeManager keys on and what block explorers and staking UIs show —
    ///      so the breadcrumb is derived from it instead.
    ///
    ///      **Tier 2 — `"<POL symbol> <share address>"`**, e.g. `"POL 0x97997023…4868"`, mirroring
    ///      {StakeWiseV3VaultsMetaBalanceAdapter}'s fallback: always available, never blank, and distinct per
    ///      instance. The symbol comes from the NAV asset registry rather than an ERC20 `symbol()` read so that an
    ///      unregistered or code-less underlying degrades to the bare address instead of reverting.
    ///
    ///      The leaf is descriptive, NOT an identifier — consumers must key on `positionId`.
    ///
    ///      Display-only and must never revert, hence the capped fail-open read. Returns an empty array for a
    ///      positionId that is not exactly one word.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        // Exactly one word, not `< 32`: `abi.decode` ignores trailing bytes, so a `< 32` guard would let a foreign
        // MULTI-word coordinate through and label it from its first word — a confident, wrong breadcrumb for a
        // position this adapter never emitted.
        if (pid.length != 32) return new string[](0);
        // Decode as a raw word, not `abi.decode(pid, (address))`: Solidity's decoder REVERTS on an address with
        // dirty upper bits, which would turn a malformed positionId into a revert of a view that must not revert.
        uint256 raw = abi.decode(pid, (uint256));
        if (raw >> 160 != 0) return _labels("Validator", "");
        address share = address(uint160(raw));

        (uint256 validatorId, bool ok) = _readValidatorId(share);
        if (ok) return _labels("Validator", string.concat("#", Strings.toString(validatorId)));

        string memory leaf = Strings.toHexString(share);
        (INAVCalculator.Asset memory underlying, bool registered) = _getAssetInfo(UNDERLYING_TOKEN);
        if (registered && bytes(underlying.symbol).length != 0) {
            leaf = string.concat(underlying.symbol, " ", leaf);
        }
        return _labels("Validator", leaf);
    }

    /// @notice Fail-open, gas-capped `validatorId()` probe for the display label.
    /// @dev Returns `(0, false)` on every failure path: no code, revert, gas exhaustion, or a reply that is not
    ///      exactly one word. The `size != 32` check is the load-bearing one — a contract returning a longer or
    ///      shorter payload is not answering this selector, and decoding it anyway would render a confident wrong
    ///      validator number. Bounded output size means a hostile instance cannot blow up caller memory either.
    function _readValidatorId(address share) private view returns (uint256 id, bool ok) {
        if (share.code.length == 0) return (0, false);
        bytes4 selector = IValidatorShare.validatorId.selector;
        bool success;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(VALIDATOR_ID_READ_GAS, share, 0x00, 0x04, 0x20, 0x20)
            size := returndatasize()
            word := mload(0x20)
        }
        if (!success || size != 32) return (0, false);
        return (word, true);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.POLYGON;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.POLYGON;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.POLYGON_STAKING;
    }
}
