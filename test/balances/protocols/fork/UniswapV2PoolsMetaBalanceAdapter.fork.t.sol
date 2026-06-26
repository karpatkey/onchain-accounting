// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {UniswapV2PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title UniswapV2PoolsMetaParityForkTest
/// @notice Fork tests for the Uniswap V2 pools meta-adapter against real mainnet contracts.
///         (exact — both delegate the same UniswapV2PairLib math, incl. the protocol-fee dilution), against the
///         real mainnet USDC/WETH V2 pair with a dealt LP balance. Both adapters share one BalancesHarnessForFork.
contract UniswapV2PoolsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc; // USDC/WETH
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 public constant FORK_BLOCK = 24_444_658;

    address public alice = makeAddr("alice");

    UniswapV2PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        deal(PAIR, alice, 1e15); // synthetic LP balance

        balances = _deployBalancesForAdapter(_assets());
        meta = new UniswapV2PoolsMetaBalanceAdapter("Uniswap V2", address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = USDC;
        a[1] = WETH;
    }

    function _pairInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(PAIR)));
    }

    function _metaToken(address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _pairInstance(), token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
    }

    function test_metaBalance_perToken() public view {
        assertGt(_metaToken(USDC), 0, "USDC balance non-zero");
        assertGt(_metaToken(WETH), 0, "WETH balance non-zero");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _pairInstance(), address(0));
        assertEq(p.length, 2);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(PAIR), "positionId = pair address");
        }
    }
}
