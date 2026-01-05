// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InvalidArguments} from "src/errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Aura Balancerv3 Balance Oracle
/// @notice Oracle contract for retrieving token balances from Aura Balancer V3 pools
contract Aura is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;

    //
    // State
    //

    /// @notice Balancer V3 Pool contract that holds the underlying assets
    IStablePool public immutable POOL;

    /// @notice Balancer V3 Gauge contract for staking pool tokens and earning rewards
    IGaugeV3 public immutable GAUGE;

    /// @notice Aura Booster contract that manages pool rewards and multipliers
    IBooster public immutable BOOSTER;

    /// @notice Pool ID in the Aura Booster contract
    uint256 public immutable PID;

    /// @notice Aura token contract address
    IAuraToken public immutable AURA_TOKEN;

    /// @notice Aura rewards pool contract that distributes rewards to stakers
    IBaseRewardPool4626 public immutable AURA_REWARDS;

    /// @notice Position tags associated with the balance oracle.
    PositionMetadata internal _positionMetadata;

    //
    // Constructor
    //

    /// @notice Initializes the oracle with pool and gauge addresses
    /// @param pool_ Address of the Balancer V3 pool
    /// @param gauge_ Address of the corresponding gauge contract
    /// @param booster_ Address of the Aura Booster contract
    /// @param pid_ Pool ID in the Aura Booster contract
    /// @param auraToken_ Address of the Aura token contract
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    /// @dev Validates that the gauge's LP token matches the pool address
    constructor(
        address pool_,
        address gauge_,
        address booster_,
        uint256 pid_,
        address auraToken_,
        PositionMetadata memory positionMetadata_
    ) {
        if (pool_ == address(0) || gauge_ == address(0)) {
            revert InvalidArguments();
        }

        POOL = IStablePool(pool_);
        BOOSTER = IBooster(booster_);
        GAUGE = IGaugeV3(gauge_);
        PID = pid_;
        AURA_TOKEN = IAuraToken(auraToken_);

        try GAUGE.lp_token() returns (address lpToken) {
            if (lpToken != pool_) {
                revert InvalidArguments();
            }
        } catch {
            revert InvalidArguments();
        }

        try BOOSTER.poolInfo(PID) returns (address lptoken, address, address gauge, address crvRewards, address, bool) {
            if (lptoken != pool_) {
                revert InvalidArguments();
            }

            if (gauge != gauge_) {
                revert InvalidArguments();
            }
            AURA_REWARDS = IBaseRewardPool4626(crvRewards);
        } catch {
            revert InvalidArguments();
        }

        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address token, address safe) external view override returns (int256) {
        uint256 userGaugeBalance = AURA_REWARDS.balanceOf(safe);

        return poolBalanceOf(userGaugeBalance, token) + rewards(token, safe);
        //return rewards(token, safe);
    }

    //
    // Internal API
    //

    /// @notice Calculates the total rewards for a given token and safe address
    /// @dev Handles both base rewards and extra rewards:
    ///      - Simulates updateRewards and emulates earned function for base rewards token
    ///      - Processes array of extra rewards by calling getReward
    ///      - May need to emulate getReward calls depending on implementation
    /// @param token The token address to calculate rewards for
    /// @param safe The safe address to calculate rewards for
    /// @return total The total rewards for the given token and safe
    function rewards(address token, address safe) public view returns (int256 total) {
        // 0x8e89d41c563e6c3d9901ad75b75e2d8e140def04
        // call updateRewards()
        if (AURA_REWARDS.rewardToken() == token) {
            total += baseRewards(AURA_REWARDS, safe);
        }

        if (address(AURA_TOKEN) == token) {
            uint256 earned = previewEarned(AURA_REWARDS, safe);
            uint256 claimed = auraMintAmountConversion(rewardClaimed(address(AURA_REWARDS), earned));

            total += int256(claimed);
        }
        // getRewards()

        for (uint256 i = 0; i < AURA_REWARDS.extraRewardsLength(); i++) {
            IBaseRewardPool4626 pool = IBaseRewardPool4626(AURA_REWARDS.extraRewards(i));
            if (IStashToken(pool.rewardToken()).baseToken() == token) {
                total += baseRewards(pool, safe);
            }

            if (address(AURA_TOKEN) == token) {
                uint256 earned = previewEarned(pool, safe);
                uint256 claimed = auraMintAmountConversion(rewardClaimed(address(pool), earned));

                total += int256(claimed);
            }
        }
    }

    /// @notice Calculates the base rewards for a given pool and safe address
    /// @param pool The reward pool to calculate rewards from
    /// @param safe The safe address to calculate rewards for
    /// @return The base rewards for the given pool and safe
    function baseRewards(IBaseRewardPool4626 pool, address safe) public view returns (int256) {
        // 0x8e89d41c563e6c3d9901ad75b75e2d8e140def04
        // call updateRewards()

        uint256 earned = previewEarned(pool, safe);

        return int256(earned);
    }

    /// @notice Previews the earned rewards for a given pool and account
    /// @param pool The reward pool to preview rewards from
    /// @param account The account to preview rewards for
    /// @return The previewed earned rewards
    function previewEarned(IBaseRewardPool4626 pool, address account) public view returns (uint256) {
        uint256 rewardPerTokenStored = pool.rewardPerToken();
        uint256 lastUpdateTime = pool.lastTimeRewardApplicable();
        uint256 rewardsAccount = pool.earned(account);
        uint256 userRewardPerTokenPaidAccount = rewardPerTokenStored;

        uint256 secondRewardPerToken = rewardPerTokenStored;

        if (pool.totalSupply() != 0) {
            secondRewardPerToken = rewardPerTokenStored
                + (((pool.lastTimeRewardApplicable() - lastUpdateTime) * (pool.rewardRate()) * (1e18)) / pool.totalSupply());
        }

        return
            rewardsAccount + ((pool.balanceOf(account) * (secondRewardPerToken - userRewardPerTokenPaidAccount)) / 1e18);
    }

    /// @notice Emulates rewardClaimed from 0xa57b8d98dae62b26ec3bcc4a365338157060b234 mainnet.
    /// @param token The address of the reward token
    /// @param amount The amount of the reward token claimed
    /// @return The amount of Aura tokens that would be minted based on the claimed reward
    function rewardClaimed(address token, uint256 amount) public view returns (uint256) {
        uint256 mintAmount =
            (amount * BOOSTER.getRewardMultipliers(address(token))) / (BOOSTER.REWARD_MULTIPLIER_DENOMINATOR());

        return mintAmount;
    }

    /// @notice Converts a reward amount to Aura token amount based on emission schedule
    /// @param amount The reward amount to convert
    /// @return The converted Aura token amount
    function auraMintAmountConversion(uint256 amount) public view returns (uint256) {
        uint256 supply = AURA_TOKEN.totalSupply();
        if (supply == 0) return 0;

        uint256 emissionsMinted = supply - AURA_TOKEN.INIT_MINT_AMOUNT() - getMinterMinted(address(AURA_TOKEN));

        uint256 cliff = emissionsMinted / AURA_TOKEN.reductionPerCliff();

        if (cliff >= AURA_TOKEN.totalCliffs()) {
            return 0;
        }

        uint256 reduction = ((AURA_TOKEN.totalCliffs() - cliff) * 5) / 2 + 700;
        uint256 mintAmount = (amount * reduction) / AURA_TOKEN.totalCliffs();

        uint256 amtTillMax = AURA_TOKEN.EMISSIONS_MAX_SUPPLY() - emissionsMinted;
        if (mintAmount > amtTillMax) {
            mintAmount = amtTillMax;
        }

        return mintAmount;
    }

    /// @notice Gets the total amount of Aura tokens minted by the minter
    /// @dev Uses low-level assembly to read storage slot 2 from the Aura token contract
    ///      This slot contains the total amount of tokens minted by the minter
    ///      The function performs a staticcall to read the storage slot directly
    /// @param auraToken The address of the Aura token contract
    /// @return result The total amount of Aura tokens minted
    function getMinterMinted(address auraToken) public view returns (uint256 result) {
        bytes32 slot = bytes32(uint256(2)); // slot 2
        //solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, slot)
            result :=
                staticcall(
                    gas(), // forward all gas
                    auraToken, // to Aura token
                    ptr,
                    0x20, // input at ptr, 32 bytes (slot)
                    ptr,
                    0x20 // store output in same ptr
                )
            result := mload(ptr)
        }
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
    //solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address);

    /// @notice Returns the amount of reward tokens claimable by a user
    /// @param user Address of the user to check rewards for
    /// @param token Address of the reward token to check
    /// @return The amount of reward tokens claimable
    //solhint-disable-next-line func-name-mixedcase
    function claimable_reward(address user, address token) external view returns (uint256);
}

