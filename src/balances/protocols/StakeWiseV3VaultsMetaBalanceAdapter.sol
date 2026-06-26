// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
/// @author kpk
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
    bytes32 private constant PROTOCOL_ID = ProtocolIds.STAKEWISE_V3;

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
            temp[count++] = _row(asset, vaultAssets, false, pid, PositionKind.Staking);
        }
        if (mintedOs > 0) {
            temp[count++] = _row(asset, mintedOs, true, pid, PositionKind.Borrowed);
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
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        if (pid.length < 32) return "";
        address vault = abi.decode(pid, (address));
        try IERC20Metadata(vault).name() returns (string memory n) {
            return n;
        } catch {
            return "";
        }
    }

    function _row(INAVCalculator.Asset memory asset, uint256 amount, bool isDebt, bytes memory pid, PositionKind kind)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: PROTOCOL_ID,
            positionId: pid,
            positionKind: kind
        });
    }
}
