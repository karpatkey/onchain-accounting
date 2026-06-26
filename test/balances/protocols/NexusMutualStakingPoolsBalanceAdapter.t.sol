// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    NexusMutualStakingPoolsBalanceAdapter,
    INexusStakingViewer
} from "src/balances/protocols/NexusMutualStakingPoolsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Nexus's StakingNFT — mint-only ERC-721 with `totalSupply()` +
///         `tokenInfo(id) -> (poolId, owner)`. Unset ids return (0, address(0)) (skipped by the
///         adapter); `setRevertId` makes one id revert to exercise the try/catch.
contract MockStakingNFT {
    uint256 private _supply;
    mapping(uint256 => address) private _owner;
    mapping(uint256 => uint256) private _pool;
    bool public revertSupply;
    bool public revertBalance;
    uint256 public revertId; // 0 = none

    function setTotalSupply(uint256 s) external {
        _supply = s;
    }

    function setToken(uint256 id, uint256 poolId, address owner) external {
        _pool[id] = poolId;
        _owner[id] = owner;
    }

    function setRevertSupply(bool v) external {
        revertSupply = v;
    }

    function setRevertBalance(bool v) external {
        revertBalance = v;
    }

    function setRevertId(uint256 id) external {
        revertId = id;
    }

    function totalSupply() external view returns (uint256) {
        require(!revertSupply, "supply revert");
        return _supply;
    }

    /// @notice Standard ERC721 owned-count, derived from the seeded owners over 1..totalSupply.
    function balanceOf(address owner) external view returns (uint256 c) {
        require(!revertBalance, "balanceOf revert");
        for (uint256 i = 1; i <= _supply; ++i) {
            if (_owner[i] == owner) c++;
        }
    }

    function tokenInfo(uint256 id) external view returns (uint256, address) {
        require(id != revertId || revertId == 0, "tokenInfo revert");
        return (_pool[id], _owner[id]);
    }
}

/// @notice Minimal mock of Nexus's StakingViewer — stores per-token (poolId, active, expired, rewards)
///         and returns them via both `getTokens` (per-token, used for positions) and
///         `getAggregatedTokens` (summed, used by the no-arg balance getters).
contract MockStakingViewer {
    mapping(uint256 => uint256) public poolId;
    mapping(uint256 => uint256) public active;
    mapping(uint256 => uint256) public expired;
    mapping(uint256 => uint256) public rewards;
    bool public doRevert;

    function setToken(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) external {
        poolId[id] = pool;
        active[id] = a;
        expired[id] = e;
        rewards[id] = r;
    }

    function setRevert(bool v) external {
        doRevert = v;
    }

    function getTokens(uint256[] calldata ids) external view returns (INexusStakingViewer.Token[] memory tokens) {
        require(!doRevert, "tokens revert");
        tokens = new INexusStakingViewer.Token[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            tokens[i] = INexusStakingViewer.Token({
                tokenId: ids[i],
                poolId: poolId[ids[i]],
                activeStake: active[ids[i]],
                expiredStake: expired[ids[i]],
                rewards: rewards[ids[i]],
                deposits: new INexusStakingViewer.Deposit[](0)
            });
        }
    }

    function getAggregatedTokens(uint256[] calldata ids)
        external
        view
        returns (INexusStakingViewer.AggregatedTokens memory agg)
    {
        require(!doRevert, "agg revert");
        for (uint256 i; i < ids.length; ++i) {
            agg.totalActiveStake += active[ids[i]];
            agg.totalExpiredStake += expired[ids[i]];
            agg.totalRewards += rewards[ids[i]];
        }
    }
}

