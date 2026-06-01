// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Aave v3 Safety Module Balance Oracle (multi-token, hardcoded)
/// @author kpk
/// @notice Reports balances across every known legacy Aave V3 Safety Module stake token for a given account, currently:
///         `stkAAVE`, `stkABPT` (Balancer V1 BPT), `stkABPTv2` (Balancer V2 AAVE/wstETH BPT), and `stkGHO`. The Safety
///         Module set is a small, slow-moving, on-chain-discovery-free list (Aave does not publish an on-chain registry
///         of stake tokens), so the adapter pins the addresses as compile-time constants. This keeps every balance
///         adapter in the framework immutable and write-function-free. If Aave governance ships a new SM stake token,
///         updating this adapter is a source-code change (new constant + new record + new test holder) — not an admin
///         transaction. That tradeoff is intentional and tracked in the relevant ADR.
/// @dev Mainnet only. The legacy Safety Module is an Ethereum-mainnet protocol; deploying this adapter on another
///      chain is meaningless. Each stake token's `STAKED_TOKEN()` and `REWARD_TOKEN()` are also pinned as constants so
///      no live reads happen during construction. Reward token is AAVE for every entry today; `_records()` keeps a
///      per-entry `rewardToken` field so a future stake token with a non-AAVE reward (unlikely but possible) is a
///      one-line change.
contract AaveV3SafetyModuleBalanceOracle is IBalanceOracleAdapter {
    //
    // Constants — Mainnet Safety Module addresses
    //

    /// @notice Aave token (reward for all four stake tokens; also the staked asset of stkAAVE).
    address public constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    /// @notice GHO stablecoin (staked asset of stkGHO).
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    /// @notice ABPT — Aave Balancer Pool Token (staked asset of stkABPT, the Balancer V1 BPT).
    address public constant ABPT = 0x41A08648C3766F9F9d85598fF102a08f4ef84F84;

    /// @notice ABPT v2 — Balancer V2 AAVE/wstETH Pool Token (staked asset of stkABPTv2).
    address public constant ABPT_V2 = 0x3de27EFa2F1AA663Ae5D458857e731c129069F29;

    /// @notice stkAAVE — staked AAVE. Both `STAKED_TOKEN()` and `REWARD_TOKEN()` are AAVE.
    address public constant STK_AAVE = 0x4da27a545c0c5B758a6BA100e3a049001de870f5;

    /// @notice stkABPT — staked Aave Balancer V1 Pool Token. `STAKED_TOKEN()` = ABPT, `REWARD_TOKEN()` = AAVE.
    address public constant STK_ABPT = 0xa1116930326D21fB917d5A27F1E9943A9595fb47;

    /// @notice stkABPTv2 — staked Balancer V2 AAVE/wstETH BPT. `STAKED_TOKEN()` = ABPT_V2, `REWARD_TOKEN()` = AAVE.
    address public constant STK_ABPT_V2 = 0x9eDA81C21C273a82BE9Bbc19B6A6182212068101;

    /// @notice stkGHO — staked GHO. `STAKED_TOKEN()` = GHO, `REWARD_TOKEN()` = AAVE.
    address public constant STK_GHO = 0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d;

    //
    // Type Definitions
    //

    /// @dev Internal record describing one Safety Module stake token. Keeping the staked / reward addresses as constants
    ///      (rather than reading them from the contract at deploy time) keeps the adapter purely view-friendly and means
    ///      a misconfiguration in source code is the only way to ship a wrong wiring — caught at review time.
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_SAFETY_MODULE;

    struct StakeTokenRecord {
        address stakeToken;
        address stakedToken;
        address rewardToken;
        string positionDetail;
    }

    //
    // State
    //

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param navCalculator The NAVCalculator address (used to look up registered assets when emitting positions).
    constructor(address navCalculator) {
        if (navCalculator == address(0)) revert InvalidArguments();
        require(navCalculator.code.length > 0, "NAVCalculator must be a contract");
        NAV_CALCULATOR = INAVCalculator(navCalculator);
    }

    //
    // Internal — stake token table
    //

    /// @dev The full hardcoded list of Safety Module stake tokens. Used by every balance/position function.
    ///      The function is `pure` (no storage reads) — the data is baked into bytecode.
    function _records() internal pure returns (StakeTokenRecord[4] memory recs) {
        recs[0] =
            StakeTokenRecord({stakeToken: STK_AAVE, stakedToken: AAVE, rewardToken: AAVE, positionDetail: "stkAAVE"});
        recs[1] =
            StakeTokenRecord({stakeToken: STK_ABPT, stakedToken: ABPT, rewardToken: AAVE, positionDetail: "stkABPT"});
        recs[2] = StakeTokenRecord({
            stakeToken: STK_ABPT_V2, stakedToken: ABPT_V2, rewardToken: AAVE, positionDetail: "stkABPTv2"
        });
        recs[3] = StakeTokenRecord({stakeToken: STK_GHO, stakedToken: GHO, rewardToken: AAVE, positionDetail: "stkGHO"});
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) { return "Aave V3"; }
    function describePosition(bytes calldata) external pure returns (string memory) { return "safety module"; }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the deduplicated union of staked and reward tokens across every Safety Module stake token.
    ///         For the legacy SM specifically: AAVE (reward of all four; also stkAAVE's staked) + GHO + ABPT + ABPT_V2.
    function underlyingAssetsSupported() public pure override returns (address[] memory) {
        address[] memory out = new address[](4);
        out[0] = AAVE;
        out[1] = GHO;
        out[2] = ABPT;
        out[3] = ABPT_V2;
        return out;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the **summed** balance for `asset` across every Safety Module stake token.
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
    /// @notice Returns up to two PositionBalances per stake token: one for the staked leg (type "Staking") and one
    ///         for the reward leg (type "Reward"). The underlyingAsset field disambiguates the stake token involved.
    /// @dev For stkAAVE both legs share the same asset (AAVE); they are told apart solely by their type label.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();

        StakeTokenRecord[4] memory recs = _records();
        // Worst case: 2 positions per stake token (staked + reward).
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](recs.length * 2);
        uint256 count;

        for (uint256 i; i < recs.length; ++i) {
            StakeTokenRecord memory r = recs[i];

            // Staked-token leg.
            if (_passesFilter(r.stakedToken, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, r.stakedToken);
                if (assetMeta.asset != address(0)) {
                    uint256 stakedAmount =
                        IStakeToken(r.stakeToken).previewRedeem(IStakeToken(r.stakeToken).balanceOf(account));
                    if (stakedAmount != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            balanceAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: stakedAmount,
                            isDebt: false,
                            protocolId: PROTOCOL_ID,
                            positionId: abi.encode(address(r.stakeToken)),
                            positionKind: PositionKind.Supplied
                        });
                    }
                }
            }

            // Reward-token leg.
            if (_passesFilter(r.rewardToken, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, r.rewardToken);
                if (assetMeta.asset != address(0)) {
                    uint256 rewards = IStakeToken(r.stakeToken).getTotalRewardsBalance(account);
                    if (rewards != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            balanceAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: rewards,
                            isDebt: false,
                            protocolId: PROTOCOL_ID,
                            positionId: abi.encode(address(r.stakeToken)),
                            positionKind: PositionKind.Earned
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
    // Internal — balance math
    //

    /// @dev Sums `asset` balances across every hardcoded stake token. For each:
    ///        - if `stakedToken == asset`, add `previewRedeem(balanceOf(account))`.
    ///        - if `rewardToken == asset`, add `getTotalRewardsBalance(account)`.
    ///      Both apply when `stakedToken == rewardToken == asset` (e.g. stkAAVE → AAVE on both sides).
    function _summedBalance(address account, address asset) internal view returns (uint256 total) {
        StakeTokenRecord[4] memory recs = _records();
        for (uint256 i; i < recs.length; ++i) {
            StakeTokenRecord memory r = recs[i];
            if (r.stakedToken == asset) {
                total += IStakeToken(r.stakeToken).previewRedeem(IStakeToken(r.stakeToken).balanceOf(account));
            }
            if (r.rewardToken == asset) {
                total += IStakeToken(r.stakeToken).getTotalRewardsBalance(account);
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
}

/// @notice Minimal interface for the Aave Safety Module stake token contracts.
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
