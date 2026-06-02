// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Mock contracts extracted from UniswapV2.t.sol for use by UniswapV2PoolsMeta.t.sol

/// @notice Minimal Uniswap V2 factory mock — settable `feeTo()`.
contract MockUniswapV2Factory {
    address public feeTo;

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }
}

/// @notice Minimal Uniswap V2 pair mock — settable reserves/supply/balances/kLast.
contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    address public factory;
    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;
    uint256 public totalSupply;
    uint256 public kLast;
    mapping(address => uint256) public balanceOf;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
    }

    function setReserves(uint112 r0, uint112 r1) external {
        _reserve0 = r0;
        _reserve1 = r1;
        _blockTimestampLast = uint32(block.timestamp);
    }

    function setTotalSupply(uint256 ts) external {
        totalSupply = ts;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setKLast(uint256 k) external {
        kLast = k;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }
}

/// @notice ERC20-ish stub providing only what the adapter looks at via the registry path.
contract MockToken {
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}
