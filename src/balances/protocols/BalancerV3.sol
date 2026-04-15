// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InvalidArguments} from "src/errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

// solhint-disable func-name-mixedcase

/// @title Balancerv3 Balance Oracle
/// @notice Oracle contract for retrieving token balances from Balancer V3 pools and gauges
/// @dev Supports both direct pool tokens and staked gauge positions
contract BalancerV3PoolBalanceOracle is IBalanceOracleAdapter {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using Math for uint256;

    /// @notice Definition of week in https://etherscan.io/token/0x9fdd52efeb601e4bc78b89c6490505b8ac637e9f#code
    uint256 public constant WEEK = 7 * 86_400;

    //
    // Type Definitions
    //

    /// @notice Asset balance data structure
    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    /// @notice Balancer V3 Pool contract
    IStablePool public immutable POOL;

    /// @notice Balancer V3 Gauge contract for staking pool tokens
    IGaugeV3 public immutable GAUGE;

    /// @notice Balancer Minter contract that mints the BAL token
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Initializes the oracle with pool and gauge addresses
    /// @param pool_ Address of the Balancer V3 pool
    /// @param gauge_ Address of the corresponding gauge contract
    /// @param balancerMinter_ Address of the Balancer Minter contract
    /// @param protocol_ Protocol identifier (e.g., "Balancer v3").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    /// @dev Validates that the gauge's LP token matches the pool address
    constructor(
        address pool_,
        address gauge_,
        address balancerMinter_,
        string memory protocol_,
        address navCalculator_
    ) {
        if (pool_ == address(0) || gauge_ == address(0)) {
            revert InvalidArguments();
        }
        require(pool_.code.length > 0, "Pool must be a contract");
        require(gauge_.code.length > 0, "Gauge must be a contract");
        require(balancerMinter_.code.length > 0, "BalancerMinter must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        POOL = IStablePool(pool_);
        GAUGE = IGaugeV3(gauge_);
        BALANCER_MINTER = IBalancerMinter(balancerMinter_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        try GAUGE.lp_token() returns (address lpToken) {
            if (lpToken != pool_) {
                revert InvalidArguments();
            }
        } catch {
            revert InvalidArguments();
        }

        _protocol = protocol_;
    }

    /// @notice Calculates a user's token balance in the pool
    /// @param userBalance User's pool token balance
    /// @param token Address of the token to query
    /// @return User's balance of the specified token in the pool
    /// @dev Handles both direct tokens and ERC4626 vault tokens
    // solhint-disable-next-line function-max-lines
    function poolBalanceOf(uint256 userBalance, address token) public view returns (int256) {
        uint256 totalSupply = POOL.totalSupply();

        if (totalSupply == 0 || userBalance == 0) {
            return 0;
        }

        // Get pool data
        IStablePool.StablePoolDynamicData memory poolData = POOL.getStablePoolDynamicData();
        IStablePool.StablePoolImmutableData memory immutableData = POOL.getStablePoolImmutableData();

        // Find token index
        uint256 tokenIndex;
        bool found = false;
        bool erc4626 = false;

        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            address currentToken = address(immutableData.tokens[i]);

            // Check if token matches directly
            if (currentToken == token) {
                tokenIndex = i;
                found = true;
                break;
            }

            // Check if token is underlying asset of an ERC4626 vault
            try IERC4626(currentToken).asset() returns (address underlyingToken) {
                if (underlyingToken == token) {
                    tokenIndex = i;
                    found = true;
                    erc4626 = true;
                    break;
                }
            } // solhint-disable-next-line no-empty-blocks
                catch {}
        }

        if (!found) return 0;

        // Get user's token balance using live scaled balance
        //https://github.com/balancer/balancer-v3-monorepo/blob/0d2de793ea4da7b0750f56ea01c8ea9788801f64/pkg/vault/contracts/BasePoolMath.sol#L87
        uint256 tokenBalance = poolData.balancesLiveScaled18[tokenIndex] * userBalance / totalSupply;

        if (erc4626) {
            // If the token is an ERC4626 vault we need to emulate the process of redeeming from the vault

            // Go to wrapped token again
            // tokenBalance.toRawUndoRateRoundDown(scalingFactor , tokenRate)
            // FixedPoint.divDown(amount, scalingFactor * tokenRate)
            //https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/solidity-utils/contracts/helpers/ScalingHelpers.sol#L74
            //https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/solidity-utils/contracts/math/FixedPoint.sol#L38
            uint256 shares = (tokenBalance * 1e18)
                / (immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]);

            // transform wrapped token to underlying again
            //https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/vault/contracts/Vault.sol#L1327
            tokenBalance = IERC4626(address(immutableData.tokens[tokenIndex])).previewRedeem(shares);
        } else {
            // Convert from live scaled balance back to raw token units
            // tokenBalance.toRawUndoRateRoundDown(scalingFactor , tokenRate)
            // FixedPoint.divDown(amount, scalingFactor * tokenRate)
            // https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/solidity-utils/contracts/helpers/ScalingHelpers.sol#L74
            // https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/solidity-utils/contracts/math/FixedPoint.sol#L38
            tokenBalance = (tokenBalance * 1e18)
                / (immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]);
        }

        return tokenBalance.toInt256();
    }

    /// @notice Gets the claimable reward balance for a user from the gauge
    /// @param account Address of the user
    /// @param token Address of the reward token
    /// @return Amount of claimable reward tokens
    /// @dev Returns 0 if the token is not a reward token or if the call fails
    function gaugeRewards(address account, address token) public view returns (int256) {
        try GAUGE.claimable_reward(account, token) returns (uint256 claimableReward) {
            return claimableReward.toInt256();
        } catch {
            return 0;
        }
    }

    /// @notice Gets the claimable BAL token for a user in the gauge
    /// @dev This function emulates the `claimable_tokens` function from the gauge contract
    /// but with no state changes, by emulating the checkpoint call that updates the integrateFraction state variable.
    /// Mainnet gauges use inflation_rate() function, while L2 gauges use inflation_rate(week) mapping.
    /// We try mainnet calculation first, then fall back to L2 calculation if that fails.
    /// @param token Address of the reward token
    /// @param account Address of the user
    /// @return Amount of claimable BAL tokens
    function claimableTokens(address token, address account) public view returns (int256) {
        if (token == BALANCER_MINTER.getBalancerToken()) {
            // Try mainnet calculation first
            try this.calculateIntegrateFraction(account, GAUGE) returns (uint256 integrateFraction) {
                uint256 minted = BALANCER_MINTER.minted(account, address(GAUGE));
                return (integrateFraction - minted).toInt256();
            } catch {
                // If mainnet calculation fails (e.g., on L2s like Arbitrum), try L2 calculation
                try this.calculateIntegrateFractionL2(account, GAUGE) returns (uint256 integrateFraction) {
                    uint256 minted = BALANCER_MINTER.minted(account, address(GAUGE));
                    return (integrateFraction - minted).toInt256();
                } catch {
                    // If both fail, return 0
                    return 0;
                }
            }
        }

        return 0;
    }

    /// @notice Calculates the BAL checkpoint for a given user and gauge
    /// This function emulates the `_checkpoint` function from the gauge contract
    /// but with no state changes , by not updating the state variables.
    /// We only use the snippet of code that updates the `self.integrate_fraction[addr]` state variable for our user.
    /// https://etherscan.io/token/0x9fdd52efeb601e4bc78b89c6490505b8ac637e9f#code line 204
    /// @param user Address of the user
    /// @param gauge The gauge address
    /// @return The new checkpoint
    function calculateIntegrateFraction(address user, IGaugeV3 gauge) public view returns (uint256) {
        uint256 period = gauge.period().toUint256();
        uint128 period128 = period.toUint128();
        uint256 periodTime = gauge.period_timestamp(uint256(period128));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(period128));
        uint256 rate = gauge.inflation_rate();
        uint256 prevFutureEpoch = gauge.future_epoch_time();
        uint256 newRate = rate;

        if (prevFutureEpoch >= periodTime) {
            // pull updated rate & future epoch
            ITokenAdmin tokenAdmin = ITokenAdmin(BALANCER_MINTER.getBalancerTokenAdmin());
            newRate = tokenAdmin.rate();
        }

        if (gauge.is_killed()) {
            rate = 0;
            newRate = 0;
        }

        if (block.timestamp > periodTime) {
            uint256 ws = gauge.working_supply();
            uint256 prevWeek = periodTime;
            // Intentional: round down to nearest week boundary (divide before multiply is correct here)
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 weekTime = ((periodTime + WEEK) / WEEK) * WEEK;
            if (weekTime > block.timestamp) weekTime = block.timestamp;

            for (uint256 i = 0; i < 500; i++) {
                uint256 dt = weekTime - prevWeek;
                // Intentional: round down to nearest week boundary (divide before multiply is correct here)
                // forge-lint: disable-next-line(divide-before-multiply)
                uint256 w = gauge.getCappedRelativeWeight((prevWeek / WEEK) * WEEK);

                if (ws > 0) {
                    if (prevFutureEpoch >= prevWeek && prevFutureEpoch < weekTime) {
                        integrateInvSup += rate * w * (prevFutureEpoch - prevWeek) / ws;
                        rate = newRate;
                        integrateInvSup += rate * w * (weekTime - prevFutureEpoch) / ws;
                    } else {
                        integrateInvSup += rate * w * dt / ws;
                    }
                }

                if (weekTime == block.timestamp) break;
                prevWeek = weekTime;
                weekTime = prevWeek + WEEK;
                if (weekTime > block.timestamp) weekTime = block.timestamp;
            }
        }
        // compute final user fraction
        uint256 balFrac = gauge.integrate_fraction(user);
        uint256 balInvPrev = gauge.integrate_inv_supply_of(user);
        uint256 wb = gauge.working_balances(user);

        return balFrac + (wb * (integrateInvSup - balInvPrev)) / 1e18;
    }

    /// @notice Calculates the BAL checkpoint for L2 gauges (Arbitrum, Optimism, etc.)
    /// @dev L2 gauges use a simpler inflation model:
    /// - inflation_rate is a mapping indexed by week number, not a function
    /// - No gauge weights (no getCappedRelativeWeight calls)
    /// - No epoch crossing logic
    /// - Inflation rate is set per week based on BAL token transfers to the gauge
    /// @param user Address of the user
    /// @param gauge The gauge address
    /// @return The new checkpoint
    function calculateIntegrateFractionL2(address user, IGaugeV3 gauge) public view returns (uint256) {
        uint256 period = gauge.period().toUint256();
        uint128 period128 = period.toUint128();
        uint256 periodTime = gauge.period_timestamp(uint256(period128));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(period128));

        // L2 gauges skip accumulation if killed
        if (block.timestamp > periodTime && !gauge.is_killed()) {
            uint256 ws = gauge.working_supply();
            uint256 prevWeek = periodTime;
            // Intentional: round down to nearest week boundary (divide before multiply is correct here)
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 weekTime = ((periodTime + WEEK) / WEEK) * WEEK;
            if (weekTime > block.timestamp) weekTime = block.timestamp;

            for (uint256 i = 0; i < 256; i++) {
                uint256 dt = weekTime - prevWeek;

                if (ws != 0) {
                    // L2 uses inflation_rate mapping indexed by week number
                    // Intentional: round down to nearest week boundary (divide before multiply is correct here)
                    // forge-lint: disable-next-line(divide-before-multiply)
                    uint256 weekNumber = prevWeek / WEEK;
                    uint256 rate = gauge.inflation_rate(weekNumber);
                    integrateInvSup += rate * 1e18 * dt / ws;
                }

                if (weekTime == block.timestamp) break;
                prevWeek = weekTime;
                weekTime = prevWeek + WEEK;
                if (weekTime > block.timestamp) weekTime = block.timestamp;
            }
        }

        // Compute final user fraction
        uint256 balFrac = gauge.integrate_fraction(user);
        uint256 balInvPrev = gauge.integrate_inv_supply_of(user);
        uint256 wb = gauge.working_balances(user);

        return balFrac + (wb * (integrateInvSup - balInvPrev)) / 1e18;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _underlyingAssetsSupported();
    }

    /// @notice Internal helper to list all underlying assets supported by the Balancer V3 pool.
    /// @dev Includes pool underlying tokens, gauge reward tokens, and the BAL token from the minter.
    /// @return assets Array of supported underlying asset addresses.
    function _underlyingAssetsSupported() internal view returns (address[] memory assets) {
        address[] memory poolTokens = _getPoolTokens();
        address[] memory rewardTokens = _getRewardTokens();
        address balToken = BALANCER_MINTER.getBalancerToken();

        uint256 totalLen = poolTokens.length + rewardTokens.length + 1;
        address[] memory temp = new address[](totalLen);
        uint256 count = 0;

        // Add pool tokens
        for (uint256 i = 0; i < poolTokens.length; i++) {
            temp[count++] = poolTokens[i];
        }

        // Add unique reward tokens
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (!_isDuplicate(temp, count, rewardTokens[i])) {
                temp[count++] = rewardTokens[i];
            }
        }

        // Add BAL token if not duplicate
        if (!_isDuplicate(temp, count, balToken)) {
            temp[count++] = balToken;
        }

        // Trim and return
        assets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = temp[i];
        }
    }

    /// @notice Gets pool tokens, unwrapping ERC4626 tokens to their underlying assets
    /// @return Pool token addresses (underlying where token is ERC4626 vault)
    function _getPoolTokens() internal view returns (address[] memory) {
        IStablePool.StablePoolImmutableData memory immutableData = POOL.getStablePoolImmutableData();
        address[] memory tokens = new address[](immutableData.tokens.length);

        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            address currentToken = address(immutableData.tokens[i]);

            (bool success, bytes memory data) = currentToken.staticcall(abi.encodeWithSelector(IERC4626.asset.selector));

            if (success && data.length >= 32) {
                tokens[i] = abi.decode(data, (address));
            } else {
                tokens[i] = currentToken;
            }
        }
        return tokens;
    }

    /// @notice Gets reward tokens from the gauge
    /// @return Reward token addresses
    function _getRewardTokens() internal view returns (address[] memory) {
        (bool success, bytes memory data) =
            address(GAUGE).staticcall(abi.encodeWithSelector(IGaugeV3.reward_count.selector));

        if (!success || data.length < 32) {
            return new address[](0);
        }

        uint256 rewardCount = abi.decode(data, (uint256));
        address[] memory temp = new address[](rewardCount);
        uint256 count = 0;

        for (uint256 i = 0; i < rewardCount; i++) {
            (bool tokenSuccess, bytes memory tokenData) =
                address(GAUGE).staticcall(abi.encodeWithSelector(IGaugeV3.reward_tokens.selector, i));

            if (tokenSuccess && tokenData.length >= 32) {
                address rewardToken = abi.decode(tokenData, (address));
                if (rewardToken != address(0)) {
                    temp[count++] = rewardToken;
                }
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Returns true if token is already in the array within the given length
    function _isDuplicate(address[] memory arr, uint256 len, address token) internal pure returns (bool) {
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == token) return true;
        }
        return false;
    }

    /// @notice Implementation of IERC165 interface detection
    /// @param interfaceId The interface id to check
    /// @return True if this contract implements the interface
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) {
            return (0, false);
        }
        try this.underlyingAssetsSupported() returns (address[] memory supported) {
            bool isSupported = false;
            for (uint256 i = 0; i < supported.length; i++) {
                if (supported[i] == asset) {
                    isSupported = true;
                    break;
                }
            }
            if (!isSupported) {
                return (0, false);
            }
        } catch {
            return (0, false);
        }
        return _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address assetAddr = supportedAssets[i];
            (uint256 amount, bool isDebt_) = _calculateBalance(assetAddr, account);
            if (amount != 0) {
                tempAssets[count] = assetAddr;
                tempAmounts[count] = amount;
                tempIsDebt[count] = isDebt_;
                count++;
            }
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
    // Internal Functions - Balance Calculation
    //

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return amount Balance magnitude (non-negative)
    /// @return isDebt True if debt, false if credit
    function _calculateBalance(address underlyingAsset, address account)
        internal
        view
        returns (uint256 amount, bool isDebt)
    {
        uint256 userBalance = POOL.balanceOf(account);
        // Gauge token to lp token is 1 to 1
        uint256 userGaugeBalance = GAUGE.balanceOf(account);

        // We need to do a single conversion of the user balance and gauge token balance because on redeem we are
        // deducted 1 wei share and 1 wei
        // underlying
        // If we do two conversions the value will be less then the one if we unstake the gauge position and redeem the
        // lp token
        // https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/vault/contracts/Vault.sol#L1327
        int256 balance = poolBalanceOf(userBalance + userGaugeBalance, underlyingAsset)
            + gaugeRewards(account, underlyingAsset) + claimableTokens(underlyingAsset, account);
        if (balance < 0) {
            return (SafeCast.toUint256(-balance), true);
        }
        if (balance > 0) {
            return (SafeCast.toUint256(balance), false);
        }
        return (0, false);
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets are guaranteed to be registered (filtered in getOraclePositions).
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
                underlyingAsset: underlyingAsset,
                balanceOracle: address(this),
                amount: assetBalanceData[i].amount,
                isDebt: assetBalanceData[i].isDebt,
                protocol: _protocol,
                positionDetail: underlyingAsset.symbol
            });

            positionCount++;
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Balancer V3 positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by Balancer and registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }
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
            assetBalanceData = new AssetBalanceData[](0);
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    (uint256 amount, bool isDebt) = _calculateBalance(assetFilter, account);
                    if (amount != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: amount, isDebt: isDebt});
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                (uint256 amount, bool isDebt) = _calculateBalance(registeredSupportedAssets[i], account);
                if (amount != 0) {
                    tempData[count] =
                        AssetBalanceData({asset: registeredSupportedAssets[i], amount: amount, isDebt: isDebt});
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
}

