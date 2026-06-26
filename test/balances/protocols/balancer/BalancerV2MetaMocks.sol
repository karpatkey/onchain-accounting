// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Minimal Balancer V2 Vault mock: stores a poolId -> (tokens, balances) mapping and returns it from
///         `getPoolTokens`, mirroring the single-Vault custody model the V2 meta-adapters read through.
contract MockV2Vault {
    mapping(bytes32 => address[]) private _tokens;
    mapping(bytes32 => uint256[]) private _balances;

    function setPool(bytes32 poolId, address[] memory tokens, uint256[] memory balances) external {
        _tokens[poolId] = tokens;
        _balances[poolId] = balances;
    }

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock)
    {
        return (_tokens[poolId], _balances[poolId], 0);
    }
}

/// @notice Minimal Balancer V2 pool (BPT) mock: ERC20 name/balanceOf/totalSupply, an optional `getActualSupply`
///         (composable-stable pools only — toggled off so the adapter falls back to totalSupply), and getPoolId.
contract MockV2Pool {
    string public name;
    uint256 private _totalSupply;
    uint256 private _actualSupply;
    bool private _hasActualSupply;
    bytes32 private _poolId;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, bytes32 poolId_) {
        name = name_;
        _poolId = poolId_;
    }

    function getPoolId() external view returns (bytes32) {
        return _poolId;
    }

    function setPoolId(bytes32 poolId_) external {
        _poolId = poolId_;
    }

    function setTotalSupply(uint256 s) external {
        _totalSupply = s;
    }

    function setActualSupply(uint256 s) external {
        _actualSupply = s;
        _hasActualSupply = true;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @dev Reverts when not set, so the adapter's try/catch falls back to `totalSupply()` (legacy pools).
    function getActualSupply() external view returns (uint256) {
        require(_hasActualSupply, "no actual supply");
        return _actualSupply;
    }
}
