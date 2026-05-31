// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {FluidVaultLib} from "src/balances/protocols/FluidVaultLib.sol";

/// @title Fluid Vaults Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's collateral + debt across *any* Fluid T1 vault — a
///         `Collateral` leg (supply) and a `Borrow` leg (debt) per vault, aggregated over the account's NFT
///         positions. The instance coordinate is the vault address, widened to bytes32; the active vault set
///         lives on NAVCalculator (`setMetaInstances`). The Fluid VaultResolver is the chain-level constant
///         pinned in the constructor. Identity is derived on-chain (positionId = vault address; name =
///         `collSym/debtSym`). See ADR 0010.
/// @dev Read logic (tokens via `constantsView`, NFT aggregation) is delegated to `FluidVaultLib`, mirroring the
///      per-vault `FluidVaultBalanceOracle` leg-for-leg (parity fork-tested). T1 vaults only — Smart vaults
///      (T2/T3/T4) have a different `constantsView` layout and must not be configured.
contract FluidVaultsMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;

    /// @notice The Fluid VaultResolver (chain-level constant; used for NFT enumeration + per-NFT position reads).
    address public immutable VAULT_RESOLVER;

    /// @param vaultResolver_ The Fluid VaultResolver address.
    /// @param protocol_ Protocol identifier (e.g. "Fluid").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vaultResolver_, string memory protocol_, address navCalculator_)
        MetaBalanceOracle(protocol_, navCalculator_)
    {
        require(vaultResolver_.code.length > 0, "VaultResolver must be a contract");
        VAULT_RESOLVER = vaultResolver_;
    }

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the T1 vault address. Emits a `Collateral` leg (supply token) and a `Borrow` leg (debt
    ///      token), dropping zeros and unregistered assets, respecting `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address vault = _toAddress(instance);
        (address collToken, address debtToken) = FluidVaultLib.tokens(vault);
        (uint256 collateral, uint256 debt) = FluidVaultLib.aggregate(vault, VAULT_RESOLVER, account);

        string memory positionId = vault.toHexString();
        string memory base = _detailBase(collToken, debtToken);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;

        if (collateral > 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(collToken, assetFilter);
            if (ok) {
                temp[count++] =
                    _row(a, collateral, false, positionId, PositionType.withType(base, PositionType.COLLATERAL));
            }
        }
        if (debt > 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(debtToken, assetFilter);
            if (ok) temp[count++] = _row(a, debt, true, positionId, PositionType.withType(base, PositionType.BORROW));
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        (address collToken, address debtToken) = FluidVaultLib.tokens(_toAddress(instance));
        if (collToken == debtToken) {
            assets = new address[](1);
            assets[0] = collToken;
        } else {
            assets = new address[](2);
            assets[0] = collToken;
            assets[1] = debtToken;
        }
    }

    function _eligible(address token, address assetFilter)
        private
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
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

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain as `collSym/debtSym`.
    function _detailBase(address collToken, address debtToken) private view returns (string memory) {
        string memory name = string.concat(_symbol(collToken), "/", _symbol(debtToken));
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Vault\",\"name\":\"", name, "\"");
    }

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens.
    function _symbol(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? "?" : s;
        } catch {
            return "?";
        }
    }
}
