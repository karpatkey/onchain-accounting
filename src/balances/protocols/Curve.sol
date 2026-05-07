// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title Curve Balance Oracle
/// @author kpk
/// @notice Returns pool-token and reward balances for an account's Curve LP position (unstaked + gauge-staked).
/// @dev Compatible with Stableswap pools that implement `coins(uint256)`, `balances(uint256)`, `totalSupply()`.
///      Pool type compatibility:
///        - Stableswap Custom (ID 0), Metapool Factory (ID 3), StableswapNG (ID 12) ✓
///        - Cryptoswap variants (IDs 5, 6, 11, 13) — NOT verified.
///      Bounded loop: `_MAX_ITERATIONS = 8` (all tested Stableswap types have ≤ 8 tokens).
///
/// @dev CRV Rewards Limitation:
///      `_calculateBalance` returns the CRV lower-bound estimate from integrate_fraction − minted.
///      This value is stale between checkpoints (deposit/withdraw/claim) and may return 0 for users who
///      received gauge tokens via transfer. For accurate CRV in tests/simulations use `crvClaimableAccurate()`.
///      Off-chain NAV calculations should use eth_call with `crvClaimableAccurate()` for accuracy.
///
/// @dev The LP token address is derived from `gauge.lp_token()` at construction.
contract CurveBalanceOracle is IBalanceOracleAdapter {
    using SafeCast for uint256;

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

    /// @notice Curve LP token for this pool (derived from gauge.lp_token() at construction)
    address public immutable LP_TOKEN;

    /// @notice Curve gauge where LP tokens can be staked
    address public immutable GAUGE;

    /// @notice Canonical Ethereum mainnet CRV token address
    address internal constant _CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    /// @notice Canonical Ethereum mainnet Curve Minter address
    address internal constant _CURVE_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    /// @notice Bounded iteration limit for pool coins and reward tokens
    uint256 internal constant _MAX_ITERATIONS = 8;

    /// @notice Protocol identifier for this oracle
    string private _protocol;

    /// @notice JSON metadata base (no closing `}`) for this oracle
    string private _positionDetail;

    /// @notice Stable hex identifier for this adapter instance (gauge address)
    string private _positionId;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param gauge_ The Curve gauge contract address (lp_token() is derived from it)
    /// @param protocol_ Protocol identifier (e.g., "Curve")
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (gauge address).
    /// @param navCalculator_ The NAVCalculator contract address
    constructor(
        address gauge_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) {
        if (gauge_ == address(0)) revert InvalidArguments();
        require(gauge_.code.length > 0, "Gauge must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        GAUGE = gauge_;
        address lpToken = ICurveGauge(gauge_).lp_token();
        require(lpToken != address(0), "Gauge lp_token() returned zero");
        LP_TOKEN = lpToken;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
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
    /// @dev Returns pool tokens (from coins()) + CRV + extra gauge rewards, deduplicated.
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _getAllSupportedAssets();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0)) return (0, false);
        return (_calculateBalance(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = _getAllSupportedAssets();
        AssetBalanceData[] memory tempData = new AssetBalanceData[](supportedAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            uint256 balance = _calculateBalance(account, supportedAssets[i]);
            if (balance > 0) {
                tempData[count] = AssetBalanceData({asset: supportedAssets[i], amount: balance, isDebt: false});
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempData[i].asset;
            amounts[i] = tempData[i].amount;
            isDebt[i] = tempData[i].isDebt;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev CRV reward amounts are a lower-bound estimate (see contract-level NatSpec for the limitation).
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = _getAllSupportedAssets();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        address[] memory eligibleAssets = ArrayLib.intersection(supportedAssets, registeredAssets);
        if (eligibleAssets.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Apply asset filter
        if (assetFilter != address(0)) {
            bool filterFound = false;
            for (uint256 i = 0; i < eligibleAssets.length; i++) {
                if (eligibleAssets[i] == assetFilter) {
                    filterFound = true;
                    break;
                }
            }
            if (!filterFound) return new INAVCalculator.PositionBalance[](0);

            uint256 balance = _calculateBalance(account, assetFilter);
            if (balance == 0) return new INAVCalculator.PositionBalance[](0);

            INAVCalculator.Asset memory filteredAsset = _getAssetInfo(assetFilter);
            positions = new INAVCalculator.PositionBalance[](1);
            positions[0] = INAVCalculator.PositionBalance({
                underlyingAsset: filteredAsset,
                balanceOracle: address(this),
                amount: balance,
                isDebt: false,
                protocol: _protocol,
                positionDetail: string.concat(_positionDetail, ",\"token\":\"", filteredAsset.symbol, "\"}"),
                positionId: _positionId
            });
            return positions;
        }

        // No filter — return all eligible assets with non-zero balance
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](eligibleAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < eligibleAssets.length; i++) {
            uint256 balance = _calculateBalance(account, eligibleAssets[i]);
            if (balance > 0) {
                INAVCalculator.Asset memory eligibleAsset = _getAssetInfo(eligibleAssets[i]);
                tempPositions[count] = INAVCalculator.PositionBalance({
                    underlyingAsset: eligibleAsset,
                    balanceOracle: address(this),
                    amount: balance,
                    isDebt: false,
                    protocol: _protocol,
                    positionDetail: string.concat(_positionDetail, ",\"token\":\"", eligibleAsset.symbol, "\"}"),
                    positionId: _positionId
                });
                count++;
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = tempPositions[i];
        }
    }

    //
    // Public helpers (for testing and off-chain use)
    //

    /// @notice Returns accurate CRV rewards via checkpointing (non-view — use off-chain/in tests).
    /// @dev Calls gauge.claimable_tokens() which updates integrate_fraction then returns the accurate amount.
    ///      Cannot be called from view contexts. For on-chain conservative estimates, use getCrvRewardsLowerBound.
    /// @param account The account to query
    /// @return Accurate CRV reward balance after checkpointing
    function crvClaimableAccurate(address account) external returns (uint256) {
        return ICurveGauge(GAUGE).claimable_tokens(account);
    }

    /// @notice Returns the CRV lower-bound estimate (view-safe, may be stale or 0 before checkpoint).
    /// @param account The account to query
    /// @return CRV reward lower bound (integrate_fraction − minted)
    function getCrvRewardsLowerBound(address account) external view returns (uint256) {
        int256 lb = _getCrvRewardsLowerBound(account);
        // forge-lint: disable-next-line(unsafe-typecast)
        return lb > 0 ? uint256(lb) : 0;
    }

    //
    // Internal Helpers
    //

    /// @notice Computes total balance for a given asset across: pool position + CRV reward + extra rewards.
    /// @dev Pool: (LP unstaked + LP staked) × (poolBalance / totalSupply)
    ///      CRV: lower bound = integrate_fraction − minted (may be 0 or underestimated — see NatSpec)
    ///      Extra: gauge.claimable_reward(account, asset)
    function _calculateBalance(address account, address asset) internal view returns (uint256) {
        uint256 balance = _getPoolTokenBalance(account, asset);

        if (asset == _CRV_TOKEN) {
            // CRV: lower bound only (see contract-level limitation note)
            int256 crvLb = _getCrvRewardsLowerBound(account);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (crvLb > 0) balance += uint256(crvLb);
        }

        balance += _getExtraRewardBalance(account, asset);

        return balance;
    }

    /// @notice Gets the account's proportional pool-token balance (unstaked LP + staked LP).
    function _getPoolTokenBalance(address account, address token) internal view returns (uint256) {
        (bool supplySuccess, uint256 totalSupply) =
            _safeCallUint(LP_TOKEN, abi.encodeCall(ICurveLPToken.totalSupply, ()));
        if (!supplySuccess || totalSupply == 0) return 0;

        (bool unstakedSuccess, uint256 unstakedLp) =
            _safeCallUint(LP_TOKEN, abi.encodeCall(ICurveLPToken.balanceOf, (account)));
        (bool stakedSuccess, uint256 stakedLp) = _safeCallUint(GAUGE, abi.encodeCall(ICurveGauge.balanceOf, (account)));

        uint256 totalLp = (unstakedSuccess ? unstakedLp : 0) + (stakedSuccess ? stakedLp : 0);
        if (totalLp == 0) return 0;

        // Find token in pool and compute proportional share
        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            (bool coinSuccess, address poolToken) = _safeCallAddress(LP_TOKEN, abi.encodeCall(ICurveLPToken.coins, (i)));
            if (!coinSuccess) break;

            if (poolToken == token) {
                (bool balSuccess, uint256 poolBalance) =
                    _safeCallUint(LP_TOKEN, abi.encodeCall(ICurveLPToken.balances, (i)));
                if (!balSuccess) return 0;
                return (poolBalance * totalLp) / totalSupply;
            }
        }
        return 0;
    }

    /// @notice Computes the CRV lower-bound: integrate_fraction(account) - minter.minted(account, gauge).
    function _getCrvRewardsLowerBound(address account) internal view returns (int256) {
        (bool okIf, uint256 integrateFraction) =
            _safeCallUint(GAUGE, abi.encodeWithSignature("integrate_fraction(address)", account));
        if (!okIf) return 0;

        (bool okMinted, uint256 alreadyMinted) =
            _safeCallUint(_CURVE_MINTER, abi.encodeWithSignature("minted(address,address)", account, GAUGE));
        if (!okMinted) return 0;

        if (integrateFraction > alreadyMinted) {
            return (integrateFraction - alreadyMinted).toInt256();
        }
        return 0;
    }

    /// @notice Gets balance for extra gauge reward tokens via claimable_reward().
    function _getExtraRewardBalance(address account, address token) internal view returns (uint256) {
        (bool countSuccess, uint256 rewardCount) = _safeCallUint(GAUGE, abi.encodeCall(ICurveGauge.reward_count, ()));

        uint256 maxIter = _MAX_ITERATIONS;
        if (countSuccess && rewardCount < maxIter) maxIter = rewardCount;

        for (uint256 i = 0; i < maxIter; i++) {
            (bool tokenSuccess, address rewardToken) =
                _safeCallAddress(GAUGE, abi.encodeCall(ICurveGauge.reward_tokens, (i)));
            if (!tokenSuccess || rewardToken == address(0)) break;

            if (rewardToken == token) {
                (bool claimableSuccess, uint256 claimable) =
                    _safeCallUint(GAUGE, abi.encodeCall(ICurveGauge.claimable_reward, (account, token)));
                return claimableSuccess ? claimable : 0;
            }
        }
        return 0;
    }

    /// @notice Returns all pool tokens discovered via coins() loop.
    function _getPoolTokens() internal view returns (address[] memory) {
        address[] memory temp = new address[](_MAX_ITERATIONS);
        uint256 count = 0;
        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            (bool success, address token) = _safeCallAddress(LP_TOKEN, abi.encodeCall(ICurveLPToken.coins, (i)));
            if (!success) break;
            temp[count] = token;
            count++;
        }
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Returns CRV + extra reward tokens, deduplicated.
    function _getRewardTokens() internal view returns (address[] memory) {
        address[] memory temp = new address[](_MAX_ITERATIONS + 1);
        uint256 count = 0;

        // CRV is always first
        temp[count] = _CRV_TOKEN;
        count++;

        (bool countSuccess, uint256 rewardCount) = _safeCallUint(GAUGE, abi.encodeCall(ICurveGauge.reward_count, ()));

        uint256 maxIter = _MAX_ITERATIONS;
        if (countSuccess && rewardCount < maxIter) maxIter = rewardCount;

        for (uint256 i = 0; i < maxIter; i++) {
            (bool success, address token) = _safeCallAddress(GAUGE, abi.encodeCall(ICurveGauge.reward_tokens, (i)));
            if (!success || token == address(0)) break;
            if (token == _CRV_TOKEN) continue; // already included

            bool isDuplicate = false;
            for (uint256 j = 1; j < count; j++) {
                if (temp[j] == token) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                temp[count] = token;
                count++;
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Returns pool tokens + reward tokens deduplicated into a single array.
    function _getAllSupportedAssets() internal view returns (address[] memory) {
        address[] memory poolTokens = _getPoolTokens();
        address[] memory rewardTokens = _getRewardTokens();

        address[] memory temp = new address[](poolTokens.length + rewardTokens.length);
        uint256 count = 0;

        for (uint256 i = 0; i < poolTokens.length; i++) {
            temp[count] = poolTokens[i];
            count++;
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == rewardTokens[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                temp[count] = rewardTokens[i];
                count++;
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Safely calls a function that returns uint256.
    function _safeCallUint(address target, bytes memory data) internal view returns (bool success, uint256 result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (uint256));
        }
    }

    /// @notice Safely calls a function that returns address.
    function _safeCallAddress(address target, bytes memory data) internal view returns (bool success, address result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (address));
        }
    }
}

// ---------------------------
// Interface Section
// ---------------------------

/// @notice Minimal Curve LP token interface (Stableswap pool)
interface ICurveLPToken {
    function coins(uint256 index) external view returns (address);
    function balances(uint256 index) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal Curve gauge interface (LiquidityGaugeV4/V5/V6)
interface ICurveGauge {
    // solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function integrate_fraction(address account) external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function claimable_tokens(address addr) external returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function reward_tokens(uint256 arg0) external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function reward_count() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function claimable_reward(address user, address rewardToken) external view returns (uint256);
}

/// @notice Minimal Curve Minter interface
interface ICurveMinter {
    function minted(address user, address gauge) external view returns (uint256);
}
