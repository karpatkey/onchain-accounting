// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {NexusStakedNxmBalanceAdapter} from "src/balances/protocols/NexusStakedNxm.sol";
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

    function setRevertId(uint256 id) external {
        revertId = id;
    }

    function totalSupply() external view returns (uint256) {
        require(!revertSupply, "supply revert");
        return _supply;
    }

    function tokenInfo(uint256 id) external view returns (uint256, address) {
        require(id != revertId || revertId == 0, "tokenInfo revert");
        return (_pool[id], _owner[id]);
    }
}

/// @notice Minimal mock of Nexus's StakingViewer — aggregates per-token active/expired/rewards over
///         exactly the tokenIds passed, so the adapter's discovery → valuation is tested end-to-end.
contract MockStakingViewer {
    mapping(uint256 => uint256) public active;
    mapping(uint256 => uint256) public expired;
    mapping(uint256 => uint256) public rewards;
    bool public doRevert;

    function setToken(uint256 id, uint256 a, uint256 e, uint256 r) external {
        active[id] = a;
        expired[id] = e;
        rewards[id] = r;
    }

    function setRevert(bool v) external {
        doRevert = v;
    }

    function getAggregatedTokens(uint256[] calldata ids) external view returns (uint256, uint256, uint256) {
        require(!doRevert, "agg revert");
        uint256 a;
        uint256 e;
        uint256 r;
        for (uint256 i; i < ids.length; ++i) {
            a += active[ids[i]];
            e += expired[ids[i]];
            r += rewards[ids[i]];
        }
        return (a, e, r);
    }
}

/// @title NexusStakedNxmBalanceAdapter unit tests
contract NexusStakedNxmBalanceAdapterTest is BalanceAdapterTestBase {
    NexusStakedNxmBalanceAdapter public adapter;
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
        adapter = new NexusStakedNxmBalanceAdapter(address(nft), address(viewer), address(nxm), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusStakedNxmBalanceAdapter(address(0), address(viewer), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusStakedNxmBalanceAdapter(address(nft), address(0), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusStakedNxmBalanceAdapter(address(nft), address(viewer), address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusStakedNxmBalanceAdapter(address(nft), address(viewer), address(nxm), address(0));
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(bytes("StakingNFT must be a contract"));
        new NexusStakedNxmBalanceAdapter(makeAddr("eoa"), address(viewer), address(nxm), address(balances));
    }

    // ---- Discovery + valuation ----

    /// @dev Seed `supply` tokens, assign `ownedIds` to `holder` (rest to `other`), value each owned.
    function _seed(uint256 supply, uint256[] memory ownedIds, uint256 a, uint256 e, uint256 r) internal {
        nft.setTotalSupply(supply);
        for (uint256 i = 1; i <= supply; ++i) {
            nft.setToken(i, 1, other);
        }
        for (uint256 i; i < ownedIds.length; ++i) {
            nft.setToken(ownedIds[i], 1, holder);
            viewer.setToken(ownedIds[i], a, e, r);
        }
    }

    function test_discoversOwnedTokensAndAggregates() public {
        uint256[] memory owned = new uint256[](2);
        owned[0] = 2;
        owned[1] = 5;
        _seed(6, owned, 100, 10, 3); // each owned: 100 active + 10 expired + 3 rewards
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        // staking = (100+10)*2 = 220; rewards = 3*2 = 6; total = 226
        assertEq(amt, 226);
        assertEq(d, false);
    }

    function test_otherAccountNotPickedUp() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 3;
        _seed(6, owned, 100, 0, 5);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(other, address(nxm));
        assertEq(amt, 0); // `other` owns the non-seeded tokens (active 0) → 0 staked
    }

    function test_balanceForWrongAsset_zero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 100, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amt, 0);
    }

    // ---- getAdapterPositions: legs + identity ----

    function test_positions_stakingAndRewardsLegs() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 4;
        _seed(5, owned, 100, 20, 7);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
        // leg 0 = Staking (active+expired = 120), leg 1 = Rewards (7)
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 120);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, 7);
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, address(nxm));
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_STAKING);
            assertEq(p[i].positionId, "");
            assertEq(p[i].isDebt, false);
        }
    }

    function test_positions_onlyStakingWhenNoRewards() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 50, 0, 0);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 50);
    }

    function test_positions_onlyRewardsWhenNoStake() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 0, 0, 9);
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
        _seed(2, owned, 100, 0, 0);
        assertEq(adapter.getAdapterPositions(holder, address(nxm)).length, 1); // match → leg
        assertEq(adapter.getAdapterPositions(holder, address(weth)).length, 0); // mismatch → empty
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        NexusStakedNxmBalanceAdapter a2 =
            new NexusStakedNxmBalanceAdapter(address(nft), address(viewer), address(nxm), address(freshNav));
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 100, 0, 5);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0); // NXM not registered → dropped
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105); // balance still computed
    }

    function test_getAdapterBalances_shape() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 2;
        _seed(3, owned, 100, 0, 5);
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
            viewer.setToken(i, 1, 0, 0); // 1 active each
        }
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, cap); // collection capped at MAX_POSITIONS_PER_ACCOUNT (1 active each)
    }

    function test_beyondMaxScan_notDiscovered() public {
        uint256 scan = adapter.MAX_TOKEN_SCAN();
        nft.setTotalSupply(scan + 3);
        nft.setToken(scan + 2, 1, holder); // owned, but id beyond the scan bound
        viewer.setToken(scan + 2, 999, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0); // not discovered (id > MAX_TOKEN_SCAN)
    }

    function test_tokenInfoReverts_skipped_notReverted() public {
        uint256[] memory owned = new uint256[](2);
        owned[0] = 2;
        owned[1] = 4;
        _seed(5, owned, 100, 0, 0);
        nft.setRevertId(2); // tokenInfo(2) reverts → skipped
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 100); // only token 4 counted
    }

    function test_totalSupplyReverts_zero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 100, 0, 0);
        nft.setRevertSupply(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_aggregatedTokensReverts_zero() public {
        uint256[] memory owned = new uint256[](1);
        owned[0] = 1;
        _seed(2, owned, 100, 0, 0);
        viewer.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
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
