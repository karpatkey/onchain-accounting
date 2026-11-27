// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions, ParameterType, Op} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";

interface INonfungiblePositionManagerMin {
    function ownerOf(uint256 tokenId) external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IUniswapV3PoolMin {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IUniswapV3FactoryMin {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IRolesAvatarMin {
    function avatar() external view returns (address);
}

/// @notice Position module for Uniswap V3 LP NFTs of one pool (`UniswapV3PoolsMetaBalanceAdapter`).
/// @dev Instance = pool address widened to bytes32. The module is also the Roles v2 `Custom` condition that binds
///      an existing tokenId to the fund: `ownerOf(tokenId) == avatar` AND the token's pool (from `positions`, via
///      `factory.getPool`) is this instance's pool. The pool binding rides in the 12-byte `extra` of the compValue
///      (`bytes12(uint96(uint160(pool)))`): a 20-byte pool address does not fit, and the low 96 bits are checked
///      against the pool the NFT actually belongs to, so a Safe-owned NFT of an undeclared pool is not actionable.
contract UniswapV3LpModule is IPositionModule {
    error InvalidInstance(bytes32 instance);

    bytes32 public constant MODULE_ID = keccak256("uniswap-v3-pools");

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_MINT =
        bytes4(keccak256("mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))"));
    bytes4 private constant SEL_INCREASE =
        bytes4(keccak256("increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))"));
    bytes4 private constant SEL_DECREASE = bytes4(keccak256("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))"));
    bytes4 private constant SEL_COLLECT = bytes4(keccak256("collect((uint256,address,uint128,uint128))"));

    /// @dev Roles v2 `Operator.Custom` (CoreTypes.sol, index 22); not exported by vendor/RolesV2.sol.
    uint8 private constant OP_CUSTOM = 22;

    /// @notice Meta adapter that values this module's positions.
    address public immutable ADAPTER;
    /// @notice NonfungiblePositionManager (mainnet 0xC36442b4a4522E871399CD717aBDD847Ab11FE88).
    address public immutable NPM;
    /// @notice Uniswap V3 factory (mainnet 0x1F98431c8aD98523631AE4a59f267346ea31F984).
    address public immutable FACTORY;

    constructor(address adapter_, address npm_, address factory_) {
        ADAPTER = adapter_;
        NPM = npm_;
        FACTORY = factory_;
    }

    /// @inheritdoc IPositionModule
    function moduleId() external pure returns (bytes32) {
        return MODULE_ID;
    }

    /// @inheritdoc IPositionModule
    function validate(bytes32 instance) external view {
        _pool(instance);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address pool = _pool(instance);
        address t0 = IUniswapV3PoolMin(pool).token0();
        address t1 = IUniswapV3PoolMin(pool).token1();
        uint24 fee = IUniswapV3PoolMin(pool).fee();
        bytes memory binding = abi.encodePacked(address(this), _poolExtra(pool));

        leaves = new PermissionLeaf[](6);
        leaves[0] = PermissionLeaf({
            target: t0,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(NPM), Cond.pass()),
            options: ExecutionOptions.Send
        });
        leaves[1] = PermissionLeaf({
            target: t1,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(NPM), Cond.pass()),
            options: ExecutionOptions.Send
        });
        leaves[2] = PermissionLeaf({
            target: NPM,
            selector: SEL_MINT,
            conditions: _tuple(_mintFields(t0, t1, fee)),
            options: ExecutionOptions.Send
        });
        leaves[3] = PermissionLeaf({
            target: NPM,
            selector: SEL_INCREASE,
            conditions: _tuple(_customFirst(binding, 5)),
            options: ExecutionOptions.Send
        });
        leaves[4] = PermissionLeaf({
            target: NPM,
            selector: SEL_DECREASE,
            conditions: _tuple(_customFirst(binding, 4)),
            options: ExecutionOptions.Send
        });
        leaves[5] = PermissionLeaf({
            target: NPM,
            selector: SEL_COLLECT,
            conditions: _tuple(_collectFields(binding)),
            options: ExecutionOptions.Send
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        return Accounting({adapter: ADAPTER, isMeta: true, coordinate: instance, assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external view returns (address[] memory out) {
        address pool = _pool(instance);
        out = new address[](2);
        out[0] = IUniswapV3PoolMin(pool).token0();
        out[1] = IUniswapV3PoolMin(pool).token1();
    }

    /// @notice Roles `Custom` condition, in the 7-argument form the deployed Roles mastercopy (0x9646…, selector
    ///         0xb0acb980) calls. The clone (`msg.sender`) passes the calldata slice of the constrained `uint256 tokenId`
    ///         (`location`, `size`). Passes iff the NFT is owned by the Roles avatar and belongs to the pool in `extra`.
    function check(address to, uint256, bytes calldata data, uint8, uint256 location, uint256 size, bytes12 extra)
        external
        view
        returns (bool, bytes32)
    {
        if (to != NPM || size != 32) return (false, bytes32(0));
        uint256 tokenId = abi.decode(data[location:location + 32], (uint256));

        try INonfungiblePositionManagerMin(NPM).ownerOf(tokenId) returns (address owner) {
            if (owner != IRolesAvatarMin(msg.sender).avatar()) return (false, bytes32(0));
        } catch {
            return (false, bytes32(0));
        }

        (,, address t0, address t1, uint24 fee,,,,,,,) = INonfungiblePositionManagerMin(NPM).positions(tokenId);
        address pool = IUniswapV3FactoryMin(FACTORY).getPool(t0, t1, fee);
        return (pool != address(0) && _poolExtra(pool) == extra, bytes32(0));
    }

    function _pool(bytes32 instance) internal view returns (address pool) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        pool = address(uint160(uint256(instance)));
        if (IUniswapV3PoolMin(pool).factory() != FACTORY) revert InvalidInstance(instance);
    }

    function _poolExtra(address pool) internal pure returns (bytes12) {
        return bytes12(uint96(uint160(pool)));
    }

    /// @dev Calldata-matching tree whose only argument is a static tuple with `fields` as its members, in order.
    function _tuple(ConditionFlat[] memory fields) private pure returns (ConditionFlat[] memory out) {
        out = new ConditionFlat[](fields.length + 2);
        out[0] = ConditionFlat(0, ParameterType.Calldata, Op.MATCHES, "");
        out[1] = ConditionFlat(0, ParameterType.Tuple, Op.MATCHES, "");
        for (uint256 i; i < fields.length; ++i) {
            out[i + 2] = ConditionFlat(1, fields[i].paramType, fields[i].operator, fields[i].compValue);
        }
    }

    /// @dev MintParams: token0, token1, fee, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min,
    ///      amount1Min, recipient, deadline.
    function _mintFields(address t0, address t1, uint24 fee) private pure returns (ConditionFlat[] memory f) {
        f = new ConditionFlat[](11);
        f[0] = Cond.equalTo(t0);
        f[1] = Cond.equalTo(t1);
        f[2] = ConditionFlat(0, ParameterType.Static, Op.EQUAL_TO, abi.encode(uint256(fee)));
        f[3] = Cond.pass();
        f[4] = Cond.pass();
        f[5] = Cond.pass();
        f[6] = Cond.pass();
        f[7] = Cond.pass();
        f[8] = Cond.pass();
        f[9] = Cond.equalToAvatar();
        f[10] = Cond.pass();
    }

    /// @dev tokenId constrained by Custom, followed by `rest` unconstrained static members.
    function _customFirst(bytes memory binding, uint256 rest) private pure returns (ConditionFlat[] memory f) {
        f = new ConditionFlat[](rest + 1);
        f[0] = ConditionFlat(0, ParameterType.Static, OP_CUSTOM, binding);
        for (uint256 i = 1; i <= rest; ++i) {
            f[i] = Cond.pass();
        }
    }

    /// @dev CollectParams: tokenId (Custom), recipient (EqualToAvatar), amount0Max, amount1Max.
    function _collectFields(bytes memory binding) private pure returns (ConditionFlat[] memory f) {
        f = new ConditionFlat[](4);
        f[0] = ConditionFlat(0, ParameterType.Static, OP_CUSTOM, binding);
        f[1] = Cond.equalToAvatar();
        f[2] = Cond.pass();
        f[3] = Cond.pass();
    }
}
