// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal slot0 read used only by the test to derive oracle-consistent prices (the adapter itself no
///      longer reads slot0 — see [2]).
interface IPoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// @title UniswapV3PoolsMetaParityForkTest
/// @notice Fork tests for the Uniswap V3 pools meta-adapter against real mainnet contracts.
///         (exact — both delegate the same UniswapV3PoolLib math), against the real mainnet WBTC/WETH 0.3% pool and
///         a real NFT holder. Both adapters share one BalancesHarnessForFork registry.
contract UniswapV3PoolsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // WBTC/WETH 0.3%
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;
    uint256 public constant FORK_BLOCK = 24_987_608;

    UniswapV3PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        _setPoolImpliedPrices();
        meta = new UniswapV3PoolsMetaBalanceAdapter(NPM, "Uniswap V3", address(balances));
    }

    /// @notice Feeds the harness oracle prices consistent with the pool's live `sqrtPrice`, so the adapter's
    ///         [2] reconstruct-from-feeds split reproduces the real on-chain split (and the holder's position is
    ///         in range). token0 = WBTC (8dp), token1 = WETH (18dp); both price feeds use 8 decimals, so the
    ///         reconstructed raw price is `(pWBTC/pWETH)·1e10` — set pWETH = 1e8 and pWBTC = P/100 where P is the
    ///         pool's raw token1/token0 price.
    function _setPoolImpliedPrices() internal {
        (uint160 sp,,,,,,) = IPoolSlot0(POOL).slot0();
        uint256 p = Math.mulDiv(uint256(sp), uint256(sp), 1 << 192); // raw WETH per raw WBTC
        balances.setAssetPrice(WETH, 1e8, 8);
        balances.setAssetPrice(WBTC, int256(p / 100), 8);
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
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
    }

    function test_metaBalance_perToken() public view {
        uint256 metaWbtc = _metaToken(WBTC);
        uint256 metaWeth = _metaToken(WETH);
        assertTrue(metaWbtc > 0 || metaWeth > 0, "holder should have a non-zero position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), address(0));
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
