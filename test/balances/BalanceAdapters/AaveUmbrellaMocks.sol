// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title Aave Umbrella balance-oracle unit-test mocks
/// @notice Minimal stand-ins for the live Umbrella surface the adapter discovers at runtime, so the
///         balance math (the ERC4626 walk + reward bare-reserve resolution + position emission) can
///         be exercised deterministically without a fork. The fork companion
///         (test/balances/BalanceAdapters/fork/AaveUmbrellaBalanceAdapter.fork.t.sol) covers the real contracts.
/// @dev Conversions use a 1e18-scaled `rate` (assets per share); convertToAssets(0) == 0 so the
///      wrapper-detection probe in the adapter classifies MockErc4626Wrapper as a wrapper and a
///      plain Mock_ERC20 (no asset()/convertToAssets) as a bare reserve.

/// @notice ERC4626-shaped wrapper (e.g. a `waEth*` StataTokenV2 layer): exposes asset() + convertToAssets.
contract MockErc4626Wrapper {
    address public immutable asset;
    uint256 public immutable rate;

    constructor(address asset_, uint256 rate_) {
        asset = asset_;
        rate = rate_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    /// @notice Switches `previewRedeem` between healthy, reverting and gas-burning.
    /// @dev Without this the Umbrella suite could not reach EITHER of `redeemValue`'s failure branches, so the
    ///      caller with the WIDEST blast radius — a plain adapter with no per-stake-token isolation — had no
    ///      test on either path. Found in review.
    enum PreviewMode {
        Ok,
        Revert,
        Starve
    }

    PreviewMode public previewMode;

    function setPreviewMode(PreviewMode m) external {
        previewMode = m;
    }

    /// @notice Fee-less redemption preview, equal to {convertToAssets}.
    /// @dev `previewRedeem` is MANDATORY in ERC4626 and this mock lacked it, so it modelled a wrapper that
    ///      cannot exist — Aave's real `StataTokenV2` waTokens implement it. The omission mattered because
    ///      `_sharesToUnderlying` values the wrapper hop through `ERC4626RedeemLib.redeemValue`, which prefers
    ///      the fee-aware accessor precisely so a wrapper fee (possible via Aave governance) is not
    ///      over-reported. Fee-less here, so both accessors agree and the balance math under test is unchanged;
    ///      the fee-charging case is covered in `test/balances/ERC4626RedeemLib.t.sol`.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        if (previewMode == PreviewMode.Revert) revert("preview unavailable");
        if (previewMode == PreviewMode.Starve) {
            assembly {
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        return (shares * rate) / 1e18;
    }
}

/// @notice Umbrella stake token (ERC4626 vault): balanceOf + convertToAssets + asset(). `asset` may be a
///         wrapper (wa* family → two-hop walk) or a bare reserve directly (stkGHO-style → one hop).
contract MockUmbrellaStakeToken {
    /// @notice Mirrors `IUmbrellaStakeToken.CooldownSnapshot` so the adapter's `getStakerCooldown` read decodes.
    struct CooldownSnapshot {
        uint192 amount;
        uint32 endOfCooldown;
        uint32 withdrawalWindow;
    }

    address public immutable asset;
    uint256 public immutable rate;
    string public symbol;
    mapping(address => uint256) public balanceOf;

    mapping(address => CooldownSnapshot) private _cooldown;
    bool public cooldownAbiEnabled; // when false, getStakerCooldown reverts (degrades to single live leg)

    constructor(address asset_, uint256 rate_, string memory symbol_) {
        asset = asset_;
        rate = rate_;
        symbol = symbol_;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    /// @notice Activate an unstaking cooldown for `account`. Implicitly enables the cooldown ABI.
    function setCooldown(address account, uint192 amount, uint32 endOfCooldown, uint32 withdrawalWindow) external {
        _cooldown[account] = CooldownSnapshot(amount, endOfCooldown, withdrawalWindow);
        cooldownAbiEnabled = true;
    }

    function getStakerCooldown(address user) external view returns (CooldownSnapshot memory) {
        require(cooldownAbiEnabled, "no cooldown ABI");
        return _cooldown[user];
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}

/// @notice aToken-shaped reward token: exposes UNDERLYING_ASSET_ADDRESS() so the adapter maps the
///         reward onto its bare reserve. Plain reward tokens (no such getter) resolve to themselves.
contract MockAToken {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    // solhint-disable-next-line func-name-mixedcase
    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return underlying;
    }
}

/// @notice Umbrella RewardsController: enumerates stake tokens and returns per-(stakeToken,user) rewards.
contract MockUmbrellaRewardsController {
    address[] internal _all;
    mapping(bytes32 => address[]) internal _rewardTokens;
    mapping(bytes32 => uint256[]) internal _rewardAmounts;

    function addStakeToken(address stakeToken) external {
        _all.push(stakeToken);
    }

    function getAllAssets() external view returns (address[] memory) {
        return _all;
    }

    function setRewards(address stakeToken, address user, address[] calldata tokens, uint256[] calldata amounts)
        external
    {
        bytes32 k = keccak256(abi.encode(stakeToken, user));
        _rewardTokens[k] = tokens;
        _rewardAmounts[k] = amounts;
    }

    function calculateCurrentUserRewards(address stakeToken, address user)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        bytes32 k = keccak256(abi.encode(stakeToken, user));
        return (_rewardTokens[k], _rewardAmounts[k]);
    }
}
