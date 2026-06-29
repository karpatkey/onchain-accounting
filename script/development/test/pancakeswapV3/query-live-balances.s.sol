// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {
    PancakeSwapV3PoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsAssistedBalanceAdapter.sol";
import {INonfungiblePositionManager} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title QueryPancakeV3LiveBalances
/// @notice Ad-hoc evidence helper: forks Ethereum at the pinned block, deploys the PancakeSwap V3 assisted adapter
///         pointed at a minimal Balances harness, seeds the verification holder's NFT tokenIds (discovered via the
///         NPM's ERC721Enumerable surface), and prints the per-leg breakdown the adapter emits. Used to capture the
///         exact amounts documented in this folder's README and to cross-check against the PancakeSwap UI / a
///         portfolio tracker.
/// @dev The adapter only reports a token leg if that token is registered on its NAVCalculator (asset registry).
///      So point this at the dev anvil RPC, where deploy.sh has stood up a NAV proxy with WETH/USDT registered,
///      and pass that proxy as DEV_NAV_PROXY:
///        DEV_NAV_PROXY=<dev NAV proxy> forge script \
///          script/development/test/pancakeswapV3/query-live-balances.s.sol:QueryPancakeV3LiveBalances \
///          --rpc-url http://127.0.0.1:8545 -vv
///      For a registry-free dump at an exact archive block, read getAdapterPositions in the fork test
///      (test/balances/AssistedBalanceAdapters/fork/PancakeSwapV3PoolsAssistedBalanceAdapter.fork.t.sol), which deploys its
///      own Balances harness.
contract QueryPancakeV3LiveBalances is Script {
    address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant HOLDER = 0x783C3255340f8Ba524452A9BE5d12a77e9Ce1F53;

    function run() public {
        // navCalculator arg is only used as the asset registry; pass the address provided via env (a deployed
        // NAVCalculator on the fork) so _getAssetInfo resolves WETH/USDT.
        address nav = vm.envAddress("DEV_NAV_PROXY");
        // admin + assistant = this script, so it can submit the holder's tokenIds below.
        PancakeSwapV3PoolsAssistedBalanceAdapter adapter =
            new PancakeSwapV3PoolsAssistedBalanceAdapter(NPM, "PancakeSwap V3", nav, address(this), address(this));

        // Discover the holder's NFT tokenIds off the NPM's ERC721Enumerable surface and feed them to the adapter.
        uint256 bal = INonfungiblePositionManager(NPM).balanceOf(HOLDER);
        uint256[] memory tokenIds = new uint256[](bal);
        for (uint256 i = 0; i < bal; i++) {
            tokenIds[i] = INonfungiblePositionManager(NPM).tokenOfOwnerByIndex(HOLDER, i);
        }
        if (tokenIds.length > 0) adapter.submitTokenIds(HOLDER, tokenIds);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        console2.log("legs:", p.length);
        for (uint256 i = 0; i < p.length; i++) {
            console2.log("---");
            console2.log("  asset:  ", p[i].balanceAsset.symbol);
            console2.log("  amount: ", p[i].amount);
            console2.log("  kind:   ", uint256(p[i].positionKind));
            (, uint256 tokenId) = abi.decode(p[i].positionId, (address, uint256));
            console2.log("  tokenId:", tokenId);
        }
    }
}
