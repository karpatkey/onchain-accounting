// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {PancakeSwapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title PancakeSwapV3PoolsMetaParityForkTest (Base)
/// @notice Validates the PancakeSwap V3 pools meta-adapter against the real Base WETH/COW 0.25% pool. The key
///         check is that the `_slot0` override decodes PancakeSwap's `uint32 feeProtocol` (Uniswap's `uint8` read
///         would revert on a live PCS pool): the test holder has an NFT in this pool, so the slot0 read in
///         UniswapV3PoolLib is exercised. The holder's position is closed (liquidity 0), so amounts are zero —
///         the assertion is that the adapter returns empty without
///         reverting).
contract PancakeSwapV3PoolsMetaParityForkTest_Base is BalanceAdapterTestBase {
    address public constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address public constant POOL = 0xfe5291Ac7Ac2b81a40c0ba6980308212037828aF; // WETH/COW 0.25%
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_COW = 0xc694a91e6b071bF030A18BD3053A7fE09B6DaE69;
    address public constant HOLDER = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    uint256 public constant FORK_BLOCK = 45_520_000;

    PancakeSwapV3PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        meta = new PancakeSwapV3PoolsMetaBalanceAdapter(NPM, "PancakeSwap V3", address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = BASE_WETH;
        a[1] = BASE_COW;
    }

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    /// @notice The slot0 uint32-feeProtocol override decodes on a real PCS pool: the call succeeds (no revert).
    function test_slot0Override_noRevert() public view {
        uint256 metaWeth;
        uint256 metaCow;
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == BASE_WETH) metaWeth += p[i].amount;
            if (p[i].balanceAsset.asset == BASE_COW) metaCow += p[i].amount;
        }
        // holder's position is closed (liquidity 0), so amounts are zero — the key assertion is no revert.
        assertEq(metaWeth, 0, "WETH (closed position)");
        assertEq(metaCow, 0, "COW (closed position)");
    }
}
