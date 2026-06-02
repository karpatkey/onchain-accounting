// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @notice Mock ERC20 token with symbol/decimals.
contract MockCurveToken {
    string public symbol;
    string public name;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        name = symbol_;
        decimals = decimals_;
        totalSupply = 1_000_000e18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @notice Mock Curve pool where the pool IS the LP token (classic StableSwap / TriCryptoNG pattern).
///         coins() uses uint256 indices.
contract MockCurvePool {
    address[] private _coins;
    mapping(uint256 => uint256) private _balances;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address[] memory coins_) {
        _coins = coins_;
        totalSupply = 1_000e18;
        for (uint256 i; i < coins_.length; ++i) {
            _balances[i] = 100_000e18; // default pool balance
        }
    }

    // Pool IS the LP token — no separate lp_token() method (or it would return address(0)/self)
    function coins(uint256 i) external view returns (address) {
        require(i < _coins.length, "out of range");
        return _coins[i];
    }

    function balances(uint256 i) external view returns (uint256) {
        return _balances[i];
    }

    function setPoolBalance(uint256 i, uint256 amount) external { _balances[i] = amount; }
    function setWalletBalance(address account, uint256 amount) external { balanceOf[account] = amount; }
    function setTotalSupply(uint256 ts) external { totalSupply = ts; }
}

/// @notice Mock Curve LP ERC20 (separate from pool, as in StableSwap-NG factory pools).
///         Exposes minter() returning the pool address.
contract MockCurveLpToken {
    address public minter; // points to the pool
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address pool_) {
        minter = pool_;
        totalSupply = 1_000e18;
    }

    /// @notice Allows fixing the minter after construction (needed to break circular reference in tests).
    function setMinter(address pool_) external { minter = pool_; }
    function setWalletBalance(address account, uint256 amount) external { balanceOf[account] = amount; }
    function setTotalSupply(uint256 ts) external { totalSupply = ts; }
}

/// @notice Mock Curve pool that has a SEPARATE LP token (StableSwap-NG factory style).
///         Returns the LP token from lp_token(), and has coins()/balances() for decomposition.
contract MockCurvePoolWithSeparateLp {
    address[] private _coins;
    mapping(uint256 => uint256) private _balances;
    address public lpToken;

    constructor(address[] memory coins_, address lpToken_) {
        _coins = coins_;
        lpToken = lpToken_;
        for (uint256 i; i < coins_.length; ++i) {
            _balances[i] = 100_000e18;
        }
    }

    // solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address) { return lpToken; }

    function coins(uint256 i) external view returns (address) {
        require(i < _coins.length, "out of range");
        return _coins[i];
    }

    function balances(uint256 i) external view returns (uint256) { return _balances[i]; }
    function setPoolBalance(uint256 i, uint256 amount) external { _balances[i] = amount; }
}

/// @notice Mock legacy StableSwap pool using int128 indices (Vyper 0.1.x style).
contract MockCurvePoolInt128 {
    address[] private _coins;
    mapping(uint256 => uint256) private _balances;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address[] memory coins_) {
        _coins = coins_;
        totalSupply = 1_000e18;
        for (uint256 i; i < coins_.length; ++i) _balances[i] = 100_000e18;
    }

    // int128 variant — will revert on uint256 call
    function coins(int128 i) external view returns (address) {
        require(i >= 0 && uint128(i) < _coins.length, "out of range");
        return _coins[uint128(i)];
    }

    function balances(int128 i) external view returns (uint256) {
        require(i >= 0, "neg");
        return _balances[uint128(i)];
    }

    function setWalletBalance(address account, uint256 amount) external { balanceOf[account] = amount; }
    function setTotalSupply(uint256 ts) external { totalSupply = ts; }
    function setPoolBalance(uint256 i, uint256 amount) external { _balances[i] = amount; }
}

/// @notice Mock Curve gauge (V3-style: reward_tokens + claimable_reward + lp_token).
contract MockCurveGauge {
    address private _lpToken;
    mapping(address => uint256) public balanceOf; // staked LP

    // CRV via integrate_fraction / minted pattern
    mapping(address => uint256) private _integrateFraction;

    // Extra rewards (reward_tokens + claimable_reward)
    address[] private _rewardTokens;
    mapping(address => mapping(address => uint256)) private _claimableReward; // token => account => amount

    constructor(address lpToken_) {
        _lpToken = lpToken_;
    }

    // solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address) { return _lpToken; }

    function setStaked(address account, uint256 amount) external { balanceOf[account] = amount; }

    // solhint-disable-next-line func-name-mixedcase
    function integrate_fraction(address account) external view returns (uint256) {
        return _integrateFraction[account];
    }

    function setIntegrateFraction(address account, uint256 amount) external {
        _integrateFraction[account] = amount;
    }

    function addRewardToken(address token) external { _rewardTokens.push(token); }

    // solhint-disable-next-line func-name-mixedcase
    function reward_tokens(uint256 i) external view returns (address) {
        if (i >= _rewardTokens.length) return address(0);
        return _rewardTokens[i];
    }

    // solhint-disable-next-line func-name-mixedcase
    function claimable_reward(address account, address token) external view returns (uint256) {
        return _claimableReward[token][account];
    }

    function setClaimableReward(address token, address account, uint256 amount) external {
        _claimableReward[token][account] = amount;
    }
}

/// @notice Mock Curve Minter (tracks minted CRV per (account, gauge)).
contract MockCurveMinter {
    mapping(address => mapping(address => uint256)) public minted; // account => gauge => minted

    function setMinted(address account, address gauge, uint256 amount) external {
        minted[account][gauge] = amount;
    }
}