/// @title Balancer V3 Stable Pool Interface
/// @notice Interface for interacting with Balancer V3 stable pools
interface IStablePool is IERC20 {
    /// @notice Dynamic data structure for stable pool state
    /// @dev Contains current pool state that can change over time
    /// @param balancesLiveScaled18 Array of live scaled balances for each token
    /// @param tokenRates Array of current token rates
    /// @param staticSwapFeePercentage Current static swap fee percentage
    /// @param totalSupply Total supply of the pool
    /// @param bptRate Rate of the BPT token
    /// @param amplificationParameter Current amplification parameter
    /// @param startValue Starting value for the pool
    /// @param endValue Ending value for the pool
    /// @param startTime Start time for the pool
    /// @param endTime End time for the pool
    /// @param isAmpUpdating Whether the amplification parameter is currently being updated
    /// @param isPoolInitialized Whether the pool has been initialized
    /// @param isPoolPaused Whether the pool is currently paused
    /// @param isPoolInRecoveryMode Whether the pool is in recovery mode
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
    /// @param tokens Array of token addresses in the pool
    /// @param decimalScalingFactors Array of scaling factors for each token's decimals
    /// @param amplificationParameterPrecision Precision for the amplification parameter
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
}

/// @title Aura Booster Interface
/// @notice Interface for the Aura Booster contract that manages pool rewards and multipliers
interface IBooster {
    /// @notice Gets information about a specific pool
    /// @param pid The pool ID to get information for
    /// @return lptoken The LP token address for the pool
    /// @return token The reward token address
    /// @return gauge The gauge contract address
    /// @return crvRewards The CRV rewards contract address
    /// @return stash The stash contract address
    /// @return shutdown Whether the pool is shutdown
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);

    /// @notice Gets the reward multiplier for a specific token
    /// @param token The token address to get multiplier for
    /// @return The reward multiplier value
    function getRewardMultipliers(address token) external view returns (uint256);

    /// @notice Gets the denominator used for reward multiplier calculations
    /// @return The reward multiplier denominator
    //solhint-disable-next-line func-name-mixedcase
    function REWARD_MULTIPLIER_DENOMINATOR() external view returns (uint256);
}

