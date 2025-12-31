// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InvalidArguments} from "src/errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// solhint-disable func-name-mixedcase

/// @title Balancerv3 Balance Oracle
/// @notice Oracle contract for retrieving token balances from Balancer V3 pools and gauges
/// @dev Supports both direct pool tokens and staked gauge positions
contract BalancerV3PoolBalanceOracle is IBalanceOracleCustom {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using Math for uint256;

    /// @notice Definition of week in https://etherscan.io/token/0x9fdd52efeb601e4bc78b89c6490505b8ac637e9f#code
    uint256 public constant WEEK = 7 * 86_400;

    /// @notice Balancer V3 Pool contract
    IStablePool public immutable POOL;

    /// @notice Balancer V3 Gauge contract for staking pool tokens
    IGaugeV3 public immutable GAUGE;

    /// @notice Balancer Minter contract that mints the BAL token
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @notice Position tags associated with the balance oracle.
    PositionMetadata internal _positionMetadata;

    /// @notice Initializes the oracle with pool and gauge addresses
    /// @param pool_ Address of the Balancer V3 pool
    /// @param gauge_ Address of the corresponding gauge contract
    /// @param balancerMinter_ Address of the Balancer Minter contract
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    /// @dev Validates that the gauge's LP token matches the pool address
    constructor(address pool_, address gauge_, address balancerMinter_, PositionMetadata memory positionMetadata_) {
        if (pool_ == address(0) || gauge_ == address(0)) {
            revert InvalidArguments();
        }

        POOL = IStablePool(pool_);
        GAUGE = IGaugeV3(gauge_);
        BALANCER_MINTER = IBalancerMinter(balancerMinter_);

        try GAUGE.lp_token() returns (address lpToken) {
            if (lpToken != pool_) {
                revert InvalidArguments();
            }
        } catch {
            revert InvalidArguments();
        }

        _positionMetadata = positionMetadata_;
    }

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address safe) external view override returns (int256) {
        uint256 userBalance = POOL.balanceOf(safe);
        // Gauge token to lp token is 1 to 1
        uint256 userGaugeBalance = GAUGE.balanceOf(safe);

        // We need to do a single conversion of the user balance and gauge token balance because on redeem we are
        // deducted 1 wei share and 1 wei
        // underlying
        // If we do two conversions the value will be less then the one if we unstake the gauge position and redeem the
        // lp token
        // https://github.com/balancer/balancer-v3-monorepo/blob/e44adf7ad77fba773af1dbdb4be30b2ce14c29e9/pkg/vault/contracts/Vault.sol#L1327
        return poolBalanceOf(userBalance + userGaugeBalance, underlyingAsset) + gaugeRewards(safe, underlyingAsset)
            + claimableTokens(underlyingAsset, safe);
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

            tokenBalance = IERC4626(address(immutableData.tokens[tokenIndex])).previewRedeem(shares - 1) - 1;
        }

        return tokenBalance.toInt256();
    }

    /// @notice Gets the claimable reward balance for a user from the gauge
    /// @param safe Address of the user
    /// @param token Address of the reward token
    /// @return Amount of claimable reward tokens
    /// @dev Returns 0 if the token is not a reward token or if the call fails
    function gaugeRewards(address safe, address token) public view returns (int256) {
        try GAUGE.claimable_reward(safe, token) returns (uint256 claimableReward) {
            return claimableReward.toInt256();
        } catch {
            return 0;
        }
    }

    /// @notice Gets the claimable BAL token for a user in the gauge
    /// This function emulates the `claimable_tokens` function from the gauge contract
    /// but with no state changes , by emulating the checkpoint call that updates the integrateFraction state variable.
    /// https://etherscan.io/token/0x9fdd52efeb601e4bc78b89c6490505b8ac637e9f#code
    /// @param token Address of the reward token
    /// @param safe Address of the user
    /// @return Amount of claimable BAL tokens
    function claimableTokens(address token, address safe) public view returns (int256) {
        if (token == BALANCER_MINTER.getBalancerToken()) {
            uint256 integrateFraction = calculateIntegrateFraction(safe, (GAUGE));
            uint256 minted = BALANCER_MINTER.minted(safe, address(GAUGE));

            return (integrateFraction - minted).toInt256();
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
        uint256 periodTime = gauge.period_timestamp(uint256(uint128(period)));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(uint128(period)));
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
            uint256 weekTime = ((periodTime + WEEK) / WEEK) * WEEK;
            if (weekTime > block.timestamp) weekTime = block.timestamp;

            for (uint256 i = 0; i < 500; i++) {
                uint256 dt = weekTime - prevWeek;
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

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = address(0); // FIXME
        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    /// @notice Implementation of IERC165 interface detection
    /// @param interfaceId The interface id to check
    /// @return True if this contract implements the interface
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title Balancer V3 Gauge Interface
/// @notice Interface for interacting with Balancer V3 liquidity gauges
interface IGaugeV3 is IERC20 {
    /// @notice Returns the address of the LP token that can be staked in this gauge
    /// @return The address of the LP token
    function lp_token() external view returns (address);

    /// @notice Returns the amount of reward tokens claimable by a user
    /// @param user Address of the user to check rewards for
    /// @param token Address of the reward token to check
    /// @return The amount of reward tokens claimable
    function claimable_reward(address user, address token) external view returns (uint256);

    /// @notice # ∫(balance * rate(t) / totalSupply(t) dt) from 0 till checkpoint
    /// Units: rate * t = already number of coins per address to issue
    /// @param user Address of the user to check
    /// @return The amount of reward tokens claimable
    function integrate_fraction(address user) external view returns (uint256);
    /// @notice  The goal is to be able to calculate ∫(rate * balance / totalSupply dt) from 0 till checkpoint
    /// All values are kept in units of being multiplied by 1e18
    /// @return value ∫(rate * balance / totalSupply dt) from 0 till checkpoint
    function period() external view returns (int128);
    /// @notice The timestamp of the period
    /// @param period The period to get timestamp for
    /// @return Returns the timestamp of the period
    function period_timestamp(uint256 period) external view returns (uint256);
    /// @notice Calculates the integrate inverse supply
    /// @param period The period to calculate for
    /// @return 1e18 * ∫(rate(t) / totalSupply(t) dt) from 0 till checkpoint
    function integrate_inv_supply(uint256 period) external view returns (uint256);
    /// @notice Get the locally stored BAL inflation rate
    /// @return self.inflation_params % 2 ** 216
    function inflation_rate() external view returns (uint256);
    /// @notice Get if the gauge is killed
    /// @return True if the gauge is killed
    function is_killed() external view returns (bool);
    /// @notice the current working supply
    /// @return The current working supply
    function working_supply() external view returns (uint256);
    /// @notice Returns the gauge's relative weight, capped to its _relative_weight_cap attribute.
    /// @param time The time to get the weight for
    /// @return min(Controller(GAUGE_CONTROLLER).gauge_relative_weight(self, period), self._relative_weight_cap)
    function getCappedRelativeWeight(uint256 time) external view returns (uint256);
    /// @notice Returns the integrate of the inverse supply for a user
    /// @param user The user to get the integrate for
    /// @return 1e18 * ∫(rate(t) / totalSupply(t) dt) from (last_action) till checkpoint
    function integrate_inv_supply_of(address user) external view returns (uint256);
    /// @notice Returns the working balance of a user
    /// @param user The user to get the working balance for
    /// @return The working balance of the user
    function working_balances(address user) external view returns (uint256);
    /// @notice Returns the future epoch time
    /// @return The future epoch time
    function future_epoch_time() external view returns (uint256);
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
    function future_epoch_time_write() external view returns (uint256);
}
