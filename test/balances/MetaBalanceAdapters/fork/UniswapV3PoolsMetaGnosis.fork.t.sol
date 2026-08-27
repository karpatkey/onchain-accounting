// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";

interface IGnosisNPM {
    function factory() external view returns (address);
}

interface IGnosisFactory {
    function getPool(address token0, address token1, uint24 fee) external view returns (address);
}

interface IGnosisPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @title UniswapV3PoolsMetaGnosisForkTest
/// @author KPK
/// @notice Premise tests for the chain-100 Uniswap V3 wiring: the NonfungiblePositionManager address and the
///         governed pool set, both read from config rather than hardcoded here.
/// @dev **Why this exists as a separate file from the mainnet fork test.** That test pins the Ethereum NPM, pool
///      and holder, so it exercises the adapter's MATH but says nothing about chain 100's addresses. No covered
///      Gnosis Safe holds a Uniswap V3 NFT today, so the integration suite runs this adapter's inert path and its
///      NAV assertions are unchanged whether the configuration is right or wrong. A wrong-but-callable NPM, or a
///      pool address that is not a real Uniswap pool, would therefore return an empty position list and be
///      indistinguishable from "this Safe holds nothing" — an under-report hiding behind a complete-looking
///      answer. These assertions fail instead.
///
///      **They iterate the config, not a hardcoded list**, so adding an instance — which is the whole point of the
///      meta pattern, an `addMetaInstances` transaction rather than a deploy — inherits the same checks instead of
///      leaving them behind. Verified on-chain 2026-08-27: the NPM's `factory()` is
///      `0xe32F7dD7e3f098D518ff19A22d5f028e076489B1` and all seven configured pools are genuine factory pools.
contract UniswapV3PoolsMetaGnosisForkTest is BalanceAdapterTestBase {
    /// @dev Read from config in every test; duplicated here only so a config edit that drops the key fails loudly.
    string internal constant DEPLOY_CFG = "script/config/contracts-deployment-config/meta-balance-adapters/100.json";
    string internal constant NAV_CFG = "script/config/nav-config/meta-balance-adapters/100.json";
    string internal constant ASSET_CFG = "script/config/nav-config/assets-and-price-feeds/100.json";

    uint256 public constant FORK_BLOCK = 47_933_022;

    function setUp() public override {
        super.setUp();
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK);
    }

    function _positionManager() internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(DEPLOY_CFG), ".UniswapV3PoolsMeta.constructor.positionManager");
    }

    function _instances() internal view returns (address[] memory) {
        return vm.parseJsonAddressArray(vm.readFile(NAV_CFG), ".UniswapV3PoolsMeta.instances");
    }

    /// @notice The configured NPM is a real Uniswap V3 position manager, identified by its own factory pointer.
    /// @dev Uniswap V3 is deployed at DIFFERENT addresses on Gnosis than on Ethereum, and the mainnet NPM address
    ///      is the obvious wrong value to paste here. This is what distinguishes "the right contract" from "a
    ///      contract that answers the calls".
    function test_positionManagerIsRealAndOnThisChain() public view {
        address npm = _positionManager();
        assertGt(npm.code.length, 0, "configured positionManager has no code on Gnosis");
        address factory = IGnosisNPM(npm).factory();
        assertGt(factory.code.length, 0, "positionManager.factory() is not a contract");
        assertTrue(npm != 0xC36442b4a4522E871399CD717aBDD847Ab11FE88, "this is the ETHEREUM NPM address");
    }

    /// @notice EVERY configured pool is a genuine pool of the NPM's own factory.
    /// @dev The load-bearing assertion. `getPool(token0, token1, fee)` round-tripping back to the configured
    ///      address proves factory MEMBERSHIP: any other contract that merely answers `token0`/`token1`/`fee`
    ///      fails here. Without it, a mistyped or hostile instance would be valued as an LP position.
    function test_everyConfiguredPoolIsAGenuineFactoryPool() public view {
        address factory = IGnosisNPM(_positionManager()).factory();
        address[] memory pools = _instances();
        assertGt(pools.length, 0, "config lists no Uniswap V3 instances for chain 100");

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            (address t0, address t1, uint24 fee) = _poolIdentity(pool);
            assertEq(
                IGnosisFactory(factory).getPool(t0, t1, fee),
                pool,
                "configured instance is not the factory's pool for its own (token0, token1, fee)"
            );
        }
    }

    /// @notice Both tokens of every configured pool are registered chain-100 assets.
    /// @dev NAV values an LP position as the sum of its two legs, so a pool with one unregistered token would be
    ///      valued from one leg only and UNDER-report — silently, because the adapter drops what it cannot price
    ///      rather than reverting. Iterating the config means a later instance addition cannot skip the check.
    function test_bothTokensOfEveryPoolAreRegisteredAssets() public view {
        string memory assetsJson = vm.readFile(ASSET_CFG);
        string[] memory symbols = vm.parseJsonKeys(assetsJson, "$");

        address[] memory registered = new address[](symbols.length);
        for (uint256 i = 0; i < symbols.length; i++) {
            registered[i] = vm.parseJsonAddress(assetsJson, string.concat(".", symbols[i], ".address"));
        }

        address[] memory pools = _instances();
        for (uint256 i = 0; i < pools.length; i++) {
            (address t0, address t1,) = _poolIdentity(pools[i]);
            _assertRegistered(registered, t0, "token0");
            _assertRegistered(registered, t1, "token1");
        }
    }

    /// @dev Read a pool's three identity fields through low-level staticcalls so an instance that is NOT a pool
    ///      fails with a message naming the problem, instead of the bare `EvmError: Revert` that
    ///      `IGnosisPool(x).token0()` produces. Measured: pointing an instance at the GNO token produced exactly
    ///      that unhelpful revert before this was written, which tells whoever added the bad instance nothing.
    function _poolIdentity(address pool) internal view returns (address t0, address t1, uint24 fee) {
        assertGt(pool.code.length, 0, "configured pool has no code on Gnosis");
        bool ok;
        bytes memory ret;
        (ok, ret) = pool.staticcall(abi.encodeWithSignature("token0()"));
        assertTrue(ok && ret.length == 32, "configured instance does not answer token0(); is it really a pool?");
        t0 = abi.decode(ret, (address));
        (ok, ret) = pool.staticcall(abi.encodeWithSignature("token1()"));
        assertTrue(ok && ret.length == 32, "configured instance does not answer token1(); is it really a pool?");
        t1 = abi.decode(ret, (address));
        (ok, ret) = pool.staticcall(abi.encodeWithSignature("fee()"));
        assertTrue(ok && ret.length == 32, "configured instance does not answer fee(); is it really a pool?");
        fee = uint24(abi.decode(ret, (uint256)));
    }

    function _assertRegistered(address[] memory registered, address token, string memory which) internal pure {
        for (uint256 i = 0; i < registered.length; i++) {
            if (registered[i] == token) return;
        }
        assertTrue(false, string.concat("configured pool's ", which, " is not a registered chain-100 asset"));
    }

    /// @notice The adapter is constructible against the configured NPM and reports no legs for an account with no
    ///         NFTs — the inert path, asserted rather than assumed.
    function test_accountWithNoPositions_yieldsNoLegs() public {
        (address t0,,) = _poolIdentity(_instances()[0]);
        balances = _deployBalancesForAdapter(t0);
        UniswapV3PoolsMetaBalanceAdapter meta =
            new UniswapV3PoolsMetaBalanceAdapter(_positionManager(), address(balances));

        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(_instances()[0])));
        assertEq(meta.getAdapterPositionsForInstances(address(0xDEAD), ins, address(0)).length, 0);
    }
}
