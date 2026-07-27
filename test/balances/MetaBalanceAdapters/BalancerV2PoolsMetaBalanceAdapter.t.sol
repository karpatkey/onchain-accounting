// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockBalToken} from "./BalancerMetaMocks.sol";
import {MockV2Vault, MockV2Pool} from "./BalancerV2MetaMocks.sol";

/// @title BalancerV2PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Exercises the meta-framework behaviour and the wallet-BPT pro-rata math against a mock V2 Vault + BPT.
///         The instance coordinate is the raw 32-byte poolId (used directly, not widened from an address); the BPT
///         address is derived on-chain as the top 160 bits of the poolId — so the poolId here encodes the deployed
///         mock pool's address. Real composable-stable (getActualSupply) and live mainnet share math is fork-tested.
contract BalancerV2PoolsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockV2Vault vault;
    MockV2Pool pool;
    BalancerV2PoolsMetaBalanceAdapter adapter;

    MockBalToken tokenX;
    MockBalToken tokenY;

    bytes32 poolId;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        tokenX = new MockBalToken("X", 18);
        tokenY = new MockBalToken("Y", 18);
        nav.registerAsset(address(tokenX), 18, "X");
        nav.registerAsset(address(tokenY), 18, "Y");

        vault = new MockV2Vault();
        pool = new MockV2Pool("B-50X-50Y", bytes32(0));
        // poolId encodes the BPT (pool) address in its top 160 bits, like a real Balancer V2 poolId.
        poolId = bytes32((uint256(uint160(address(pool))) << 96) | uint256(0x010001));

        // 1000 X and 2000 Y backing 1000 BPT (no getActualSupply -> totalSupply used).
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenX);
        tokens[1] = address(tokenY);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000e18;
        balances[1] = 2000e18;
        vault.setPool(poolId, tokens, balances);
        pool.setTotalSupply(1000e18);

        adapter = new BalancerV2PoolsMetaBalanceAdapter(address(vault), address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = poolId; // raw poolId, used directly
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public {
        pool.setBalance(alice, 100e18);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    function test_positionsForInstances_walletShare() public {
        pool.setBalance(alice, 100e18); // 10% of supply

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "one Supply leg per pool token");

        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 100e18); // 1000e18 * 100e18 / 1000e18
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].balanceAdapter, address(adapter));
        assertNotEq(pos[0].positionId.length, uint256(0));

        assertEq(pos[1].balanceAsset.asset, address(tokenY));
        assertEq(pos[1].amount, 200e18); // 2000e18 * 100e18 / 1000e18
    }

    function test_getActualSupply_preferredOverTotalSupply() public {
        // Composable-stable pools dilute the share via getActualSupply (here 2000 vs totalSupply 1000).
        pool.setActualSupply(2000e18);
        pool.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos[0].amount, 50e18); // 1000e18 * 100e18 / 2000e18
        assertEq(pos[1].amount, 100e18); // 2000e18 * 100e18 / 2000e18
    }

    function test_bptInPoolToken_excluded() public {
        // Composable-stable pools list their own BPT as a pool token; it must be excluded from the legs.
        address[] memory tokens = new address[](3);
        tokens[0] = address(pool); // the pool's own BPT
        tokens[1] = address(tokenX);
        tokens[2] = address(tokenY);
        uint256[] memory balances = new uint256[](3);
        balances[0] = 999_999e18;
        balances[1] = 1000e18;
        balances[2] = 2000e18;
        vault.setPool(poolId, tokens, balances);
        pool.setActualSupply(1000e18);
        pool.setBalance(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2, "BPT-in-pool token excluded");
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[1].balanceAsset.asset, address(tokenY));

        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
    }

    function test_zeroWalletBpt_empty() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 0);
    }

    function test_assetFilter_returnsOnlyMatchingToken() public {
        pool.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(tokenY));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(tokenY));
        assertEq(pos[0].amount, 200e18);
    }

    function test_unregisteredToken_skipped() public {
        nav.unregisterAssetHelper(address(tokenY));
        pool.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
    }

    function test_badInstance_isolated() public {
        pool.setBalance(alice, 100e18);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32((uint256(uint160(address(0xdead))) << 96)); // no code at derived BPT -> reverts, isolated
        ins[1] = poolId;
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 2, "bad instance isolated, good pool returns both legs");
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
    }

    function test_emptyInstances_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
    }

    /// @dev `positionLabels` is display-only and must never revert, and must never label a coordinate this adapter
    ///      never emitted. Both were reachable before: `abi.decode(pid, (address))` reverts on a word with dirty
    ///      upper 96 bits, and a `pid.length < 32` guard let a foreign MULTI-word coordinate through to be labelled
    ///      from its first word. The decode now goes through `MetaBalanceAdapter._pidWord`, whose own accept window is
    ///      pinned exhaustively in `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case pins that THIS
    ///      adapter routes through it.
    ///
    ///      The clean-coordinate assertion is what keeps the rest load-bearing. A shape-valid but unknown
    ///      coordinate still resolves to the category-only label (the fail-open leaf collapse), so a view that
    ///      rejected everything would fail here rather than pass the rejections trivially.

    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        bytes32 coord = bytes32(uint256(0xBEEF));

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one full word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }
}
