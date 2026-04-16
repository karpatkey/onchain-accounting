// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InvalidArguments} from "src/errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

/// @title Aura Balancerv3 Balance Oracle
/// @notice Oracle contract for retrieving token balances from Aura Balancer V3 pools
/// @dev Supports Aura positions on both mainnet and sidechains (L2s). AURA token address
///      is resolved dynamically from the Booster's `minter()`: on mainnet it returns the
///      AURA token directly, on L2s it returns the L2Coordinator whose `auraOFT()` method
///      reveals the bridged AURA address. L2 AURA rewards are computed via the
///      L2Coordinator's `mintRate()` rather than mainnet's cliff-based schedule.
contract Aura is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;

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

    /// @notice Balancer V3 Pool contract that holds the underlying assets
    IStablePool public immutable POOL;

    /// @notice Balancer V3 Gauge contract for staking pool tokens and earning rewards
    IGaugeV3 public immutable GAUGE;

    /// @notice Aura Booster contract that manages pool rewards and multipliers
    IBooster public immutable BOOSTER;

    /// @notice Pool ID in the Aura Booster contract
    uint256 public immutable PID;

    /// @notice Aura token contract address (dynamically resolved: Booster.minter() on mainnet,
    ///         L2Coordinator.auraOFT() on sidechains).
    address public immutable AURA_TOKEN;

    /// @notice Interface for the Aura token contract (mainnet only; address(0) on L2).
    IAuraToken internal immutable _IAURA;

    /// @notice L2Coordinator for sidechain AURA minting (L2 only; address(0) on mainnet).
    IL2Coordinator internal immutable _L2_COORDINATOR;

    /// @notice True if this adapter is deployed on the AURA-minting chain (Ethereum mainnet),
    ///         false if on an L2 where AURA is bridged and the L2Coordinator governs minting.
    bool public immutable IS_MAINNET;

    /// @notice Aura rewards pool contract that distributes rewards to stakers
    IBaseRewardPool4626 public immutable AURA_REWARDS;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @notice Initializes the oracle with pool and gauge addresses
    /// @param pool_ Address of the Balancer V3 pool
    /// @param gauge_ Address of the corresponding gauge contract
    /// @param booster_ Address of the Aura Booster contract
    /// @param pid_ Pool ID in the Aura Booster contract
    /// @param protocol_ Protocol identifier (e.g., "Aura").
    /// @param positionDetail_ Position detail identifier (e.g., "Some Aura Pool").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    /// @dev Validates that the gauge's LP token matches the pool address. AURA token address and
    ///      the chain kind (Mainnet vs L2) are both derived from `BOOSTER.minter()`:
    ///      on Mainnet `minter()` returns AURA directly; on L2s it returns the L2Coordinator,
    ///      whose `auraOFT()` method reveals the bridged AURA address.
    constructor(
        address pool_,
        address gauge_,
        address booster_,
        uint256 pid_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (pool_ == address(0) || gauge_ == address(0)) {
            revert InvalidArguments();
        }
        require(pool_.code.length > 0, "Pool must be a contract");
        require(gauge_.code.length > 0, "Gauge must be a contract");
        require(booster_.code.length > 0, "Booster must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        POOL = IStablePool(pool_);
        BOOSTER = IBooster(booster_);
        GAUGE = IGaugeV3(gauge_);
        PID = pid_;

        // Resolve AURA token address from the Booster's minter.
        // On Mainnet, minter() returns the AURA token directly.
        // On L2s, minter() returns the L2Coordinator whose auraOFT() is the bridged AURA.
        address minter = BOOSTER.minter();
        (bool l2Success, bytes memory l2Data) =
            minter.staticcall(abi.encodeWithSelector(IL2Coordinator.auraOFT.selector));
        if (l2Success && l2Data.length >= 32) {
            IS_MAINNET = false;
            _L2_COORDINATOR = IL2Coordinator(minter);
            AURA_TOKEN = abi.decode(l2Data, (address));
            _IAURA = IAuraToken(address(0));
        } else {
            IS_MAINNET = true;
            AURA_TOKEN = minter;
            _IAURA = IAuraToken(minter);
            _L2_COORDINATOR = IL2Coordinator(address(0));
        }

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

        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Public API
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
        // Base reward (typically BAL)
        if (AURA_REWARDS.rewardToken() == token) {
            total += baseRewards(AURA_REWARDS, safe);
        }

        // AURA mint derived from earned base rewards on the base pool.
        // Mainnet: apply BOOSTER reward multiplier, then cliff-schedule conversion.
        // L2: bypass the multiplier (getRewardMultipliers is mainnet-only) and use L2Coordinator mint rate.
        if (AURA_TOKEN == token) {
            uint256 earned = previewEarned(AURA_REWARDS, safe);
            uint256 auraMint = IS_MAINNET
                ? auraMintAmountConversion(rewardClaimed(address(AURA_REWARDS), earned))
                : calculateL2AuraMint(earned);
            total += auraMint.toInt256();
        }

        // Extra rewards (may be direct reward tokens, stash wrappers, or additional AURA)
        for (uint256 i = 0; i < AURA_REWARDS.extraRewardsLength(); i++) {
            IBaseRewardPool4626 pool = IBaseRewardPool4626(AURA_REWARDS.extraRewards(i));
            address extraRewardToken = pool.rewardToken();

            try IStashToken(extraRewardToken).baseToken() returns (address baseToken) {
                if (baseToken == token) {
                    total += baseRewards(pool, safe);
                }
            } catch {
                // Not a stash token — check direct match
                if (extraRewardToken == token) {
                    total += baseRewards(pool, safe);
                }
            }

            if (AURA_TOKEN == token) {
                uint256 earned = previewEarned(pool, safe);
                uint256 auraMint = IS_MAINNET
                    ? auraMintAmountConversion(rewardClaimed(address(pool), earned))
                    : calculateL2AuraMint(earned);
                total += auraMint.toInt256();
            }
        }
    }

    /// @notice Calculates AURA mint amount for L2 chains using the L2Coordinator mint rate
    /// @param balAmount The amount of base rewards (BAL, adjusted by reward multiplier)
    /// @return auraAmount The amount of AURA tokens that would be minted on this L2
    /// @dev Mirrors v1 Aura.calculateL2AuraMint. Returns 0 on Mainnet.
    function calculateL2AuraMint(uint256 balAmount) public view returns (uint256 auraAmount) {
        if (IS_MAINNET) return 0;
        uint256 mintRate = _L2_COORDINATOR.mintRate();
        if (mintRate > 0) {
            auraAmount = (balAmount * mintRate) / 1e18;
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

        return earned.toInt256();
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
                + (((pool.lastTimeRewardApplicable() - lastUpdateTime) * (pool.rewardRate()) * (1e18))
                    / pool.totalSupply());
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

    /// @notice Converts a reward amount to Aura token amount based on emission schedule (Mainnet only)
    /// @param amount The reward amount to convert
    /// @return The converted Aura token amount. Returns 0 on L2s.
    /// @dev L2 AURA minting is governed by the L2Coordinator's `mintRate()`; see `calculateL2AuraMint`.
    function auraMintAmountConversion(uint256 amount) public view returns (uint256) {
        if (!IS_MAINNET) return 0;
        uint256 supply = _IAURA.totalSupply();
        if (supply == 0) return 0;

        uint256 emissionsMinted = supply - _IAURA.INIT_MINT_AMOUNT() - getMinterMinted(AURA_TOKEN);

        uint256 cliff = emissionsMinted / _IAURA.reductionPerCliff();

        if (cliff >= _IAURA.totalCliffs()) {
            return 0;
        }

        uint256 reduction = ((_IAURA.totalCliffs() - cliff) * 5) / 2 + 700;
        uint256 mintAmount = (amount * reduction) / _IAURA.totalCliffs();

        uint256 amtTillMax = _IAURA.EMISSIONS_MAX_SUPPLY() - emissionsMinted;
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
            result := staticcall(
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
    /// @param safe Address of the user
    /// @param token Address of the reward token
    /// @return Amount of claimable reward tokens
    function gaugeRewards(address safe, address token) public view returns (int256) {
        uint256 claimableReward = GAUGE.claimable_reward(safe, token);
        return claimableReward.toInt256();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _underlyingAssetsSupported();
    }

    /// @notice Internal helper to list all underlying assets supported by the Aura pool.
    /// @dev Includes pool underlying tokens (unwrapping ERC4626) and reward tokens from Aura rewards.
    /// @return assets Array of supported underlying asset addresses.
    function _underlyingAssetsSupported() internal view returns (address[] memory assets) {
        address[] memory poolTokens = _getPoolTokens();
        address[] memory rewardTokens = _getRewardTokens();

        uint256 totalLen = poolTokens.length + rewardTokens.length;
        address[] memory temp = new address[](totalLen);
        uint256 count = 0;

        for (uint256 i = 0; i < poolTokens.length; i++) {
            temp[count++] = poolTokens[i];
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (!_isDuplicate(temp, count, rewardTokens[i])) {
                temp[count++] = rewardTokens[i];
            }
        }

        assets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = temp[i];
        }
    }

    /// @notice Gets pool tokens, unwrapping ERC4626 tokens to their underlying assets.
    /// @return Pool token addresses (underlying where the pool token is an ERC4626 vault).
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

    /// @notice Gets reward tokens from the Aura rewards pool (base reward, AURA, and extra rewards).
    /// @return Reward token addresses (base tokens where reward is a stash wrapper).
    function _getRewardTokens() internal view returns (address[] memory) {
        uint256 maxRewards = 10;
        address[] memory temp = new address[](maxRewards);
        uint256 count = 0;

        (bool success, bytes memory data) =
            address(AURA_REWARDS).staticcall(abi.encodeWithSelector(IBaseRewardPool4626.rewardToken.selector));
        if (success && data.length >= 32) {
            address rewardToken = abi.decode(data, (address));
            if (rewardToken != address(0)) {
                temp[count++] = rewardToken;
            }
        }

        temp[count++] = AURA_TOKEN;

        (bool lengthSuccess, bytes memory lengthData) =
            address(AURA_REWARDS).staticcall(abi.encodeWithSelector(IBaseRewardPool4626.extraRewardsLength.selector));
        if (lengthSuccess && lengthData.length >= 32) {
            uint256 extraLength = abi.decode(lengthData, (uint256));
            uint256 maxExtra = extraLength > 8 ? 8 : extraLength;
            for (uint256 i = 0; i < maxExtra; i++) {
                (bool extraSuccess, bytes memory extraData) = address(AURA_REWARDS)
                    .staticcall(abi.encodeWithSelector(IBaseRewardPool4626.extraRewards.selector, i));
                if (extraSuccess && extraData.length >= 32) {
                    address extraPool = abi.decode(extraData, (address));
                    address baseToken = _getBaseToken(extraPool);
                    if (baseToken != address(0) && !_isDuplicate(temp, count, baseToken)) {
                        temp[count++] = baseToken;
                    }
                }
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Resolves base token for an extra reward pool (unstashes wrapper tokens).
    /// @param extraPool Address of the extra reward pool.
    /// @return The base token address, or the reward token if not a stash.
    function _getBaseToken(address extraPool) internal view returns (address) {
        (bool success, bytes memory data) =
            extraPool.staticcall(abi.encodeWithSelector(IBaseRewardPool4626.rewardToken.selector));
        if (!success || data.length < 32) {
            return address(0);
        }
        address rewardToken = abi.decode(data, (address));
        (bool baseSuccess, bytes memory baseData) =
            rewardToken.staticcall(abi.encodeWithSelector(IStashToken.baseToken.selector));
        if (baseSuccess && baseData.length >= 32) {
            return abi.decode(baseData, (address));
        }
        return rewardToken;
    }

    /// @notice Returns true if token is already present in the array within the given length.
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
        return _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
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
            (uint256 amt, bool debt) = _calculateBalance(asset, account);
            if (amt != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = amt;
                tempIsDebt[count] = debt;
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Aura positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by the protocol and registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Get supported assets from pool tokens
        address[] memory supportedAssets = this.underlyingAssetsSupported();

        // Get registered assets from NAVCalculator
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        // Apply asset filter if specified
        address[] memory filteredAssets;
        if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    filteredAssets = new address[](1);
                    filteredAssets[0] = assetFilter;
                    break;
                }
            }
            if (filteredAssets.length == 0) {
                return new INAVCalculator.PositionBalance[](0);
            }
        } else {
            filteredAssets = registeredSupportedAssets;
        }

        // Pre-fetch balance data for filtered assets
        AssetBalanceData[] memory assetBalanceData = new AssetBalanceData[](filteredAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < filteredAssets.length; i++) {
            address asset = filteredAssets[i];
            (uint256 amount, bool isDebt) = _calculateBalance(asset, account);
            if (amount != 0) {
                assetBalanceData[count] = AssetBalanceData({asset: asset, amount: amount, isDebt: isDebt});
                count++;
            }
        }

        // Resize to actual count
        AssetBalanceData[] memory finalAssetBalanceData = new AssetBalanceData[](count);
        for (uint256 i = 0; i < count; i++) {
            finalAssetBalanceData[i] = assetBalanceData[i];
        }

        // Build positions from pre-fetched data
        return _buildPositions(finalAssetBalanceData);
    }

    //
    // Internal Functions
    //

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param token The asset address
    /// @param account The account address
    /// @return amount Balance magnitude (non-negative)
    /// @return isDebt True if debt, false if credit
    function _calculateBalance(address token, address account) internal view returns (uint256 amount, bool isDebt) {
        uint256 userGaugeBalance = AURA_REWARDS.balanceOf(account);
        int256 balance = poolBalanceOf(userGaugeBalance, token) + rewards(token, account);
        if (balance < 0) {
            return (SafeCast.toUint256(-balance), true);
        }
        if (balance > 0) {
            return (SafeCast.toUint256(balance), false);
        }
        return (0, false);
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

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData with pre-fetched balance information
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets in assetBalanceData are guaranteed to be registered in NAVCalculator.
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
                positionDetail: _positionDetail
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

/// @title Balancer V3 Gauge Interface
/// @notice Interface for interacting with Balancer V3 liquidity gauges
interface IGaugeV3 is IERC20 {
    /// @notice Returns the address of the LP token that can be staked in this gauge
    /// @return The address of the LP token
    //solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address);

    /// @notice Returns the amount of reward tokens claimable by a user
    /// @param user Address of the user to check rewards for
    /// @param token Address of the reward token to check
    /// @return The amount of reward tokens claimable
    //solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
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

    /// @notice Returns the minter address. On Mainnet this is the AURA token; on L2s
    ///         it is the L2Coordinator whose `auraOFT()` is the bridged AURA address.
    /// @return The minter address.
    function minter() external view returns (address);
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

/// @title L2 Coordinator Interface
/// @notice Interface for the Aura L2Coordinator contract deployed on sidechains. Responsible
///         for bridging AURA rewards from mainnet and governing the per-chain mint rate.
interface IL2Coordinator {
    /// @notice Returns the bridged AURA OFT token address on this L2.
    /// @return The AURA OFT token address.
    function auraOFT() external view returns (address);

    /// @notice Returns the current mint rate (AURA minted per BAL earned, in 1e18 fixed-point).
    /// @return The current mint rate.
    function mintRate() external view returns (uint256);
}

/// @title Aura Token Interface
/// @notice Interface for the Aura token contract (Mainnet only)
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
