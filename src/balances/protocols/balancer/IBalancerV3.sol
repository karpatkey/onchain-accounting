// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// solhint-disable func-name-mixedcase

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
interface IRateProvider {
    /// @notice An 18 decimal fixed point number representing the exchange rate of one token to another related token.
    /// @return rate The current token rate
    function getRate() external view returns (uint256 rate);
}

/// @title Balancer V3 Stable Pool Interface
/// @notice Interface for interacting with Balancer V3 stable pools
interface IStablePool is IERC20 {
    /// @notice Dynamic data structure for stable pool state
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
    struct StablePoolImmutableData {
        IERC20[] tokens;
        uint256[] decimalScalingFactors;
        uint256 amplificationParameterPrecision;
    }

    /// @notice Returns the current dynamic state of the pool
    function getStablePoolDynamicData() external view returns (StablePoolDynamicData memory);

    /// @notice Returns the immutable configuration of the pool
    function getStablePoolImmutableData() external view returns (StablePoolImmutableData memory);

    /// @notice Enum defining token types in the pool
    enum TokenType {
        STANDARD,
        WITH_RATE
    }

    /// @notice Structure containing token information
    struct TokenInfo {
        TokenType tokenType;
        IRateProvider rateProvider;
        bool paysYieldFees;
    }

    /// @notice Returns detailed token information for the pool
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

/// @title Balancer Minter Interface
/// @notice Interface for Balancer token minting
interface IBalancerMinter {
    /// @notice Gets the Balancer token address
    function getBalancerToken() external view returns (address);
    /// @notice Gets the Balancer token admin address
    function getBalancerTokenAdmin() external view returns (address);
    /// @notice Gets the gauge controller address
    function getGaugeController() external view returns (address);
    /// @notice Gets the amount of tokens minted for a user in a gauge
    function minted(address user, address gauge) external view returns (uint256);
}

/// @title Token Admin Interface
/// @notice Interface for token administration
interface ITokenAdmin {
    /// @notice Gets the current token rate
    function rate() external view returns (uint256);
    /// @notice Gets the future epoch time
    // forge-lint: disable-next-line(mixed-case-function)
    function future_epoch_time_write() external view returns (uint256);
}
