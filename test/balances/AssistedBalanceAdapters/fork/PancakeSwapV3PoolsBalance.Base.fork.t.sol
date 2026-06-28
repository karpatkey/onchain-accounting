// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    PancakeSwapV3PoolsBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsBalanceAdapter.sol";
import {INonfungiblePositionManager} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title PancakeSwapV3PoolsBalanceForkTest (Base)
/// @notice Validates the PancakeSwap V3 pools assisted adapter against the real Base WETH/COW 0.25% pool. The
///         holder's position here is closed (liquidity 0 and no settled `tokensOwed`), so the adapter returns zero
///         amounts; the assertion is that the call succeeds and yields zero without reverting. ADR 0017: the adapter
///         reads the pool's live `slot0`, and the PancakeSwap `_slot0` override must decode the real Base PCS pool's
///         `uint32 feeProtocol` (the inherited `uint8` decode would revert), so even a zero-amount valuation
///         exercises that override. The holder's NFT tokenIds are discovered off the NPM and fed via
///         `submitTokenIds` (as the assistant would).
contract PancakeSwapV3PoolsBalanceForkTest_Base is BalanceAdapterTestBase {
    address public constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_COW = 0xc694a91e6b071bF030A18BD3053A7fE09B6DaE69;
    address public constant HOLDER = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    uint256 public constant FORK_BLOCK = 45_520_000;

    PancakeSwapV3PoolsBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        adapter = new PancakeSwapV3PoolsBalanceAdapter(
            NPM, "PancakeSwap V3", address(balances), address(this), address(this)
        );
        _submitHolderTokenIds();
    }

    function _submitHolderTokenIds() internal {
        uint256 bal = INonfungiblePositionManager(NPM).balanceOf(HOLDER);
        uint256[] memory ids = new uint256[](bal);
        for (uint256 i = 0; i < bal; i++) {
            ids[i] = INonfungiblePositionManager(NPM).tokenOfOwnerByIndex(HOLDER, i);
        }
        if (ids.length > 0) adapter.submitTokenIds(HOLDER, ids);
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

    /// @notice The adapter values the holder's submitted NFTs without reverting (decoding the real PCS pool's uint32
    ///         feeProtocol via the `_slot0` override): the closed WETH/COW position yields zero amounts.
    function test_closedPosition_noRevert() public view {
        uint256 weth;
        uint256 cow;
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == BASE_WETH) weth += p[i].amount;
            if (p[i].balanceAsset.asset == BASE_COW) cow += p[i].amount;
        }
        // holder's position is closed (liquidity 0, no settled tokensOwed) — amounts are zero, the key assertion is
        // that the live-slot0 read + uint32 feeProtocol decode do not revert.
        assertEq(weth, 0, "WETH (closed position)");
        assertEq(cow, 0, "COW (closed position)");
    }
}
