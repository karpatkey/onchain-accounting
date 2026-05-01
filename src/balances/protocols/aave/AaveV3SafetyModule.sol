// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Aave v3 Safety Module Balance Oracle (multi-token)
/// @author kpk
/// @notice Tracks user positions across **all** Aave v3 Safety Module stake tokens registered with this adapter
///         (e.g. stkAAVE, stkABPT, stkGHO). Returned amounts are denominated in the underlying staked or reward token.
/// @dev This is the **only mutable balance adapter** in the framework: the owner (typically the OIV Safe) manages the
///      list of registered stake tokens via `addStakeToken` / `removeStakeToken`. The deviation from the framework's
///      "adapters are immutable" rule is intentional and documented in `docs/decisions/0002-aave-safety-module-multi-token.md`.
contract AaveV3SafetyModuleBalanceOracle is IBalanceOracleAdapter, Ownable {
    //
    // Type Definitions
    //

    /// @notice Configuration recorded for each registered Safety Module stake token.
    /// @param stakedToken The asset that gets staked (read once via `STAKED_TOKEN()` at registration).
    /// @param rewardToken The asset paid out as rewards (read once via `REWARD_TOKEN()` at registration).
    /// @param positionDetail Admin-supplied label used as `PositionBalance.positionDetail`
    ///        (e.g. "stkGHO", "stkAAVE"). Distinguishes attribution when multiple stake tokens share an asset.
    struct StakeTokenInfo {
        address stakedToken;
        address rewardToken;
        string positionDetail;
    }

    /// @notice Constructor input for seeding the initial stake token list.
    struct StakeTokenInit {
        address stakeToken;
        string positionDetail;
    }

    //
    // State Variables
    //

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "Aave V3 Safety Module").
    string public PROTOCOL;

    /// @notice Per-stake-token configuration.
    mapping(address stakeToken => StakeTokenInfo) public stakeTokenInfo;

    /// @notice Whether `stakeToken` is currently registered with this adapter.
    mapping(address stakeToken => bool) public isStakeTokenRegistered;

    /// @dev Iteration list of registered stake tokens. Kept in sync via swap-and-pop on removal.
    address[] internal _stakeTokenList;

    /// @dev Index into `_stakeTokenList` (1-based; 0 means "not present"). Enables O(1) removal.
    mapping(address stakeToken => uint256) internal _stakeTokenIndex;

    //
    // Events
    //

    /// @notice Emitted when a stake token is registered with this adapter.
    event StakeTokenAdded(address indexed stakeToken, address stakedToken, address rewardToken, string positionDetail);

    /// @notice Emitted when a stake token is removed from this adapter.
    event StakeTokenRemoved(address indexed stakeToken);

    //
    // Errors
    //

    /// @notice Thrown when adding a stake token that is already registered.
    error StakeTokenAlreadyRegistered(address stakeToken);

    /// @notice Thrown when removing a stake token that is not registered.
    error StakeTokenNotRegistered(address stakeToken);

    //
    // Constructor
    //

    /// @notice Deploys the adapter with an initial set of stake tokens and the given admin.
    /// @param initial Initial list of `(stakeToken, positionDetail)` pairs to register at construction.
    ///        May be empty; the admin can call `addStakeToken` later.
    /// @param admin The address that owns the adapter (usually the OIV Safe). Manages the stake-token list.
    /// @param navCalculator The NAVCalculator address (used to look up registered assets when emitting positions).
    /// @param protocol_ Protocol identifier (e.g. "Aave V3 Safety Module").
    constructor(StakeTokenInit[] memory initial, address admin, address navCalculator, string memory protocol_)
        Ownable(admin)
    {
        if (admin == address(0) || navCalculator == address(0)) revert InvalidArguments();
        require(navCalculator.code.length > 0, "NAVCalculator must be a contract");

        NAV_CALCULATOR = INAVCalculator(navCalculator);
        PROTOCOL = protocol_;

        uint256 len = initial.length;
        for (uint256 i; i < len; ++i) {
            _addStakeToken(initial[i].stakeToken, initial[i].positionDetail);
        }
    }

    //
    // Admin functions
    //

    /// @notice Registers a Safety Module stake token with this adapter.
    /// @dev Reads `STAKED_TOKEN()` and `REWARD_TOKEN()` from the stake contract once and pins them.
    /// @param stakeToken Address of the stake-token contract (e.g. stkAAVE).
    /// @param positionDetail Label emitted on every PositionBalance from this stake token (e.g. "stkAAVE").
    function addStakeToken(address stakeToken, string calldata positionDetail) external onlyOwner {
        _addStakeToken(stakeToken, positionDetail);
    }

    /// @notice Removes a stake token from this adapter. Existing on-chain balances of users in that
    ///         stake token are no longer reported by this oracle (admin's responsibility to coordinate).
    /// @param stakeToken Address of the stake-token contract to remove.
    function removeStakeToken(address stakeToken) external onlyOwner {
        if (!isStakeTokenRegistered[stakeToken]) revert StakeTokenNotRegistered(stakeToken);

        uint256 indexPlusOne = _stakeTokenIndex[stakeToken];
        uint256 lastIndex = _stakeTokenList.length - 1;
        uint256 idx = indexPlusOne - 1;

        if (idx != lastIndex) {
            address last = _stakeTokenList[lastIndex];
            _stakeTokenList[idx] = last;
            _stakeTokenIndex[last] = idx + 1;
        }
        _stakeTokenList.pop();

        delete stakeTokenInfo[stakeToken];
        delete _stakeTokenIndex[stakeToken];
        isStakeTokenRegistered[stakeToken] = false;

        emit StakeTokenRemoved(stakeToken);
    }

    //
    // Views
    //

    /// @notice Returns the list of currently registered stake tokens.
    function getStakeTokens() external view returns (address[] memory) {
        return _stakeTokenList;
    }

    /// @notice Number of currently registered stake tokens.
    function stakeTokenCount() external view returns (uint256) {
        return _stakeTokenList.length;
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
    /// @notice Returns the deduplicated union of staked and reward tokens across all registered stake tokens.
    function underlyingAssetsSupported() public view override returns (address[] memory) {
        uint256 n = _stakeTokenList.length;
        address[] memory tmp = new address[](n * 2);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            StakeTokenInfo storage info = stakeTokenInfo[_stakeTokenList[i]];
            if (!_contains(tmp, count, info.stakedToken)) {
                tmp[count++] = info.stakedToken;
            }
            if (info.stakedToken != info.rewardToken && !_contains(tmp, count, info.rewardToken)) {
                tmp[count++] = info.rewardToken;
            }
        }

        address[] memory out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the **summed** balance for `asset` across all registered stake tokens.
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (_summedBalance(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns deduplicated per-asset summed balances. Skips zero amounts.
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        address[] memory supported = underlyingAssetsSupported();
        uint256 n = supported.length;
        address[] memory tmpAssets = new address[](n);
        uint256[] memory tmpAmounts = new uint256[](n);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            uint256 bal = _summedBalance(account, supported[i]);
            if (bal != 0) {
                tmpAssets[count] = supported[i];
                tmpAmounts[count] = bal;
                ++count;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns one PositionBalance per `(stakeToken, role)` pair, where role ∈ {staked, reward}.
    /// @dev Multi-stake-token attribution is preserved via `positionDetail`. A user holding both stkGHO and stkAAVE
    ///      sees three positions: GHO/"stkGHO", AAVE/"stkGHO" (rewards), AAVE/"stkAAVE" (stake+rewards merged because
    ///      stkAAVE's staked and reward tokens are both AAVE).
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();

        uint256 n = _stakeTokenList.length;
        // Worst case: 2 positions per stake token (staked + reward).
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](n * 2);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            address stakeToken = _stakeTokenList[i];
            StakeTokenInfo storage info = stakeTokenInfo[stakeToken];

            // Staked-token leg
            if (_passesFilter(info.stakedToken, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, info.stakedToken);
                if (assetMeta.asset != address(0)) {
                    uint256 stakedAmount =
                        IStakeToken(stakeToken).previewRedeem(IStakeToken(stakeToken).balanceOf(account));
                    if (stakedAmount != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            underlyingAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: stakedAmount,
                            isDebt: false,
                            protocol: PROTOCOL,
                            positionDetail: info.positionDetail
                        });
                    }
                }
            }

            // Reward-token leg (skip if same as staked — already counted above with `getTotalRewardsBalance`?
            // No: previewRedeem returns staked-asset amount only. Rewards are a *separate* number, even when
            // stakedToken == rewardToken. So if they're the same, we still need to add the reward amount but
            // merge it into the same PositionBalance as the staked leg.)
            if (info.stakedToken == info.rewardToken) {
                // Merge rewards into the staked-leg position we just emitted (if any).
                if (
                    count > 0 && tmp[count - 1].underlyingAsset.asset == info.stakedToken
                        && _stringEq(tmp[count - 1].positionDetail, info.positionDetail)
                ) {
                    uint256 rewards = IStakeToken(stakeToken).getTotalRewardsBalance(account);
                    tmp[count - 1].amount += rewards;
                } else if (_passesFilter(info.rewardToken, assetFilter)) {
                    // No staked leg was emitted (zero balance); emit a rewards-only position if rewards > 0.
                    INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, info.rewardToken);
                    if (assetMeta.asset != address(0)) {
                        uint256 rewards = IStakeToken(stakeToken).getTotalRewardsBalance(account);
                        if (rewards != 0) {
                            tmp[count++] = INAVCalculator.PositionBalance({
                                underlyingAsset: assetMeta,
                                balanceOracle: address(this),
                                amount: rewards,
                                isDebt: false,
                                protocol: PROTOCOL,
                                positionDetail: info.positionDetail
                            });
                        }
                    }
                }
            } else if (_passesFilter(info.rewardToken, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, info.rewardToken);
                if (assetMeta.asset != address(0)) {
                    uint256 rewards = IStakeToken(stakeToken).getTotalRewardsBalance(account);
                    if (rewards != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            underlyingAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: rewards,
                            isDebt: false,
                            protocol: PROTOCOL,
                            positionDetail: info.positionDetail
                        });
                    }
                }
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    //
    // Internal — admin
    //

    function _addStakeToken(address stakeToken, string memory positionDetail) internal {
        if (stakeToken == address(0)) revert InvalidArguments();
        require(stakeToken.code.length > 0, "StakeToken must be a contract");
        if (isStakeTokenRegistered[stakeToken]) revert StakeTokenAlreadyRegistered(stakeToken);

        address stakedToken = IStakeToken(stakeToken).STAKED_TOKEN();
        address rewardToken = IStakeToken(stakeToken).REWARD_TOKEN();
        if (stakedToken == address(0) || rewardToken == address(0)) revert InvalidArguments();

        stakeTokenInfo[stakeToken] =
            StakeTokenInfo({stakedToken: stakedToken, rewardToken: rewardToken, positionDetail: positionDetail});
        isStakeTokenRegistered[stakeToken] = true;
        _stakeTokenList.push(stakeToken);
        _stakeTokenIndex[stakeToken] = _stakeTokenList.length; // 1-based

        emit StakeTokenAdded(stakeToken, stakedToken, rewardToken, positionDetail);
    }

    //
    // Internal — balance math
    //

    /// @dev Sums `asset` balances across every registered stake token. For each stake token:
    ///      - if `stakedToken == asset`, add `previewRedeem(balanceOf(account))`.
    ///      - if `rewardToken == asset`, add `getTotalRewardsBalance(account)`.
    ///      Both apply when `stakedToken == rewardToken == asset` (e.g. stkAAVE → AAVE on both sides).
    function _summedBalance(address account, address asset) internal view returns (uint256 total) {
        uint256 n = _stakeTokenList.length;
        for (uint256 i; i < n; ++i) {
            address stakeToken = _stakeTokenList[i];
            StakeTokenInfo storage info = stakeTokenInfo[stakeToken];
            if (info.stakedToken == asset) {
                total += IStakeToken(stakeToken).previewRedeem(IStakeToken(stakeToken).balanceOf(account));
            }
            if (info.rewardToken == asset) {
                total += IStakeToken(stakeToken).getTotalRewardsBalance(account);
            }
        }
    }

    //
    // Internal — helpers
    //

    function _passesFilter(address asset, address assetFilter) internal pure returns (bool) {
        return assetFilter == address(0) || assetFilter == asset;
    }

    function _findRegisteredAsset(INAVCalculator.Asset[] memory registered, address asset)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        uint256 n = registered.length;
        for (uint256 i; i < n; ++i) {
            if (registered[i].asset == asset) return registered[i];
        }
        return INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0});
    }

    function _contains(address[] memory list, uint256 length, address needle) internal pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (list[i] == needle) return true;
        }
        return false;
    }

    function _stringEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

/// @notice Minimal interface for the Aave Safety Module stake token contracts (stkAAVE, stkABPT, stkGHO, …).
/// @dev Reference: https://etherscan.io/address/0x50f9d4e28309303f0cdcac8af0b569e8b75ab857#code
interface IStakeToken {
    /// @notice Address of the reward token paid out to stakers.
    //solhint-disable-next-line func-name-mixedcase
    function REWARD_TOKEN() external view returns (address);

    /// @notice Address of the underlying token that gets staked.
    //solhint-disable-next-line func-name-mixedcase
    function STAKED_TOKEN() external view returns (address);

    /// @notice ERC20 balance of the stake token (in stake-token units).
    function balanceOf(address account) external view returns (uint256);

    /// @notice Converts `shares` of stake token into the underlying staked-token amount the user could redeem.
    function previewRedeem(uint256 shares) external view returns (uint256);

    /// @notice Total claimable rewards for `staker` (in reward-token units).
    function getTotalRewardsBalance(address staker) external view returns (uint256);
}
