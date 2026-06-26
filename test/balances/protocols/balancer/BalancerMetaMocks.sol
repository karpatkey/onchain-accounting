// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ERC20-metadata token used as a Balancer pool token or reward token. Deliberately has no
///         `asset()` so the adapters' ERC4626-unwrap probe treats it as a plain (non-wrapped) token.
contract MockBalToken {
    string public symbol;
    string public name;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        name = symbol_;
        decimals = decimals_;
    }
}

/// @notice Minimal Balancer V3 StablePool mock exposing the surface used by BalancerV3PoolLib: ERC20 name/
///         balanceOf/totalSupply plus the stable-pool dynamic/immutable data. Per-token entries are appended
///         via `addToken(token, balanceLiveScaled18, decimalScalingFactor, tokenRate)`.
contract MockStablePool {
    string public name;
    uint256 private _totalSupply;
    mapping(address => uint256) public balanceOf;

    address[] private _tokens;
    uint256[] private _balancesLiveScaled18;
    uint256[] private _decimalScalingFactors;
    uint256[] private _tokenRates;

    constructor(string memory name_) {
        name = name_;
    }

    function addToken(address token, uint256 balanceLiveScaled18, uint256 decimalScalingFactor, uint256 tokenRate)
        external
    {
        _tokens.push(token);
        _balancesLiveScaled18.push(balanceLiveScaled18);
        _decimalScalingFactors.push(decimalScalingFactor);
        _tokenRates.push(tokenRate);
    }

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function getStablePoolDynamicData() external view returns (IStablePool.StablePoolDynamicData memory data) {
        data.balancesLiveScaled18 = _balancesLiveScaled18;
        data.tokenRates = _tokenRates;
        data.totalSupply = _totalSupply;
    }

    function getStablePoolImmutableData() external view returns (IStablePool.StablePoolImmutableData memory data) {
        IERC20[] memory tokens = new IERC20[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokens[i] = IERC20(_tokens[i]);
        }
        data.tokens = tokens;
        data.decimalScalingFactors = _decimalScalingFactors;
    }
}

/// @notice Minimal Balancer Minter mock. BAL token + minted accounting; `getBalancerTokenAdmin` returns a dummy.
contract MockBalancerMinter {
    address public bal;
    mapping(address => mapping(address => uint256)) private _minted;

    constructor(address bal_) {
        bal = bal_;
    }

    function getBalancerToken() external view returns (address) {
        return bal;
    }

    function getBalancerTokenAdmin() external view returns (address) {
        return address(this);
    }

    function minted(address user, address gauge) external view returns (uint256) {
        return _minted[user][gauge];
    }

    function setMinted(address user, address gauge, uint256 amount) external {
        _minted[user][gauge] = amount;
    }
}

/// @notice Minimal Balancer V3 gauge mock: staking balances, an LP token, and extra reward tokens. It deliberately
///         omits the inflation-accounting surface (`period()` et al.) so the adapters' BAL claimable computation
///         reverts and is caught — yielding 0 BAL in unit tests. The real BAL math is fork-tested.
contract MockBalancerGauge {
    address private _lpToken;
    mapping(address => uint256) public balanceOf;
    address[] private _rewardTokens;
    mapping(address => mapping(address => uint256)) private _claimable;

    constructor(address lpToken_) {
        _lpToken = lpToken_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address) {
        return _lpToken;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function addRewardToken(address token) external {
        _rewardTokens.push(token);
    }

    function setClaimable(address account, address token, uint256 amount) external {
        _claimable[account][token] = amount;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function reward_count() external view returns (uint256) {
        return _rewardTokens.length;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function reward_tokens(uint256 i) external view returns (address) {
        return _rewardTokens[i];
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function claimable_reward(address user, address token) external view returns (uint256) {
        return _claimable[user][token];
    }
}
