// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {IStakeWiseVault} from "src/balances/protocols/StakeWiseV3Vault.sol";

/// @title StakeWise V3 Vaults Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's StakeWise V3 vault positions across *any* vault on a
///         chain — emitting two gross legs per vault: `Staking` (vault shares → underlying) and `Borrow` (minted
///         osToken debt → underlying). The instance coordinate is the vault address, widened to bytes32; the
///         active vault set lives on NAVCalculator (`setMetaInstances`). The underlying token (the staking asset,
///         e.g. the ETH sentinel on mainnet / GNO on Gnosis) is the chain-level constant pinned in the
///         constructor. Identity is derived on-chain (positionId = vault address; name = vault `name()`).
///         See ADR 0010.
/// @dev Mirrors the per-vault `StakeWiseV3VaultBalanceOracle` leg-for-leg (parity fork-tested): the gross
///      Staking/Borrow split is the same; only the signed-net `getOracleBalances`/`getOracleBalanceForAsset`
///      convenience getters of the per-vault adapter are dropped (they are not on the NAV path).
contract StakeWiseV3VaultsMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;

    /// @notice The underlying staking asset all configured vaults are denominated in (chain-level constant).
    address public immutable UNDERLYING_TOKEN;

    /// @param underlyingToken_ The underlying staking asset (e.g. ETH sentinel on mainnet, GNO on Gnosis).
    /// @param protocol_ Protocol identifier (e.g. "StakeWise V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address underlyingToken_, string memory protocol_, address navCalculator_)
        MetaBalanceOracle(protocol_, navCalculator_)
    {
        require(underlyingToken_ != address(0), "underlyingToken=0");
        UNDERLYING_TOKEN = underlyingToken_;
    }

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the vault address. Emits a `Staking` leg (vault shares) and a `Borrow` leg (osToken
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
        uint256 vaultAssets = vault.convertToAssets(vault.getShares(account));
        uint256 mintedOs = vault.convertToAssets(vault.osTokenPositions(account));

        string memory positionId = address(vault).toHexString();
        string memory base = _detailBase(address(vault));

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;
        if (vaultAssets > 0) {
            temp[count++] =
                _row(asset, vaultAssets, false, positionId, PositionType.withType(base, PositionType.STAKING));
        }
        if (mintedOs > 0) {
            temp[count++] = _row(asset, mintedOs, true, positionId, PositionType.withType(base, PositionType.BORROW));
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bool isDebt,
        string memory positionId,
        string memory detail
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            underlyingAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: isDebt,
            protocol: _protocol,
            positionDetail: detail,
            positionId: positionId
        });
    }

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain from the vault's ERC20 `name()`,
    ///         falling back to the vault address for vaults that don't expose a name.
    function _detailBase(address vault) private view returns (string memory) {
        string memory name;
        try IERC20Metadata(vault).name() returns (string memory n) {
            name = bytes(n).length == 0 ? vault.toHexString() : n;
        } catch {
            name = vault.toHexString();
        }
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Vault\",\"name\":\"", name, "\"");
    }
}
