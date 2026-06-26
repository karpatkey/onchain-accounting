// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice A balance adapter for the DAI token that uses the DSRManager contract to calculate the balance.
contract DaiDsrBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // Constants
    //

    /// @notice Copied from the original DSRManager contract
    /// @notice https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    uint256 public constant RAY = 10 ** 27;

    //
    // Type Definitions
    //

    /// @notice Asset balance data structure
    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice Address of the DAI token
    address public immutable DAI;

    /// @notice Address of the DSR Manager contract.
    DsrManager public immutable DSR_MANAGER;

    /// @notice Address of the Pot contract
    PotLike public immutable POT;

    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol ID for DAI Savings Rate
    bytes32 private constant PROTOCOL_ID = ProtocolIds.DAI_DSR;

    //
    // Constructor
    //

    /// @param dai_ The address of the DAI token
    /// @param dsrManager_ The address of the DSR Manager contract
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(address dai_, address dsrManager_, address navCalculator_) {
        if (dai_ == address(0) || dsrManager_ == address(0)) revert InvalidArguments();
        require(dsrManager_.code.length > 0, "DSRManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        DAI = dai_;
        DSR_MANAGER = DsrManager(dsrManager_);
        POT = DSR_MANAGER.pot();
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance as uint256 (always non-negative for DSR)
    function _calculateBalance(address underlyingAsset, address account) internal view returns (uint256 balance) {
        if (underlyingAsset != DAI) {
            revert InvalidArguments();
        }
        return _daiBalance(account); // DSR is always credit (positive)
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = DAI;
        return assets;
    }

    //
    // Internal API
    //

    /// @notice Adapted from the write-function on the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param usr The address of the account
    /// @return wad The balance of the account
    function _daiBalance(address usr) internal view returns (uint256 wad) {
        // we don't call drip as in the original code, only chi, since we're in a view function
        // but we emulate it by calling the same instructions that are in the drip function
        // uint256 chi = (block.timestamp > POT.rho()) ? POT.drip() : POT.chi();
        uint256 chi = POT.chi();

        uint256 rho = POT.rho();
        if (block.timestamp > rho) {
            // tmp = rmul(rpow(dsr, now - rho, ONE), chi);
            uint256 dsr = POT.dsr();
            chi = _rmul(_rpow(dsr, block.timestamp - rho, RAY), chi);
        }
        wad = _rmul(chi, DSR_MANAGER.pieOf(usr));
    }

    /// @notice Copied from the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The first number
    /// @param y The second number
    /// @return z The result of the multiplication
    function _mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // solhint-disable-next-line reason-string, gas-custom-errors
        require(y == 0 || (z = x * y) / y == x);
    }

    /// @notice Copied from the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The first number
    /// @param y The second number
    /// @return z The result of the multiplication
    function _rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds down
        z = _mul(x, y) / RAY;
    }

    /// @notice Copied from the original DSRManager contract
    ///  https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The base number to be raised to the power of n
    /// @param n The exponent
    /// @param base The base for the fixed point math used to scale the result
    /// @return z The result of the exponentiation
    function _rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := base }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := base }
                default { z := x }
                let half := div(base, 2) // for rounding.
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "MakerDAO";
    }

    function positionLabels(bytes calldata) external pure returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "DAI Savings Rate";
        return out;
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        // Return zero for unsupported or invalid tokens (adapter convention)
        if (asset == address(0) || asset != DAI) {
            return (0, false);
        }
        return (_calculateBalance(asset, account), false); // DSR is always credit
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays (internal use uint256; cast to int256 for interface)
        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempBalances = new uint256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            uint256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempBalances[count] = balance;
                count++;
            }
        }

        // Resize to actual count (DSR is always credit)
        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempBalances[i];
            isDebt[i] = false;
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns balance-only positions for the account's DAI DSR positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by DSR and registered in NAVCalculator.
    function getAdapterPositions(address account, address assetFilter)
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

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData;
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    uint256 balance = _calculateBalance(assetFilter, account);
                    if (balance != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: balance, isDebt: false});
                    } else {
                        assetBalanceData = new AssetBalanceData[](0);
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                uint256 balance = _calculateBalance(registeredSupportedAssets[i], account);
                if (balance != 0) {
                    tempData[count] =
                        AssetBalanceData({asset: registeredSupportedAssets[i], amount: balance, isDebt: false});
                    count++;
                }
            }

            // Resize to actual count
            assetBalanceData = new AssetBalanceData[](count);
            for (uint256 i = 0; i < count; i++) {
                assetBalanceData[i] = tempData[i];
            }
        }
        positions = _buildPositions(assetBalanceData);
    }

    //
    // Internal Functions - Asset Registry & Lookup
    //

    /// @notice Gets asset information from NAVCalculator by iterating through registered assets
    /// @param asset The asset address to look up
    /// @return assetInfo The Asset struct containing asset address, symbol, and decimals
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory assetInfo) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return reg[i];
            }
        }
        revert("Asset not found in NAVCalculator");
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this adapter
    /// @param assetBalanceData Array of AssetBalanceData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this adapter
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets are guaranteed to be registered (filtered in getAdapterPositions).
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            address asset = assetBalanceData[i].asset;

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

            // Build position (balance-only, pricing will be added by NAVCalculator)
            tempPositions[positionCount] = INAVCalculator.PositionBalance({
                balanceAsset: underlyingAsset,
                balanceAdapter: address(this),
                amount: assetBalanceData[i].amount,
                isDebt: assetBalanceData[i].isDebt,
                protocolId: PROTOCOL_ID,
                positionId: "",
                positionKind: PositionKind.Supplied
            });

            positionCount++;
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}

interface DsrManager {
    /// @notice from the original DsrManager contract
    /// @return The pot value
    function pot() external view returns (PotLike);

    /// @notice from the original DsrManager contract
    /// @param account The address of the account
    /// @return The pie value
    function pieOf(address account) external view returns (uint256);
}

interface PotLike {
    /// @notice The dai saving rate
    /// @return The dsr value
    function dsr() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The chi value
    function chi() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The rho value
    function rho() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The drip value
    function drip() external returns (uint256);

    /// @notice from the original Pot contract
    /// @param a The number of DAI to join
    function join(uint256 a) external;

    /// @notice from the original Pot contract
    /// @param a The address to transfer the balance to
    function exit(uint256 a) external;
}
