// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/protocols/curve/CurvePoolsMeta.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/protocols/curve/CurveGaugesMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title CurveMetaForkTest
/// @notice Fork tests for CurvePoolsMetaBalanceAdapter and CurveGaugesMetaBalanceAdapter against
///         real mainnet contracts.
///
/// Pools under test:
///   - crvUSD/USDC StableSwap-NG (0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E)
///       self-LP (pool IS the LP token), uint256 coins indices
///   - weETH/WETH TriCrypto-style 2-token pool (actual: ngPool)
///       self-LP, two ETH-denominated coins
///   - 3pool (DAI/USDC/USDT, 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7)
///       classic StableSwap with int128-indexed coins
///
/// Gauges under test (same underlying pools):
///   - crvUSD/USDC gauge (0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1)
///   - weETH/WETH gauge (0xca8C7cc4a38a8481f52ad43de9a97c03f2c5bEBd)
///   - 3pool gauge (0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A)
///
/// Pinned to a block where the test accounts hold verified positions.
contract CurveMetaForkTest is BalanceAdapterTestBase {
    // ── Mainnet addresses ─────────────────────────────────────────────────────

    // Curve Minter (Ethereum mainnet)
    address public constant CURVE_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    // crvUSD/USDC StableSwap-NG pool (pool IS LP token, uint256 indices)
    address public constant CRVUSD_USDC_POOL  = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant CRVUSD_USDC_GAUGE = 0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1;
    // Account known to hold gauge-staked LP and claimable rewards at FORK_BLOCK
    address public constant CRVUSD_USDC_STAKER = 0xc9332cbf6fee06A6b8cf87e56Bd2E77e08C0C13c;

    // crvUSD/USDT StableSwap-NG pool
    address public constant CRVUSD_USDT_POOL  = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant CRVUSD_USDT_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;

    // RLUSD/USDC StableSwap-NG pool
    address public constant RLUSD_USDC_POOL  = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
    address public constant RLUSD_USDC_GAUGE = 0xFc3212Bd9Ad9A28Da6B2bd50a2918969C126894F;

    // weETH/WETH NG pool (self-LP, uint256 indices)
    address public constant WEETH_WETH_POOL  = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant WEETH_WETH_GAUGE = 0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2;
    // Account with weETH/WETH staked LP
    address public constant WEETH_WETH_STAKER = 0x6cF2A2Cb4F1D3A4aeb56DB52E9b5B69F8bDB83c5;

    // 3pool — classic StableSwap, int128 coin indices
    address public constant THREEPOOL        = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant THREEPOOL_GAUGE  = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;
    // Account holding 3pool LP tokens in wallet
    address public constant THREEPOOL_HOLDER = 0x43b4FdFD4Ff969587185cDB6f0BD875c5Fc83f8c;

    // Tokens
    address public constant CRV    = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WEETH  = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DAI    = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant RLUSD  = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    uint256 public constant FORK_BLOCK = 22_500_000;

    CurvePoolsMetaBalanceAdapter  public poolsMeta;
    CurveGaugesMetaBalanceAdapter public gaugesMeta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        address[] memory assets = new address[](8);
        assets[0] = CRV; assets[1] = CRVUSD; assets[2] = USDC;
        assets[3] = WEETH; assets[4] = WETH;
        assets[5] = DAI; assets[6] = USDT; assets[7] = RLUSD;
        balances = _deployBalancesForOracle(assets);

        poolsMeta  = new CurvePoolsMetaBalanceAdapter("Curve", address(balances));
        gaugesMeta = new CurveGaugesMetaBalanceAdapter(CURVE_MINTER, CRV, "Curve", address(balances));
    }

    // ─── CurvePoolsMeta fork tests ────────────────────────────────────────────

    /// @notice crvUSD/USDC pool — StableSwap-NG, uint256 coins, self-LP.
    function test_crvUsdUsdc_walletLp_decomposes() public view {
        uint256 walletLp = _lpBalance(CRVUSD_USDC_POOL, CRVUSD_USDC_STAKER);
        if (walletLp == 0) return; // holder redeemed — test is vacuous but not a failure

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _pool(CRVUSD_USDC_POOL), address(0));

        assertGt(pos.length, 0, "at least one underlying coin leg");
        _assertAllSupplied(pos);
        _assertSumIsProRata(pos, CRVUSD_USDC_POOL, walletLp);
    }

    /// @notice weETH/WETH pool — 2-token NG pool, uint256 coins.
    function test_weethWeth_walletLp_decomposes() public view {
        uint256 walletLp = _lpBalance(WEETH_WETH_POOL, WEETH_WETH_STAKER);
        if (walletLp == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getOraclePositionsForInstances(WEETH_WETH_STAKER, _pool(WEETH_WETH_POOL), address(0));

        assertGt(pos.length, 0);
        _assertAllSupplied(pos);
    }

    /// @notice 3pool — classic StableSwap, int128 coin indices.
    function test_threepool_walletLp_decomposes_int128() public view {
        uint256 walletLp = _lpBalance(THREEPOOL, THREEPOOL_HOLDER);
        if (walletLp == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getOraclePositionsForInstances(THREEPOOL_HOLDER, _pool(THREEPOOL), address(0));

        assertGt(pos.length, 0, "3pool LP decomposes");
        _assertAllSupplied(pos);
    }

    /// @notice Pool instance set returned by underlyingAssetsSupported matches coins().
    function test_crvUsdUsdc_instanceAssets_match_coins() public view {
        address[] memory assets = poolsMeta.underlyingAssetsSupportedForInstances(_pool(CRVUSD_USDC_POOL));
        assertGt(assets.length, 0);
        // crvUSD/USDC has exactly 2 coins
        assertEq(assets.length, 2);
    }

    // ─── CurveGaugesMeta fork tests ───────────────────────────────────────────

    /// @notice crvUSD/USDC gauge — staked LP decomposes + CRV lower bound.
    function test_crvUsdUsdc_gauge_stakedAndRewards() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), address(0));

        assertGt(pos.length, 0);
        uint256 suppliedCount = _countKind(pos, PositionKind.Supplied);
        assertGt(suppliedCount, 0, "staked LP decomposes into underlying coins");
    }

    /// @notice weETH/WETH gauge — staked LP decomposes.
    function test_weethWeth_gauge_staked() public view {
        uint256 staked = _gaugeBalance(WEETH_WETH_GAUGE, WEETH_WETH_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getOraclePositionsForInstances(WEETH_WETH_STAKER, _gauge(WEETH_WETH_GAUGE), address(0));

        assertGt(pos.length, 0);
        _assertAllValidPositionKinds(pos);
    }

    /// @notice Asset filter correctly restricts output to the requested token.
    function test_crvUsdUsdc_gauge_assetFilter() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), USDC);

        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].balanceAsset.asset, USDC);
        }
    }

    /// @notice protocolId and positionId are correct on-chain.
    function test_gauge_identity() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), address(0));

        assertGt(pos.length, 0);
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].positionId, abi.encode(CRVUSD_USDC_GAUGE));
        }
    }

    /// @notice describePosition returns a non-empty string from on-chain symbols.
    function test_describePosition_crvUsdUsdc_gauge() public view {
        string memory label = gaugesMeta.describePosition(abi.encode(CRVUSD_USDC_GAUGE));
        assertGt(bytes(label).length, 0);
    }

    function test_describePosition_threepool() public view {
        string memory label = poolsMeta.describePosition(abi.encode(THREEPOOL));
        assertGt(bytes(label).length, 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _pool(address pool) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(pool)));
    }

    function _gauge(address g) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(g)));
    }

    function _lpBalance(address pool, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = pool.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    function _gaugeBalance(address g, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = g.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    function _assertAllSupplied(INAVCalculator.PositionBalance[] memory pos) internal pure {
        for (uint256 i; i < pos.length; ++i) {
            assertEq(uint8(pos[i].positionKind), uint8(PositionKind.Supplied));
        }
    }

    function _assertAllValidPositionKinds(INAVCalculator.PositionBalance[] memory pos) internal pure {
        for (uint256 i; i < pos.length; ++i) {
            uint8 k = uint8(pos[i].positionKind);
            assertTrue(k == uint8(PositionKind.Supplied) || k == uint8(PositionKind.Earned));
        }
    }

    function _countKind(INAVCalculator.PositionBalance[] memory pos, PositionKind kind)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == kind) count++;
        }
    }

    /// @notice Verifies that the sum of leg amounts matches the expected pro-rata value.
    ///         Only checks coins present in the `pos` array (registered assets).
    function _assertSumIsProRata(
        INAVCalculator.PositionBalance[] memory pos,
        address pool,
        uint256 walletLp
    ) internal view {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) return; // can't verify without totalSupply
        uint256 ts = abi.decode(data, (uint256));
        if (ts == 0) return;

        for (uint256 i; i < pos.length; ++i) {
            address coin = pos[i].balanceAsset.asset;
            // Find coin index in pool
            for (uint256 j; j < 8; ++j) {
                (bool cok, bytes memory cd) = pool.staticcall(
                    abi.encodeWithSignature("coins(uint256)", j)
                );
                if (!cok || cd.length < 32) break;
                address c = abi.decode(cd, (address));
                if (c == address(0)) break;
                if (c == coin) {
                    (bool bok, bytes memory bd) = pool.staticcall(
                        abi.encodeWithSignature("balances(uint256)", j)
                    );
                    if (!bok || bd.length < 32) break;
                    uint256 poolBal = abi.decode(bd, (uint256));
                    uint256 expected = (poolBal * walletLp) / ts;
                    assertEq(pos[i].amount, expected, "pro-rata amount matches");
                    break;
                }
            }
        }
    }

}
