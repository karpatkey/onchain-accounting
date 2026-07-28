// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Gearbox V3 Markets Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's supply position in *any* Gearbox V3 ERC4626 farming
///         pool — `convertToAssets(balanceOf(account))` emitted as a single `Supplied` leg in the pool's underlying.
///         The instance coordinate is the market (pool) address, widened to bytes32; the active market set lives
///         on NAVCalculator (`addMetaInstances`/`removeMetaInstances`). Identity is encoded as `abi.encode(address(market))`.
///         See ADR 0010.
/// @dev Reports one Supply leg per market (convertToAssets(balanceOf)) in the pool's underlying. Does not include
///      Merkl rewards (those are covered separately by the Merkl rewards adapter).
/// @dev **Instance set is a governed allowlist — not auto-enumerated.** Gearbox V3 exposes an on-chain
///      `ContractsRegister` (mainnet `0xA50d4E7D8946a7c90652339CDBd262c375d54D99`, `getPools()`) listing the DAO's
///      pools, and this adapter could read it to avoid governance seeding instances. We deliberately do NOT: the
///      active set stays the MANAGER-curated `bytes32[]` on NAVCalculator. Rationale — (1) NAV integrity: balances
///      are read trustlessly from the pool, so auto-including arbitrary pools would let an untrusted instance report
///      a fabricated balance in a NAV-registered asset; the allowlist is the mitigation. (2) The register is the
///      wrong set for us anyway — the KPK-curated markets this adapter actually serves are deployed off the main
///      `ContractsRegister` and are not in its `getPools()`, while the register carries pools we do not use (incl.
///      deprecated/zombie entries). Use the register off-chain to *propose* instances; governance approves them.
///      See BALANCE_ADAPTERS.md §6.1.
contract GearboxV3MarketsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the market (ERC4626 pool) address. Emits one `Supplied` leg in the market's underlying,
    ///      dropping a zero balance and skipping an unregistered/filtered asset.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IERC4626 market = IERC4626(_toAddress(instance));
        address asset = market.asset();
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        uint256 amount = market.convertToAssets(market.balanceOf(account));
        if (amount == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = _leg(assetInfo, amount, false, _instancePositionId(instance), PositionKind.Supplied);
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market", <name>]` where the leaf is the market's ERC20 name; if the name is unreadable the
    ///      empty leaf is dropped and just `["Market"]` is returned (see `_labels`). Returns an empty array for a
    ///      malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Market", false);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX_V3_MARKETS;
    }
}