/// @title NexusMutualStakingPoolsBalanceAdapter unit tests
contract NexusMutualStakingPoolsBalanceAdapterTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsBalanceAdapter public adapter;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    Mock_ERC20 public nxm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        adapter =
            new NexusMutualStakingPoolsBalanceAdapter(address(nft), address(viewer), address(nxm), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(address(0), address(viewer), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(address(nft), address(0), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(address(nft), address(viewer), address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(address(nft), address(viewer), address(nxm), address(0));
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(bytes("StakingNFT must be a contract"));
        new NexusMutualStakingPoolsBalanceAdapter(makeAddr("eoa"), address(viewer), address(nxm), address(balances));
    }

    // ---- Discovery + valuation ----

    /// @dev Seed `supply` tokens, assign `ownedIds` to `holder` in pool `pool` (rest to `other`), value each owned.
    function _seed(uint256 supply, uint256[] memory ownedIds, uint256 pool, uint256 a, uint256 e, uint256 r) internal {
        nft.setTotalSupply(supply);
        for (uint256 i = 1; i <= supply; ++i) {
            nft.setToken(i, pool, other);
        }
        for (uint256 i; i < ownedIds.length; ++i) {
            nft.setToken(ownedIds[i], pool, holder);
            viewer.setToken(ownedIds[i], pool, a, e, r);
        }
    }

    function test_discoversOwnedTokensAndAggregates() public {
        uint256[] memory owned = new uint256[](2);
        owned[0] = 2;
        owned[1] = 5;
        _seed(6, owned, 1, 100, 10, 3); // each owned: 100 active + 10 expired + 3 rewards
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        // staking = (100+10)*2 = 220; rewards = 3*2 = 6; total = 226
        assertEq(amt, 226);
        assertEq(d, false);
    }

    function test_otherAccountNotPickedUp() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 3;
        _seed(6, owned, 1, 100, 0, 5);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(other, address(nxm));
        assertEq(amt, 0); // `other` owns the non-seeded tokens (active 0) → 0 staked
    }

    function test_balanceForWrongAsset_zero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amt, 0);
    }

    // ---- getAdapterPositions: per-NFT legs + identity ----

    function test_positions_stakingAndRewardsLegs() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 4;
        _seed(5, owned, 7, 100, 20, 7); // pool 7
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
        // leg 0 = Staking (active+expired = 120), leg 1 = Rewards (7)
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 120);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, 7);
        bytes memory expectedId = abi.encode(uint256(4), uint256(7)); // (tokenId, poolId)
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, address(nxm));
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL_STAKING);
            assertEq(p[i].positionId, expectedId);
            assertEq(p[i].isDebt, false);
        }
    }

    /// @dev Two positions in two different pools → 4 legs, each keyed by its own (tokenId, poolId).
    ///      Discovery scans descending (newest id first), so token 2 is emitted before token 1.
    function test_positions_twoPools_distinctPositionIds() public {
        nft.setTotalSupply(3);
        nft.setToken(1, 7, holder);
        viewer.setToken(1, 7, 100, 0, 1);
        nft.setToken(2, 9, holder);
        viewer.setToken(2, 9, 200, 0, 2);
        nft.setToken(3, 7, other);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 4); // (Staking+Rewards) x 2 tokens
        // token 2 → pool 9 (scanned first, descending)
        assertEq(p[0].positionId, abi.encode(uint256(2), uint256(9)));
        assertEq(p[1].positionId, abi.encode(uint256(2), uint256(9)));
        assertEq(p[0].amount, 200);
        assertEq(p[1].amount, 2);
        // token 1 → pool 7
        assertEq(p[2].positionId, abi.encode(uint256(1), uint256(7)));
        assertEq(p[3].positionId, abi.encode(uint256(1), uint256(7)));
        assertEq(p[2].amount, 100);
        assertEq(p[3].amount, 1);
    }

    function test_positions_onlyStakingWhenNoRewards() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 3, 50, 0, 0);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 50);
        assertEq(p[0].positionId, abi.encode(uint256(1), uint256(3)));
    }

    function test_positions_onlyRewardsWhenNoStake() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 3, 0, 0, 9);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[0].amount, 9);
    }

    function test_positions_emptyWhenNothing() public {
        nft.setTotalSupply(3);
        for (uint256 i = 1; i <= 3; i++) {
            nft.setToken(i, 1, other);
        }
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_positions_assetFilterMatch_andMismatch() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 0);
        assertEq(adapter.getAdapterPositions(holder, address(nxm)).length, 1); // match → leg
        assertEq(adapter.getAdapterPositions(holder, address(weth)).length, 0); // mismatch → empty
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        NexusMutualStakingPoolsBalanceAdapter a2 =
            new NexusMutualStakingPoolsBalanceAdapter(address(nft), address(viewer), address(nxm), address(freshNav));
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 5);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0); // NXM not registered → dropped
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105); // balance still computed
    }

    function test_getAdapterBalances_shape() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 2;
        _seed(3, owned, 1, 100, 0, 5);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(nxm));
        assertEq(amounts[0], 105);
        assertEq(isDebt[0], false);
    }

    // ---- Caps + never-revert ----

    function test_perAccountCap_limitsCollectedTokens() public {
        uint256 cap = adapter.MAX_POSITIONS_PER_ACCOUNT();
        uint256 supply = cap + 5;
        nft.setTotalSupply(supply);
        for (uint256 i = 1; i <= supply; i++) {
            nft.setToken(i, 1, holder); // holder owns ALL
            viewer.setToken(i, 1, 1, 0, 0); // 1 active each
        }
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, cap); // collection capped at MAX_POSITIONS_PER_ACCOUNT (1 active each)
    }

    function test_highId_discoveredNoScanCap() public {
        // No fixed scan cap: a high-id position (beyond the old 5000 bound) is still discovered. The
        // descending scan + balanceOf early-exit finds it in one iteration here (it's the newest id).
        uint256 highId = 6000;
        nft.setTotalSupply(highId);
        nft.setToken(highId, 1, holder);
        viewer.setToken(highId, 1, 123, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 123); // found despite id > the former 5000 cap
    }

    function test_tokenInfoReverts_skipped_notReverted() public {
        uint256[] memory owned = new uint256[](2);
        owned[0] = 2;
        owned[1] = 4;
        _seed(5, owned, 1, 100, 0, 0);
        nft.setRevertId(2); // tokenInfo(2) reverts → skipped
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 100); // only token 4 counted
    }

    function test_totalSupplyReverts_zero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 0);
        nft.setRevertSupply(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_viewerReverts_balanceZero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 0);
        viewer.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_viewerReverts_positionsEmpty() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 1, 100, 0, 5);
        viewer.setRevert(true);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0); // getTokens revert → empty
    }

    // ---- balanceOf fast-path ----

    function test_zeroBalance_skipsScan() public {
        // holder owns nothing; balanceOf == 0 short-circuits before the (here large) id scan.
        nft.setTotalSupply(500);
        for (uint256 i = 1; i <= 500; ++i) {
            nft.setToken(i, 1, other);
        }
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_balanceOfReverts_fallsBackToScan() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 3;
        _seed(5, owned, 1, 100, 0, 7);
        nft.setRevertBalance(true); // balanceOf unavailable → fall back to the bounded full scan
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2); // still discovered via the scan
        assertEq(p[0].positionId, abi.encode(uint256(3), uint256(1)));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 107);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], address(nxm));
    }
}
