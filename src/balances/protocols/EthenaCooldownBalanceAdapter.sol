// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Ethena Cooldown Balance Adapter
/// @author KPK
/// @notice Reports the USDe owed to an account that is in the sUSDe unstaking cooldown.
/// @dev When a holder calls `cooldownShares`/`cooldownAssets` on StakedUSDeV2, the sUSDe is burned and the
///      underlying USDe is moved to a silo, recorded against the holder as a single `UserCooldown`
///      `{ uint104 cooldownEnd, uint152 underlyingAmount }`. `underlyingAmount` is the USDe claimable once
///      `cooldownEnd` passes (via `unstake`); the entry is zeroed on claim. There is exactly one cooldown
///      slot per account (a new cooldown adds to it), so no enumeration is needed — a single
///      `cooldowns(account)` read gives the full pending amount. This adapter reports that amount as one
///      position denominated in `UNDERLYING_TOKEN` (USDe). Correctness-on-exit coverage: it is non-zero only
///      while an unstake is in flight.
contract EthenaCooldownBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Constants
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.ETHENA_COOLDOWN;

    //
    // State
    //

    /// @notice Ethena StakedUSDeV2 (sUSDe) contract, which holds the per-account cooldown record.
    IStakedUSDeV2 public immutable STAKED_USDE;

    /// @notice The asset positions are reported in (USDe). Pricing is added by NAVCalculator from its feed.
    address public immutable UNDERLYING_TOKEN;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param stakedUSDe_ Address of Ethena's StakedUSDeV2 (sUSDe) contract.
    /// @param underlyingToken_ Address of USDe — the asset positions are denominated in.
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(address stakedUSDe_, address underlyingToken_, address navCalculator_) {
        if (stakedUSDe_ == address(0) || underlyingToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(stakedUSDe_.code.length > 0, "StakedUSDeV2 must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        STAKED_USDE = IStakedUSDeV2(stakedUSDe_);
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Balance computation
    //

    /// @notice The USDe pending in the account's sUSDe cooldown (claimable + still-cooling), or 0 if none.
    /// @dev Reads the single `UserCooldown` slot; `underlyingAmount` is zeroed when the account claims via
    ///      `unstake`, so a closed/never-opened cooldown returns 0.
    function _pendingUsde(address account) internal view returns (uint256) {
        if (account == address(0)) {
            return 0;
        }
        (, uint152 underlyingAmount) = STAKED_USDE.cooldowns(account);
        return uint256(underlyingAmount);
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Ethena";
    }

    /// @inheritdoc IPositionDescribable
    function describePosition(bytes calldata) external pure returns (string memory) {
        return "Ethena unstaking cooldown (USDe)";
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != UNDERLYING_TOKEN) {
            return (0, false);
        }
        return (_pendingUsde(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 total = _pendingUsde(account);
        if (total == 0) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
        isDebt[0] = false;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns the account's pending cooldown as a single balance-only position.
    /// @dev Dropped (empty array) if the underlying asset is not registered in NAVCalculator or the amount is 0.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Asset-filter mismatch → no positions for this adapter.
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Cheap single read first: the common case is no cooldown, so bail before fetching/scanning
        // the registered-asset list.
        uint256 total = _pendingUsde(account);
        if (total == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.Asset memory underlying;
        bool registered;
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == UNDERLYING_TOKEN) {
                underlying = reg[i];
                registered = true;
                break;
            }
        }
        if (!registered) {
            return new INAVCalculator.PositionBalance[](0);
        }

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: total,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: "",
            positionKind: PositionKind.Supplied
        });
    }
}

/// @notice Minimal interface for Ethena's StakedUSDeV2 cooldown record.
/// @dev `cooldowns` is the auto-generated getter for `mapping(address => UserCooldown)` where
///      `UserCooldown { uint104 cooldownEnd; uint152 underlyingAmount; }`.
interface IStakedUSDeV2 {
    function cooldowns(address account) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
}
