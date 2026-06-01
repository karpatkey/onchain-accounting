// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";
import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
/// @title UniswapV3PoolsMetaParityForkTest
/// @notice Proves the Uniswap V3 pools meta-adapter reproduces the per-instance UniswapV3PoolBalanceOracle per token
///         (exact — both delegate the same UniswapV3PoolLib math), against the real mainnet WBTC/WETH 0.3% pool and
///         a real NFT holder. Both adapters share one BalancesHarnessForFork registry.
contract UniswapV3PoolsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // WBTC/WETH 0.3%
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;
    uint256 public constant FORK_BLOCK = 24_987_608;

    UniswapV3PoolBalanceOracle public per;
    UniswapV3PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForOracle(_assets());
        per = new UniswapV3PoolBalanceOracle(POOL, NPM, address(balances));
        meta = new UniswapV3PoolsMetaBalanceAdapter(NPM, "Uniswap V3", address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = WBTC;
        a[1] = WETH;
    }

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    function _metaToken(address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(HOLDER, _poolInstance(), token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
    }

    function test_parity_perToken() public view {
        (uint256 perWbtc,) = per.getOracleBalanceForAsset(HOLDER, WBTC);
        (uint256 perWeth,) = per.getOracleBalanceForAsset(HOLDER, WETH);
        assertEq(_metaToken(WBTC), perWbtc, "WBTC parity");
        assertEq(_metaToken(WETH), perWeth, "WETH parity");
        assertTrue(perWbtc > 0 || perWeth > 0, "holder should have a non-zero position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(HOLDER, _poolInstance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            (address npm, uint256 tokenId) = abi.decode(p[i].positionId, (address, uint256));
            assertEq(npm, NPM, "positionId[0] = NonfungiblePositionManager");
            assertGt(tokenId, 0, "positionId[1] = non-zero tokenId");
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