/// @title Balancer V3 Gauge Interface
/// @notice Interface for interacting with Balancer V3 liquidity gauges
interface IGaugeV3 is IERC20 {
    /// @notice Returns the address of the LP token that can be staked in this gauge
    /// @return The address of the LP token
    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address);

    /// @notice Returns the amount of reward tokens claimable by a user
    /// @param user Address of the user to check rewards for
    /// @param token Address of the reward token to check
    /// @return The amount of reward tokens claimable
    // forge-lint: disable-next-line(mixed-case-function)
    function claimable_reward(address user, address token) external view returns (uint256);

    /// @notice # ∫(balance * rate(t) / totalSupply(t) dt) from 0 till checkpoint
    /// Units: rate * t = already number of coins per address to issue
    /// @param user Address of the user to check
    /// @return The amount of reward tokens claimable
    // forge-lint: disable-next-line(mixed-case-function)
    function integrate_fraction(address user) external view returns (uint256);
    /// @notice  The goal is to be able to calculate ∫(rate * balance / totalSupply dt) from 0 till checkpoint
    /// All values are kept in units of being multiplied by 1e18
    /// @return value ∫(rate * balance / totalSupply dt) from 0 till checkpoint
    function period() external view returns (int128);
    /// @notice The timestamp of the period
    /// @param period The period to get timestamp for
    /// @return Returns the timestamp of the period
    // forge-lint: disable-next-line(mixed-case-function)
    function period_timestamp(uint256 period) external view returns (uint256);
    /// @notice Calculates the integrate inverse supply
    /// @param period The period to calculate for
    /// @return 1e18 * ∫(rate(t) / totalSupply(t) dt) from 0 till checkpoint
    // forge-lint: disable-next-line(mixed-case-function)
    function integrate_inv_supply(uint256 period) external view returns (uint256);
    /// @notice Get the locally stored BAL inflation rate
    /// @return self.inflation_params % 2 ** 216
    // forge-lint: disable-next-line(mixed-case-function)
    function inflation_rate() external view returns (uint256);
    /// @notice Returns the inflation rate for a specific week (L2 gauges only)
    /// @param week Week number to get inflation rate for
    /// @return The inflation rate for that week
    // forge-lint: disable-next-line(mixed-case-function)
    function inflation_rate(uint256 week) external view returns (uint256);
    /// @notice Get if the gauge is killed
    /// @return True if the gauge is killed
    // forge-lint: disable-next-line(mixed-case-function)
    function is_killed() external view returns (bool);
    /// @notice the current working supply
    /// @return The current working supply
    // forge-lint: disable-next-line(mixed-case-function)
    function working_supply() external view returns (uint256);
    /// @notice Returns the gauge's relative weight, capped to its _relative_weight_cap attribute.
    /// @param time The time to get the weight for
    /// @return min(Controller(GAUGE_CONTROLLER).gauge_relative_weight(self, period), self._relative_weight_cap)
    function getCappedRelativeWeight(uint256 time) external view returns (uint256);
    /// @notice Returns the integrate of the inverse supply for a user
    /// @param user The user to get the integrate for
    /// @return 1e18 * ∫(rate(t) / totalSupply(t) dt) from (last_action) till checkpoint
    // forge-lint: disable-next-line(mixed-case-function)
    function integrate_inv_supply_of(address user) external view returns (uint256);
    /// @notice Returns the working balance of a user
    /// @param user The user to get the working balance for
    /// @return The working balance of the user
    // forge-lint: disable-next-line(mixed-case-function)
    function working_balances(address user) external view returns (uint256);
    /// @notice Returns the future epoch time
    /// @return The future epoch time
    // forge-lint: disable-next-line(mixed-case-function)
    function future_epoch_time() external view returns (uint256);
    /// @notice Returns the number of reward tokens on the gauge
    /// @return The number of reward tokens
    // forge-lint: disable-next-line(mixed-case-function)
    function reward_count() external view returns (uint256);
    /// @notice Returns the reward token at the given index
    /// @param i Index of the reward token
    /// @return Address of the reward token
    // forge-lint: disable-next-line(mixed-case-function)
    function reward_tokens(uint256 i) external view returns (address);
}

