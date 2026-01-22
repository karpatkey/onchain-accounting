// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {InvalidArguments} from "src/errors.sol";

/// @notice A balance oracle for the DAI token that uses the DSRManager contract to calculate the balance.
contract DaiDsrBalanceOracle is IBalanceOracleAdapter {
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
    // State
    //

    /// @notice Address of the DAI token
    address public immutable DAI;

    /// @notice Address of the DSR Manager contract.
    DsrManager public immutable DSR_MANAGER;

    /// @notice Address of the Pot contract
    PotLike public immutable POT;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @param dai_ The address of the DAI token
    /// @param dsrManager_ The address of the DSR Manager contract
    /// @param protocol_ Protocol identifier (e.g., "Maker").
    /// @param positionDetail_ Position detail identifier (e.g., "DSR").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(
        address dai_,
        address dsrManager_,
        string memory protocol_,
        string memory positionDetail_,
        address balances_
    ) {
        if (dai_ == address(0) || dsrManager_ == address(0)) revert InvalidArguments();
        DAI = dai_;
        DSR_MANAGER = DsrManager(dsrManager_);
        POT = DSR_MANAGER.pot();
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256) {
        if (underlyingAsset != DAI) {
            revert InvalidArguments();
        }
        return _daiBalance(account).toInt256();
    }

    /// @inheritdoc IBalanceOracleAdapter
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
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        // Sum all balances for this asset across all positions
        // _buildPositions with asset filter already returns only positions for this asset
        INAVCalculator.Position[] memory positions = _buildPositions(account, asset);
        for (uint256 i = 0; i < positions.length; i++) {
            balance += positions[i].balance;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        amounts = new int256[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of Position structs from this oracle
    function _buildPositions(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info from registry (if registered)
                uint8 decimals;
                string memory symbol;
                try BALANCES.getAssetDecimals(asset) returns (uint8 dec) {
                    decimals = dec;
                } catch {
                    // Asset not registered, skip it (NAVCalculator will filter anyway)
                    continue;
                }
                try BALANCES.getAssetSymbol(asset) returns (string memory sym) {
                    symbol = sym;
                } catch {
                    symbol = "";
                }

                // Build underlying asset struct
                INAVCalculator.Asset memory underlyingAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.Position({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    balance: balance,
                    quoteAsset: INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), // Will be set by NAVCalculator
                    value: 0, // Will be calculated by NAVCalculator
                    price: 0, // Will be set by NAVCalculator
                    priceDecimals: 0, // Will be set by NAVCalculator
                    stale: false, // Will be set by NAVCalculator
                    protocol: _protocol,
                    positionDetail: _positionDetail
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _buildPositions(account, assetFilter);
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