/// @title Base Reward Pool Interface
/// @notice Interface for the base reward pool that distributes rewards to stakers
interface IBaseRewardPool4626 is IERC20 {
    /// @notice Gets the address of an extra reward pool at the specified index
    /// @param index The index of the extra reward pool
    /// @return The address of the extra reward pool
    function extraRewards(uint256 index) external view returns (address);

    /// @notice Gets the total number of extra reward pools
    /// @return The number of extra reward pools
    function extraRewardsLength() external view returns (uint256);

    /// @notice Gets the address of the reward token
    /// @return The reward token address
    function rewardToken() external view returns (address);

    /// @notice Gets the current reward per token rate
    /// @return The reward per token rate
    function rewardPerToken() external view returns (uint256);

    /// @notice Gets the earned rewards for an account
    /// @param account The account to check rewards for
    /// @return The amount of earned rewards
    function earned(address account) external view returns (uint256);

    /// @notice Gets the pool ID
    /// @return The pool ID
    function pid() external view returns (uint256);

    /// @notice Gets the last time rewards were applicable
    /// @return The timestamp of the last reward application
    function lastTimeRewardApplicable() external view returns (uint256);

    /// @notice Gets the current reward rate
    /// @return The reward rate
    function rewardRate() external view returns (uint256);
}

/// @title Stash Token Interface
/// @notice Interface for stash tokens that wrap base tokens
interface IStashToken {
    /// @notice Gets the address of the base token
    /// @return The base token address
    function baseToken() external view returns (address);
}

/// @title Aura Token Interface
/// @notice Interface for the Aura token contract
interface IAuraToken {
    /// @notice Gets the total supply of Aura tokens
    /// @return The total supply
    function totalSupply() external view returns (uint256);

    /// @notice Gets the initial mint amount
    /// @return The initial mint amount
    //solhint-disable-next-line func-name-mixedcase
    function INIT_MINT_AMOUNT() external view returns (uint256);

    /// @notice Gets the total amount of tokens minted by the minter
    /// @return The total minted amount
    function minterMinted() external view returns (uint256);

    /// @notice Gets the reduction amount per cliff
    /// @return The reduction amount
    function reductionPerCliff() external view returns (uint256);

    /// @notice Gets the total number of cliffs
    /// @return The total cliffs
    function totalCliffs() external view returns (uint256);

    /// @notice Gets the maximum supply for emissions
    /// @return The maximum emissions supply
    //solhint-disable-next-line func-name-mixedcase
    function EMISSIONS_MAX_SUPPLY() external view returns (uint256);
}
