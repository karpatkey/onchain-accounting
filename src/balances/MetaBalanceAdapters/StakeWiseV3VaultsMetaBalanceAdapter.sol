// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Interface for interacting with StakeWise v3 vaults
interface IStakeWiseVault {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Gets the amount of vault shares owned by an account
    function getShares(address account) external view returns (uint256);

    /// @notice Gets the amount of osTokens minted against an account's position (in osToken SHARES).
    function osTokenPositions(address account) external view returns (uint256);
}

/// @notice StakeWise OsTokenVaultController — converts osToken shares to the underlying asset amount. The osToken
///         debt is denominated in osToken shares whose exchange rate is governed here, NOT by the staking vault's
///         share→asset rate (a different object), so the Borrowed leg must convert through this controller.
interface IOsTokenVaultController {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title StakeWise V3 Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's StakeWise V3 vault positions across *any* vault on a
///         chain — emitting two gross legs per vault: `Staking` (vault shares → underlying) and `Borrowed` (minted
///         osToken debt → underlying). The instance coordinate is the vault address, widened to bytes32; the
///         active vault set lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`). The underlying token (the staking asset,
///         e.g. the ETH sentinel on mainnet / GNO on Gnosis) is the chain-level constant pinned in the
///         constructor. Identity is encoded as `abi.encode(address(vault))`. See ADR 0010.
/// @dev Reports the gross
///      Staking/Borrowed split is the same; only the signed-net `getAdapterBalances`/`getAdapterBalanceForAsset`
///      convenience getters of the per-vault adapter are dropped (they are not on the NAV path).
contract StakeWiseV3VaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice The underlying staking asset all configured vaults are denominated in (chain-level constant).
    address public immutable UNDERLYING_TOKEN;

    /// @notice StakeWise OsTokenVaultController for this chain — converts osToken-debt shares to the underlying.
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @param underlyingToken_ The underlying staking asset (e.g. ETH sentinel on mainnet, GNO on Gnosis).
    /// @param osTokenVaultController_ The chain's StakeWise OsTokenVaultController (same one osToken_CustomPriceFeed uses).
    /// @param protocolName_ Human-readable protocol name (e.g. "StakeWise V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(
        address underlyingToken_,
        address osTokenVaultController_,
        string memory protocolName_,
        address navCalculator_
    ) MetaBalanceAdapter(protocolName_, navCalculator_) {
        require(underlyingToken_ != address(0), "underlyingToken=0");
        require(osTokenVaultController_.code.length > 0, "osTokenVaultController not a contract");
        UNDERLYING_TOKEN = underlyingToken_;
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenVaultController_);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the vault address. Emits a `Staking` leg (vault shares) and a `Borrowed` leg (osToken
    ///      debt), both denominated in the underlying token, dropping zeros. Returns empty if the underlying is
    ///      unregistered or filtered out by `assetFilter`.
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

        IStakeWiseVault vault = IStakeWiseVault(_toAddress(instance));
        // Staking leg: vault shares → underlying via the vault's own rate.
        uint256 vaultAssets = vault.convertToAssets(vault.getShares(account));
        // Borrow leg: osToken debt is in osToken SHARES → convert via the OsTokenVaultController's rate, NOT the
        // vault's share rate (different exchange-rate object), or the debt is mis-scaled.
        uint256 mintedOs = OS_TOKEN_VAULT_CONTROLLER.convertToAssets(vault.osTokenPositions(account));

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;
        if (vaultAssets > 0) {
            temp[count++] = _leg(asset, vaultAssets, false, pid, PositionKind.Staking);
        }
        if (mintedOs > 0) {
            temp[count++] = _leg(asset, mintedOs, true, pid, PositionKind.Borrowed);
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
    /// @dev Returns a single-element `["Vault"]`. StakeWise V3 vaults are minimal proxies with no on-chain
    ///      ERC20 `name()`/`symbol()` (the human vault name lives off-chain via IPFS), so there is no leaf to
    ///      derive — the category alone is the label. Returns an empty array for a short positionId.
    function positionLabels(bytes calldata pid) external pure override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        return _labels("Vault", "");
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.STAKEWISE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.STAKEWISE_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.STAKEWISE_V3_VAULTS;
    }
}
