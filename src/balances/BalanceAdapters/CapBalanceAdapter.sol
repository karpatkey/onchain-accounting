// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

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

/// @title Cap Protocol Balance Adapter
/// @author KPK
/// @notice Returns the USDC-equivalent balances for an account's Cap positions, as two structurally distinct
///         legs: the base synthetic dollar (cUSD) and the staked, yield-bearing savings token (stcUSD).
/// @dev Each leg is valued independently in USDC and emitted as its own `PositionBalance` (positionId =
///      `abi.encode(token)`), so a consumer can tell held cUSD apart from staked stcUSD:
///      - cUSD:   ERC20.balanceOf → `ICUsd.getBurnAmount` → USDC.            Label `["Stablecoin", "cUSD"]`.
///      - stcUSD: ERC20.balanceOf → ERC4626 `convertToAssets` → cUSD → `getBurnAmount` → USDC. `["Savings", "stcUSD"]`.
///      The aggregate balance getters (`getAdapterBalances`/`getAdapterBalanceForAsset`) still report the combined
///      USDC total for the USDC asset; only the NAV `getAdapterPositions` path splits the legs.
contract CapBalanceAdapter is BalanceAdapterBase {
    //
    // State
    //

    /// @notice Cap protocol cUSD token (ERC20 + burn-quote interface)
    ICUsd public immutable CUSD;

    /// @notice Cap protocol stcUSD token (ERC4626-like, redeems to cUSD)
    IStcUsd public immutable STCUSD;

    /// @notice The underlying asset returned by this adapter (USDC)
    address public immutable USDC;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice 3-level protocol identity for Cap (brand / id / sub-id). Cap is a single product with no
    ///         sub-protocols, so all three levels collapse to the same `ProtocolIds.CAP` slug; the cUSD vs.
    ///         stcUSD leg distinction is carried by `positionId` and `positionKind`, not by the taxonomy.
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.CAP;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.CAP;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.CAP;

    //
    // Constructor
    //

    /// @param cUsd_ The address of the Cap cUSD token
    /// @param stcUsd_ The address of the Cap stcUSD token
    /// @param usdc_ The address of USDC (the underlying asset returned)
    /// @param navCalculator_ The address of the NAVCalculator contract
    constructor(address cUsd_, address stcUsd_, address usdc_, address navCalculator_) {
        if (cUsd_ == address(0) || stcUsd_ == address(0) || usdc_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(cUsd_, "cUSD");
        AddressCheckLib.requireContract(stcUsd_, "stcUSD");
        AddressCheckLib.requireContract(usdc_, "USDC");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        CUSD = ICUsd(cUsd_);
        STCUSD = IStcUsd(stcUsd_);
        USDC = usdc_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IPositionDescribable
    //

    function protocolName() external pure returns (string memory) {
        return "Cap";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev Branches on the positionId token: `["Stablecoin", "cUSD"]` for the cUSD leg,
    ///      `["Savings", "stcUSD"]` for the staked stcUSD leg. Empty array for anything else.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        address token = abi.decode(positionId, (address));
        string[] memory out = new string[](2);
        if (token == address(STCUSD)) {
            out[0] = "Savings";
            out[1] = "stcUSD";
            return out;
        }
        if (token == address(CUSD)) {
            out[0] = "Stablecoin";
            out[1] = "cUSD";
            return out;
        }
        return new string[](0);
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        return assets;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != USDC) return (0, false);
        return (_calculateBalance(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
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

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns up to two USDC-denominated positions — the cUSD leg and the stcUSD leg — skipping any
    ///         leg with a zero balance. cUSD (held synthetic dollar) is `Supplied`; stcUSD (staked cUSD) is
    ///         `Staking`. Identity is the leg's token via positionId.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Only the USDC asset is reported; if it isn't registered (or filtered out), nothing to emit.
        (INAVCalculator.Asset memory underlyingAsset, bool found) = _getAssetInfo(USDC);
        if (!found) return new INAVCalculator.PositionBalance[](0);
        if (assetFilter != address(0) && assetFilter != USDC) {
            return new INAVCalculator.PositionBalance[](0);
        }

        uint256 cUsdUsdc = _cUsdLegUsdc(account);
        uint256 stcUsdUsdc = _stcUsdLegUsdc(account);

        uint256 n = (cUsdUsdc > 0 ? 1 : 0) + (stcUsdUsdc > 0 ? 1 : 0);
        positions = new INAVCalculator.PositionBalance[](n);
        uint256 k = 0;
        if (cUsdUsdc > 0) {
            positions[k++] = INAVCalculator.PositionBalance({
                balanceAsset: underlyingAsset,
                balanceAdapter: address(this),
                amount: cUsdUsdc,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: abi.encode(address(CUSD)),
                positionKind: PositionKind.Supplied,
                isLocked: false,
                positionInstanceId: bytes32(0)
            });
        }
        if (stcUsdUsdc > 0) {
            positions[k++] = INAVCalculator.PositionBalance({
                balanceAsset: underlyingAsset,
                balanceAdapter: address(this),
                amount: stcUsdUsdc,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: abi.encode(address(STCUSD)),
                positionKind: PositionKind.Staking,
                isLocked: false,
                positionInstanceId: bytes32(0)
            });
        }
    }

    //
    // Internal Helpers
    //

    /// @notice USDC equivalent of the account's directly-held cUSD (0 if none).
    function _cUsdLegUsdc(address account) internal view returns (uint256) {
        uint256 cUsdBalance = IERC20(address(CUSD)).balanceOf(account);
        if (cUsdBalance == 0) return 0;
        (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdBalance);
        return usdcAmount;
    }

    /// @notice USDC equivalent of the account's staked stcUSD (shares → cUSD → USDC; 0 if none).
    function _stcUsdLegUsdc(address account) internal view returns (uint256) {
        uint256 stcUsdBalance = IERC20(address(STCUSD)).balanceOf(account);
        if (stcUsdBalance == 0) return 0;
        uint256 cUsdEquiv = STCUSD.convertToAssets(stcUsdBalance);
        if (cUsdEquiv == 0) return 0;
        (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdEquiv);
        return usdcAmount;
    }

    /// @notice Combined USDC equivalent of cUSD + stcUSD; used by the no-arg balance getters.
    /// @dev Sums the SAME per-leg burn quotes as the NAV `getAdapterPositions` path (cUSD leg + stcUSD leg), so the
    ///      aggregate getter equals the per-position sum exactly — no burn-quote-rounding divergence between the two
    ///      reporting surfaces (vigilo L-01).
    function _calculateBalance(address account) internal view returns (uint256) {
        return _cUsdLegUsdc(account) + _stcUsdLegUsdc(account);
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry.
    /// @return asset The Asset struct (zeroed if not found). found True if the asset is registered.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory, bool found) {
        return RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), asset);
    }
}