/// @notice General interface for token exchange rates.

///
interface IRateProvider {
    /// @notice An 18 decimal fixed point number representing the exchange rate of one token to another related token.
    /// @dev The meaning of this rate depends on the context. Note that there may be an error associated with a token
    /// rate, and the caller might require a certain rounding direction to ensure correctness. This (legacy) interface
    /// does not take a rounding direction or return an error, so great care must be taken when interpreting and using
    /// rates in downstream computations.
    /// @return rate The current token rate
    function getRate() external view returns (uint256 rate);
}

/// @title Balancer V3 Stable Pool Interface
/// @notice Interface for interacting with Balancer V3 stable pools
interface IStablePool is IERC20 {
    /// @notice Dynamic data structure for stable pool state
    /// @dev Contains current pool state that can change over time
    /// @param balancesLiveScaled18 Current balances scaled to 18 decimals
    /// @param tokenRates Current rates for each token
    /// @param staticSwapFeePercentage The static swap fee percentage
    /// @param totalSupply Total supply of pool tokens
    /// @param bptRate Current BPT rate
    /// @param amplificationParameter Current amplification parameter
    /// @param startValue Start value for parameter updates
    /// @param endValue End value for parameter updates
    /// @param startTime Start time for parameter updates
    /// @param endTime End time for parameter updates
    /// @param isAmpUpdating Whether amplification is being updated
    /// @param isPoolInitialized Whether pool is initialized
    /// @param isPoolPaused Whether pool is paused
    /// @param isPoolInRecoveryMode Whether pool is in recovery mode
    struct StablePoolDynamicData {
        uint256[] balancesLiveScaled18;
        uint256[] tokenRates;
        uint256 staticSwapFeePercentage;
        uint256 totalSupply;
        uint256 bptRate;
        uint256 amplificationParameter;
        uint256 startValue;
        uint256 endValue;
        uint32 startTime;
        uint32 endTime;
        bool isAmpUpdating;
        bool isPoolInitialized;
        bool isPoolPaused;
        bool isPoolInRecoveryMode;
    }

