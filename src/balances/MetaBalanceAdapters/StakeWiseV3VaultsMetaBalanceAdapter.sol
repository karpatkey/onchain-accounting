// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {InvalidArguments} from "src/errors.sol";

/// @notice Interface for interacting with StakeWise V3 vaults
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
/// @dev Reports the same gross Staking/Borrowed split a per-vault adapter would; only the signed-net
///      `getAdapterBalances`/`getAdapterBalanceForAsset` convenience getters are dropped (the meta base returns
///      them empty, since they are not on the NAV path).
contract StakeWiseV3VaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Longest ERC20 `name()` accepted as a label leaf; anything longer degrades to the address fallback.
    uint256 private constant MAX_NAME_BYTES = 256;

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
        if (underlyingToken_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(osTokenVaultController_, "osTokenVaultController");
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
    /// @dev `["Vault", <leaf>]` — the leaf is the vault's ERC20 `name()` when it has one, otherwise its address.
    ///      Unlike the other address-keyed meta-adapters this does NOT use {_addressLabels}: that helper collapses an
    ///      underivable leaf to `["Vault"]`, which for StakeWise is the common case, not the exception, and left every
    ///      row rendering the same blank breadcrumb.
    ///
    ///      **Tier 1 — `name()`.** Only StakeWise's `…Erc20Vault` implementation variants are ERC20s and answer it,
    ///      returning the operator's own name (e.g. `"Stakers Union GNO"`). Enumerating both `VaultsRegistry`
    ///      deployments on 2026-07-26 (mainnet `0x3a0008a5…`, Gnosis `0x7d014B3C…`) found 58 of 239 mainnet and 18 of
    ///      106 Gnosis registered vaults answering it. Read fail-open via {_safeVaultName} — which, unlike
    ///      {LabelLib.name}, also survives returndata that cannot be ABI-decoded as a string.
    ///
    ///      **Tier 2 — `"<underlying symbol> <vault address>"`**, e.g. `"GNO 0x4b4406ed…0a7a"`. The address is
    ///      rendered with `Strings.toHexString`, mirroring `NexusMutualStakingPoolsAssistedBalanceAdapter`'s fallback;
    ///      the symbol prefix says what the vault stakes without pretending to name it. This is the position
    ///      coordinate rather than a name, so it is the deliberate second choice — but it is always available, needs
    ///      no maintenance, and means the breadcrumb is never blank. All five instances configured today land here.
    ///      The symbol comes from the NAVCalculator asset registry rather than an ERC20 `symbol()` read, because on
    ///      mainnet `UNDERLYING_TOKEN` is the ETH sentinel (`0xEeee…EEeE`), which has no code to read. If the
    ///      underlying is unregistered the symbol is dropped and the leaf is the bare address.
    ///
    ///      The leaf is descriptive, NOT an identifier: operator names collide (three separate Gnosis vaults are all
    ///      named `"SEED"`), so consumers must key on `positionId`, never on the label.
    ///
    ///      **Why there is no better tier 2, so nobody re-investigates.** The non-ERC20 variants expose no
    ///      human-readable identity on chain at all:
    ///        - `name()` / `symbol()` / `contractURI()` / `metadataIpfsHash()` / `asset()` all revert on them
    ///          (checked against v3, v4, v5 and v7 vaults; newer versions do not help).
    ///        - `vaultId()` answers, but it is `keccak256(<implementation type string>)` — a *type* hash, not a
    ///          per-vault id, so it both collides (the two configured Gnosis vaults are both `GnoVault`) and would
    ///          need a hardcoded hash→string table to render, since the pre-image is not recoverable on chain.
    ///        - `version()` collides; `admin()` / `mevEscrow()` / `feeRecipient()` / `validatorsManager()` /
    ///          `implementation()` are addresses, not names, and most are mutable.
    ///        - `VaultsRegistry` stores only `vaults(address) → bool`; it holds no names.
    ///      Every human-readable StakeWise vault name lives off-chain (IPFS metadata), and `positionLabels` is an
    ///      on-chain view, so there is nothing further to derive.
    ///
    ///      Returns an empty array for a short positionId. Display-only and must never revert, hence the fail-open
    ///      read.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        // Decode as a raw word, not `abi.decode(pid, (address))`: Solidity's decoder REVERTS on an address whose
        // upper 96 bits are dirty, which would turn a foreign/malformed positionId into a revert of a view that
        // must never revert. A malformed coordinate degrades to the category alone instead.
        uint256 raw = abi.decode(pid, (uint256));
        if (raw >> 160 != 0) return _labels("Vault", "");
        address vault = address(uint160(raw));

        string memory leaf = _safeVaultName(vault);
        if (bytes(leaf).length == 0) {
            leaf = Strings.toHexString(vault);
            (INAVCalculator.Asset memory underlying, bool found) = _getAssetInfo(UNDERLYING_TOKEN);
            if (found && bytes(underlying.symbol).length != 0) {
                leaf = string.concat(underlying.symbol, " ", leaf);
            }
        }
        return _labels("Vault", leaf);
    }

    /// @notice Fail-open ERC20 `name()` read that also survives returndata which cannot be ABI-decoded as a string.
    /// @dev NOT {LabelLib.name}, deliberately. LabelLib guards a code-less address and a reverting call, but decodes
    ///      the result inside a `try`/`catch`, and Solidity does **not** route a return-data decode failure into the
    ///      `catch` clause — it propagates to the caller. So a vault whose `name()` *succeeds* but returns something
    ///      undecodable would revert this display-only view. Two realistic shapes do exactly that, both reproduced on
    ///      solc 0.8.34: empty returndata (an ERC-1967 proxy whose implementation slot points at a code-less address —
    ///      the `delegatecall` succeeds and returns nothing) and a `bytes32` name (MKR-style legacy tokens).
    ///
    ///      This validates the ABI head before decoding. A canonical `string` return is
    ///      `[offset = 0x20][length][payload…]`, so require two full words, an offset of exactly `0x20`, and a length
    ///      whose payload fits inside the returndata. Anything else yields "" and the caller falls back to the
    ///      address. The length cap additionally bounds a hostile vault's ability to inflate the rendered label.
    ///
    ///      `LabelLib` has the same weakness for every other adapter that reads a name/symbol through it. That is a
    ///      pre-existing, repo-wide issue and is deliberately NOT fixed here — changing shared behaviour for ~8 other
    ///      adapters belongs in its own reviewed change, not in a StakeWise label PR.
    function _safeVaultName(address vault) private view returns (string memory) {
        if (vault.code.length == 0) return "";
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("name()"));
        if (!ok || data.length < 64) return "";

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        if (offset != 0x20 || len == 0 || len > MAX_NAME_BYTES || len > data.length - 64) return "";

        return abi.decode(data, (string));
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
