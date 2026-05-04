// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Fluid Vault Balance Oracle (T1)
/// @author kpk
/// @notice Reports an account's collateral and debt balances for a single Fluid T1 vault.
///         Smart vaults (T2/T3/T4, Dex-backed legs) use a different vault contract whose
///         `constantsView()` has a different shape — they are out of scope for this adapter and
///         must not be wired in config. The constructor's `IFluidVaultT1.constantsView()` decode
///         requires the deployed implementation to expose `supplyToken` / `borrowToken` as plain
///         `address` fields (the T1 layout); a Smart-vault address would surface implementation
///         contracts in those slots, which we guard against best-effort by requiring both tokens
///         to be non-zero contract addresses.
/// @dev    Positions in Fluid are tracked as ERC721 NFTs minted by the VaultFactory. To
///         enumerate an account's positions across vaults, we call
///         `IFluidVaultResolver.positionsNftIdOfUser(account)` for the list of NFT IDs, then for
///         each NFT call `positionByNftId(nftId)` via low-level staticcall and decode JUST the
///         `UserPosition` prefix (12 statically-laid-out 32-byte words). The trailing
///         `VaultEntireData` payload is ignored — it varies in shape across resolver versions
///         and we don't need it.
///         FLUID/Merkl reward emissions are NOT included here (separate Merkl adapter).
contract FluidVaultBalanceOracle is IBalanceOracleAdapter {
    //
    // Type Definitions
    //

    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice The Fluid T1 vault contract this adapter reports on
    address public immutable VAULT;

    /// @notice The Fluid VaultResolver — only used at runtime for NFT enumeration and per-NFT
    ///         position reads. NOT consulted in the constructor (we read the vault directly).
    address public immutable VAULT_RESOLVER;

    /// @notice The collateral (supply) token, cached at construction
    address public immutable COLLATERAL_TOKEN;

    /// @notice The debt (borrow) token, cached at construction
    address public immutable DEBT_TOKEN;

    /// @notice NAVCalculator, used to filter to registered assets and resolve symbol/decimals
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier (e.g. "Fluid Vault")
    string private _protocol;
    /// @notice Position detail (e.g. "wstETH/USDC")
    string private _positionDetail;

    //
    // Constructor
    //

    /// @param vault_ The Fluid T1 vault address.
    /// @param vaultResolver_ The Fluid VaultResolver address (used only at runtime for NFT
    ///                       enumeration and per-NFT position reads).
    /// @param protocol_ Protocol identifier (e.g. "Fluid Vault").
    /// @param positionDetail_ Position detail label (e.g. "wstETH/USDC").
    /// @param navCalculator_ NAVCalculator address (asset registry source).
    constructor(
        address vault_,
        address vaultResolver_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (vault_ == address(0) || vaultResolver_ == address(0)) {
            revert InvalidArguments();
        }
        require(vault_.code.length > 0, "Vault must be a contract");
        require(vaultResolver_.code.length > 0, "VaultResolver must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        VAULT = vault_;
        VAULT_RESOLVER = vaultResolver_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        // Read tokens directly from the T1 vault. The `IFluidVaultT1.ConstantViews` struct is
        // purely static and matches the layout currently deployed for production T1 vaults
        // (single-address `supplyToken` / `borrowToken`, no Dex wrapper). Smart vaults — built on
        // a different vault contract whose `constantsView` has a different shape — are out of
        // scope; if a Smart vault address is wired here by mistake the decode would yield
        // implementation addresses in the token slots, which we guard against by requiring
        // both tokens to be contract addresses with code on the current chain.
        IFluidVaultT1.ConstantViews memory cv = IFluidVaultT1(vault_).constantsView();

        require(cv.supplyToken != address(0) && cv.borrowToken != address(0), "Vault tokens must be non-zero");
        // Sanity-check that the tokens look like deployed ERC20 contracts. A Smart vault would
        // surface implementation addresses here; the implementation contracts won't share the
        // ERC20 surface, but they DO have code, so this check is best-effort. Operators must
        // confirm the configured vault is T1 before wiring it.
        require(cv.supplyToken.code.length > 0, "supplyToken not a contract");
        require(cv.borrowToken.code.length > 0, "borrowToken not a contract");

        COLLATERAL_TOKEN = cv.supplyToken;
        DEBT_TOKEN = cv.borrowToken;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        if (COLLATERAL_TOKEN == DEBT_TOKEN) {
            address[] memory single = new address[](1);
            single[0] = COLLATERAL_TOKEN;
            return single;
        }
        address[] memory pair = new address[](2);
        pair[0] = COLLATERAL_TOKEN;
        pair[1] = DEBT_TOKEN;
        return pair;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        if (asset != COLLATERAL_TOKEN && asset != DEBT_TOKEN) return (0, false);
        (uint256 collateral, uint256 debt) = _aggregateUserPositions(account);
        if (asset == COLLATERAL_TOKEN) return (collateral, false);
        return (debt, true);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        (uint256 collateral, uint256 debt) = _aggregateUserPositions(account);
        return _shapeBalances(collateral, debt);
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's positions in this vault.
    /// @dev Only emits positions for assets that are registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Intersection: assets that are both supported by this vault and registered in NAVCalculator
        address[] memory eligible = ArrayLib.intersection(supportedAssets, registeredAssets);
        if (eligible.length == 0) return _buildPositions(new AssetBalanceData[](0));

        // Short-circuit when assetFilter is set to something the vault doesn't track at all,
        // so we don't pay for an NFT enumeration that's guaranteed to be discarded.
        if (assetFilter != address(0)) {
            bool inEligible = false;
            for (uint256 i = 0; i < eligible.length; i++) {
                if (eligible[i] == assetFilter) {
                    inEligible = true;
                    break;
                }
            }
            if (!inEligible) return _buildPositions(new AssetBalanceData[](0));
        }

        // One walk through the user's NFTs is enough to populate both legs.
        (uint256 collateral, uint256 debt) = _aggregateUserPositions(account);

        AssetBalanceData[] memory tempData = new AssetBalanceData[](eligible.length);
        uint256 count = 0;
        for (uint256 i = 0; i < eligible.length; i++) {
            address asset = eligible[i];
            if (assetFilter != address(0) && asset != assetFilter) continue;

            (uint256 amt, bool debt_) = _legFor(asset, collateral, debt);
            if (amt == 0) continue;

            tempData[count] = AssetBalanceData({asset: asset, amount: amt, isDebt: debt_});
            count++;
        }

        AssetBalanceData[] memory data = new AssetBalanceData[](count);
        for (uint256 i = 0; i < count; i++) {
            data[i] = tempData[i];
        }
        positions = _buildPositions(data);
    }

    //
    // Internal Helpers
    //

    /// @notice Walks the user's NFTs through the resolver ONCE and aggregates both legs.
    /// @dev    Steps:
    ///           1. Fetch the list of NFT IDs owned by the user via
    ///              `IFluidVaultResolver.positionsNftIdOfUser(account)`. Pure dynamic uint array,
    ///              no struct decode.
    ///           2. For each NFT, fetch its vault via
    ///              `IFluidVaultResolver.vaultByNftId(nftId)` and skip if it isn't this vault.
    ///           3. For each matching NFT, low-level staticcall `positionByNftId(nftId)` and read
    ///              just the three words we need from the `UserPosition` prefix:
    ///                - byte offset  64 → `isLiquidated` (bool)
    ///                - byte offset 288 → `supply` (uint256, in collateral-token decimals)
    ///                - byte offset 320 → `borrow` (uint256, in debt-token decimals)
    ///              The trailing `VaultEntireData` field is ignored.
    /// @return collateralTotal Total collateral magnitude (in collateral-token decimals).
    /// @return debtTotal Total debt magnitude (in debt-token decimals).
    function _aggregateUserPositions(address account)
        internal
        view
        returns (uint256 collateralTotal, uint256 debtTotal)
    {
        if (account == address(0)) return (0, 0);

        uint256[] memory nftIds = IFluidVaultResolver(VAULT_RESOLVER).positionsNftIdOfUser(account);
        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            if (IFluidVaultResolver(VAULT_RESOLVER).vaultByNftId(nftId) != VAULT) continue;

            (bool ok, bytes memory ret) =
                VAULT_RESOLVER.staticcall(abi.encodeWithSelector(IFluidVaultResolver.positionByNftId.selector, nftId));
            if (!ok || ret.length < 384) continue;

            (uint256 supply, uint256 borrow, bool isLiquidated) = _readUserPositionPrefix(ret);
            if (isLiquidated) continue;
            collateralTotal += supply;
            debtTotal += borrow;
        }
    }

    /// @notice Maps an asset to its (amount, isDebt) leg given the aggregated totals.
    function _legFor(address asset, uint256 collateral, uint256 debt) internal view returns (uint256 amt, bool isDebt) {
        // T1 vaults always have distinct collateral and debt tokens (we enforce non-zero in the
        // constructor). The COLLATERAL_TOKEN == DEBT_TOKEN case is defensive only.
        if (asset == COLLATERAL_TOKEN) return (collateral, false);
        if (asset == DEBT_TOKEN) return (debt, true);
        return (0, false);
    }

    /// @notice Builds the IBalanceOracleAdapter.getOracleBalances tuple from aggregated totals,
    ///         skipping zero-amount entries.
    function _shapeBalances(uint256 collateral, uint256 debt)
        internal
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            (uint256 amt, bool debt_) = _legFor(asset, collateral, debt);
            if (amt == 0) continue;
            tempAssets[count] = asset;
            tempAmounts[count] = amt;
            tempIsDebt[count] = debt_;
            count++;
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
            isDebt[i] = tempIsDebt[i];
        }
    }

    /// @notice Reads the static prefix of a `(UserPosition, VaultEntireData)` ABI-encoded return.
    /// @dev    `UserPosition` is laid out as 12 sequential 32-byte words:
    ///           [0]   nftId
    ///           [32]  owner
    ///           [64]  isLiquidated
    ///           [96]  isSupplyPosition
    ///           [128] tick
    ///           [160] tickId
    ///           [192] beforeSupply
    ///           [224] beforeBorrow
    ///           [256] beforeDustBorrow
    ///           [288] supply
    ///           [320] borrow
    ///           [352] dustBorrow
    ///         All other return bytes (the trailing VaultEntireData) are ignored, so this decode
    ///         is robust to resolver-version changes in the trailing struct.
    function _readUserPositionPrefix(bytes memory ret)
        internal
        pure
        returns (uint256 supply, uint256 borrow, bool isLiquidated)
    {
        uint256 isLiquidatedWord;
        assembly {
            let dataPtr := add(ret, 32) // skip the bytes-length prefix
            isLiquidatedWord := mload(add(dataPtr, 64))
            supply := mload(add(dataPtr, 288))
            borrow := mload(add(dataPtr, 320))
        }
        isLiquidated = isLiquidatedWord != 0;
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Returns the `positionDetail` label for a given asset/leg.
    function _positionDetailFor(address asset, bool isDebt) internal view returns (string memory) {
        if (asset == COLLATERAL_TOKEN && !isDebt) return string.concat(_positionDetail, " Collateral");
        if (asset == DEBT_TOKEN && isDebt) return string.concat(_positionDetail, " Borrow");
        return _positionDetail;
    }

    /// @notice Builds PositionBalance array from pre-computed asset balance data
    function _buildPositions(AssetBalanceData[] memory data)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (data.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory tempPositions = new INAVCalculator.PositionBalance[](data.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < data.length; i++) {
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(data[i].asset);
            tempPositions[positionCount] = INAVCalculator.PositionBalance({
                underlyingAsset: underlyingAsset,
                balanceOracle: address(this),
                amount: data[i].amount,
                isDebt: data[i].isDebt,
                protocol: _protocol,
                positionDetail: _positionDetailFor(data[i].asset, data[i].isDebt)
            });
            positionCount++;
        }

        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}

/// @notice Minimal Fluid T1 vault interface — just the static `constantsView` getter we use to
///         read the vault's collateral/debt tokens at construction time. T1 vaults
///         (single-collateral, single-debt) are the only shape this adapter supports; Smart
///         vaults use a different vault contract with a different `ConstantViews` layout and are
///         intentionally out of scope.
interface IFluidVaultT1 {
    struct ConstantViews {
        address liquidity;
        address factory;
        address adminImplementation;
        address secondaryImplementation;
        address supplyToken;
        address borrowToken;
        uint8 supplyDecimals;
        uint8 borrowDecimals;
        uint256 vaultId;
        bytes32 liquiditySupplyExchangePriceSlot;
        bytes32 liquidityBorrowExchangePriceSlot;
        bytes32 liquidityUserSupplySlot;
        bytes32 liquidityUserBorrowSlot;
    }

    function constantsView() external view returns (ConstantViews memory);
}

/// @notice Minimal Fluid VaultResolver interface — only the views the adapter calls at runtime.
///         We deliberately avoid declaring `getVaultEntireData` / `positionsByUser` here because
///         their return tuples carry a heavy `VaultEntireData` struct whose layout differs across
///         resolver versions and which this adapter does not need.
interface IFluidVaultResolver {
    /// @notice All NFT IDs owned by `user` across every Fluid vault.
    function positionsNftIdOfUser(address user) external view returns (uint256[] memory nftIds);

    /// @notice Vault address that minted `nftId`.
    function vaultByNftId(uint256 nftId) external view returns (address vault);

    /// @notice Per-NFT position details. Returns `(UserPosition, VaultEntireData)` — but this
    ///         adapter only consumes the static `UserPosition` prefix via low-level staticcall
    ///         + manual decode, so the second return field is intentionally not declared here.
    ///         The selector exposed is what we use to encode the call data.
    function positionByNftId(uint256 nftId) external view returns (UserPosition memory userPosition);

    struct UserPosition {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        int256 tick;
        uint256 tickId;
        uint256 beforeSupply;
        uint256 beforeBorrow;
        uint256 beforeDustBorrow;
        uint256 supply;
        uint256 borrow;
        uint256 dustBorrow;
    }
}