    /// @notice Immutable data structure for stable pool configuration
    /// @dev Contains pool configuration that cannot change after deployment
    /// @param tokens Array of tokens in the pool
    /// @param decimalScalingFactors Scaling factors for token decimals
    /// @param amplificationParameterPrecision Precision for amplification parameter
    struct StablePoolImmutableData {
        IERC20[] tokens;
        uint256[] decimalScalingFactors;
        uint256 amplificationParameterPrecision;
    }

    /// @notice Returns the current dynamic state of the pool
    /// @return Current pool state including balances, rates, and configuration
    function getStablePoolDynamicData() external view returns (StablePoolDynamicData memory);

    /// @notice Returns the immutable configuration of the pool
    /// @return Pool configuration including tokens and scaling factors
    function getStablePoolImmutableData() external view returns (StablePoolImmutableData memory);

    /// @notice Enum defining token types in the pool
    enum TokenType {
        STANDARD,
        WITH_RATE
    }

    /// @notice Structure containing token information
    /// @param tokenType Type of the token (standard or with rate)
    /// @param rateProvider Provider for token exchange rates
    /// @param paysYieldFees Whether token pays yield fees
    struct TokenInfo {
        TokenType tokenType;
        IRateProvider rateProvider;
        bool paysYieldFees;
    }

