// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions, Op, ParameterType} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @notice Single-hop Uniswap V3 swaps through one pool, on behalf of the fund Safe.
/// @dev One module per router. Instance = Uniswap V3 pool address widened to bytes32. The pool fixes the pair and the
///      fee; `validate` checks the pool is the factory's canonical pool for them, so the declared pair cannot be a
///      look-alike. Permissions:
///      - `approve(token0 | token1 -> router)`,
///      - `exactInputSingle((tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96))` for
///        both directions, with `tokenIn`/`tokenOut` pinned to the pair, `fee` pinned, `recipient` = the Safe.
///      Value: the swap holds no position. Both tokens are `assets()`, so the Safe's balances of them count in NAV.
///
///      Limitations: multi-hop `exactInput` is not permitted (its path is not a fixed pair); a swap is valued at
///      spot only through the NAV's pricing, with no slippage or execution-price check beyond `amountOutMinimum`
///      chosen by the caller.
contract SwapModule is IPositionModule {
    error InvalidInstance(bytes32 instance);
    error UnknownPool(address pool);

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_EXACT_INPUT_SINGLE =
        bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"));

    bytes32 public immutable MODULE_ID;

    /// @notice Swap router the Safe approves and calls (Uniswap V3 SwapRouter02).
    address public immutable ROUTER;

    /// @notice Uniswap V3 factory that canonically defines the pools this module accepts.
    IUniswapV3Factory public immutable FACTORY;

    /// @notice Balance adapter that reports no positions (see `NoPositionAdapter`).
    address public immutable ADAPTER;

    constructor(bytes32 moduleId_, address router_, address factory_, address adapter_) {
        MODULE_ID = moduleId_;
        ROUTER = router_;
        FACTORY = IUniswapV3Factory(factory_);
        ADAPTER = adapter_;
    }

    /// @inheritdoc IPositionModule
    function moduleId() external view returns (bytes32) {
        return MODULE_ID;
    }

    /// @inheritdoc IPositionModule
    function validate(bytes32 instance) external view {
        address pool = _pool(instance);
        (address t0, address t1, uint24 fee) = _pair(pool);
        if (FACTORY.getPool(t0, t1, fee) != pool) revert UnknownPool(pool);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address pool = _pool(instance);
        (address t0, address t1, uint24 fee) = _pair(pool);

        leaves = new PermissionLeaf[](4);
        leaves[0] = _approve(t0);
        leaves[1] = _approve(t1);
        leaves[2] = _exactInputSingle(t0, t1, fee);
        leaves[3] = _exactInputSingle(t1, t0, fee);
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        _pool(instance);
        return Accounting({adapter: ADAPTER, isMeta: false, coordinate: bytes32(0), assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external view returns (address[] memory out) {
        (address t0, address t1,) = _pair(_pool(instance));
        out = new address[](2);
        out[0] = t0;
        out[1] = t1;
    }

    function _approve(address token) internal view returns (PermissionLeaf memory) {
        return PermissionLeaf({
            target: token,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(ROUTER), Cond.pass()),
            options: ExecutionOptions.Send
        });
    }

    function _exactInputSingle(address tokenIn, address tokenOut, uint24 fee)
        internal
        view
        returns (PermissionLeaf memory)
    {
        return PermissionLeaf({
            target: ROUTER,
            selector: SEL_EXACT_INPUT_SINGLE,
            conditions: _exactInputSingleTree(tokenIn, tokenOut, fee),
            options: ExecutionOptions.Send
        });
    }

    /// @dev Condition tree for `exactInputSingle(ExactInputSingleParams)`. The single argument is a tuple, so the tree is
    ///      Calldata(0) -> Tuple(1) -> seven fields. Field order follows the struct: tokenIn, tokenOut, fee, recipient,
    ///      amountIn, amountOutMinimum, sqrtPriceLimitX96. Fields are children of the tuple node, so each carries parent 1.
    function _exactInputSingleTree(address tokenIn, address tokenOut, uint24 fee)
        internal
        pure
        returns (ConditionFlat[] memory out)
    {
        out = new ConditionFlat[](9);
        out[0] = ConditionFlat(0, ParameterType.Calldata, Op.MATCHES, "");
        out[1] = ConditionFlat(0, ParameterType.Tuple, Op.MATCHES, "");
        out[2] = _field(Cond.equalTo(tokenIn));
        out[3] = _field(Cond.equalTo(tokenOut));
        out[4] = _field(ConditionFlat(0, ParameterType.Static, Op.EQUAL_TO, abi.encode(uint256(fee))));
        out[5] = _field(Cond.equalToAvatar());
        out[6] = _field(Cond.pass());
        out[7] = _field(Cond.pass());
        out[8] = _field(Cond.pass());
    }

    /// @dev Re-parents a field condition under the tuple node (index 1).
    function _field(ConditionFlat memory c) private pure returns (ConditionFlat memory) {
        return ConditionFlat(1, c.paramType, c.operator, c.compValue);
    }

    function _pool(bytes32 instance) internal pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        return address(uint160(uint256(instance)));
    }

    function _pair(address pool) internal view returns (address t0, address t1, uint24 fee) {
        IUniswapV3PoolPair p = IUniswapV3PoolPair(pool);
        return (p.token0(), p.token1(), p.fee());
    }
}
