// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title Cap Protocol cUSD Interface
/// @notice Minimal interface for interacting with Cap protocol's cUSD token
interface ICUsd {
    /// @notice Get the amount of underlying asset received for burning cUSD
    /// @param asset The underlying asset address (e.g. USDC)
    /// @param amountIn The amount of cUSD to burn
    /// @return amountOut The amount of underlying asset received
    /// @return fee The protocol fee amount
    function getBurnAmount(address asset, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee);
}

/// @title Cap Protocol stcUSD Interface
/// @notice Minimal ERC4626 interface for the staked cUSD (stcUSD) token
interface IStcUsd {
    /// @notice Convert stcUSD shares to underlying cUSD assets
    /// @param shares The amount of stcUSD shares to convert
    /// @return The equivalent amount of cUSD
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title Cap Protocol Balance Oracle
/// @author kpk
/// @notice Returns the USDC-equivalent balance for an account's Cap Finance positions (cUSD + stcUSD).
/// @dev Combines cUSD and stcUSD positions into a single USDC amount:
///      1. Reads cUSD balance directly via ERC20.balanceOf
///      2. Converts stcUSD shares to cUSD via ERC4626 convertToAssets
///      3. Calls ICUsd.getBurnAmount on the combined cUSD total to get the USDC equivalent
contract CapBalanceOracle is IBalanceOracleAdapter {
    //
    // State
    //

    /// @notice Cap protocol cUSD token (ERC20 + burn-quote interface)
    ICUsd public immutable CUSD;

    /// @notice Cap protocol stcUSD token (ERC4626-like, redeems to cUSD)
    IStcUsd public immutable STCUSD;

    /// @notice The underlying asset returned by this oracle (USDC)
    address public immutable USDC;

    /// @notice Protocol identifier for this oracle
    string private _protocol;

    /// @notice Position detail identifier for this oracle
    string private _positionDetail;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param cUsd_ The address of the Cap cUSD token
    /// @param stcUsd_ The address of the Cap stcUSD token
    /// @param usdc_ The address of USDC (the underlying asset returned)
    /// @param protocol_ Protocol identifier (e.g., "Cap")
    /// @param positionDetail_ Position detail (e.g., "cUSD + stcUSD")
    /// @param navCalculator_ The address of the NAVCalculator contract
    constructor(
        address cUsd_,
        address stcUsd_,
        address usdc_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (cUsd_ == address(0) || stcUsd_ == address(0) || usdc_ == address(0)) {
            revert InvalidArguments();
        }
        require(cUsd_.code.length > 0, "cUSD must be a contract");
        require(stcUsd_.code.length > 0, "stcUSD must be a contract");
        require(usdc_.code.length > 0, "USDC must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        CUSD = ICUsd(cUsd_);
        STCUSD = IStcUsd(stcUsd_);
        USDC = usdc_;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
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
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        return assets;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != USDC) return (0, false);
        return (_calculateBalance(account), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 balance = _calculateBalance(account);

        if (balance == 0) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = USDC;
        amounts[0] = balance;
        isDebt[0] = false;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the combined cUSD + stcUSD position as a single USDC-denominated PositionBalance.
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

        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        if (registeredSupportedAssets.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // assetFilter: if set and doesn't match USDC, return empty
        if (assetFilter != address(0) && assetFilter != USDC) {
            return new INAVCalculator.PositionBalance[](0);
        }

        uint256 balance = _calculateBalance(account);
        if (balance == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(USDC);

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            underlyingAsset: underlyingAsset,
            balanceOracle: address(this),
            amount: balance,
            isDebt: false,
            protocol: _protocol,
            positionDetail: _positionDetail
        });
    }

    //
    // Internal Helpers
    //

    /// @notice Computes the USDC equivalent of the account's combined cUSD and stcUSD holdings.
    /// @dev Converts stcUSD shares → cUSD via convertToAssets, then converts total cUSD → USDC
    ///      via ICUsd.getBurnAmount. Returns 0 if the account holds no Cap positions.
    function _calculateBalance(address account) internal view returns (uint256) {
        uint256 cUsdBalance = IERC20(address(CUSD)).balanceOf(account);
        uint256 stcUsdBalance = IERC20(address(STCUSD)).balanceOf(account);

        uint256 stcUsdToCUsd = 0;
        if (stcUsdBalance > 0) {
            stcUsdToCUsd = STCUSD.convertToAssets(stcUsdBalance);
        }

        uint256 totalCUsd = cUsdBalance + stcUsdToCUsd;
        if (totalCUsd == 0) return 0;

        (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, totalCUsd);
        return usdcAmount;
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }
}