    /// @notice Returns detailed token information for the pool
    /// @return tokens Array of tokens in the pool
    /// @return tokenInfo Array of token information
    /// @return balancesRaw Raw token balances
    /// @return lastBalancesLiveScaled18 Last live scaled balances
    function getTokenInfo()
        external
        view
        returns (
            IERC20[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
}

/// @title Balancer Vault Interface
/// @notice Interface for interacting with Balancer Vault
interface IVault {
    /// @notice Gets current live balances for a pool
    /// @param pool Address of the pool
    /// @return Array of current live balances
    function getCurrentLiveBalances(address pool) external view returns (uint256[] memory);
}

/// @title Balancer Minter Interface
/// @notice Interface for Balancer token minting
interface IBalancerMinter {
    /// @notice Gets the Balancer token address
    /// @return Address of the Balancer token
    function getBalancerToken() external view returns (address);
    /// @notice Gets the Balancer token admin address
    /// @return Address of the Balancer token admin
    function getBalancerTokenAdmin() external view returns (address);
    /// @notice Gets the gauge controller address
    /// @return Address of the gauge controller
    function getGaugeController() external view returns (address);
    /// @notice Gets the amount of tokens minted for a user in a gauge
    /// @param user Address of the user
    /// @param gauge Address of the gauge
    /// @return Amount of tokens minted
    function minted(address user, address gauge) external view returns (uint256);
}

/// @title Token Admin Interface
/// @notice Interface for token administration
interface ITokenAdmin {
    /// @notice Gets the current token rate
    /// @return Current token rate
    function rate() external view returns (uint256);
    /// @notice Gets the future epoch time
    /// @return Future epoch time
    // forge-lint: disable-next-line(mixed-case-function)
    function future_epoch_time_write() external view returns (uint256);
}
