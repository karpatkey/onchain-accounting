// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ConvexRewardsMetaBalanceAdapter} from "src/balances/protocols/ConvexRewardsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockToken {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
        totalSupply = 1_000_000e18;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

/// @notice Mock Curve pool that is also the LP token (self-LP, uint256 indices).
contract MockCurvePool {
    address[] public coins_;
    mapping(uint256 => uint256) private _bal;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address[] memory c) {
        coins_ = c;
        totalSupply = 1_000e18;
        for (uint256 i; i < c.length; ++i) {
            _bal[i] = 100_000e18;
        }
    }

    function coins(uint256 i) external view returns (address) {
        if (i >= coins_.length) revert("oor");
        return coins_[i];
    }

    function balances(uint256 i) external view returns (uint256) {
        return _bal[i];
    }

    function setPoolBalance(uint256 i, uint256 amt) external {
        _bal[i] = amt;
    }

    function setTotalSupply(uint256 ts) external {
        totalSupply = ts;
    }

    function setWalletBalance(address a, uint256 amt) external {
        balanceOf[a] = amt;
    }
}

/// @notice Mock extra rewarder (direct token, no stash wrapper).
contract MockExtraRewarder {
    address public rewardToken;
    mapping(address => uint256) private _earned;

    constructor(address tok) {
        rewardToken = tok;
    }

    function setEarned(address a, uint256 amt) external {
        _earned[a] = amt;
    }

    function earned(address a) external view returns (uint256) {
        return _earned[a];
    }
}

/// @notice Mock extra rewarder whose rewardToken() is a stash wrapper.
contract MockStashWrapper {
    address public token; // underlying token

    constructor(address underlying) {
        token = underlying;
    }
}

contract MockExtraRewarderWithStash {
    MockStashWrapper public stashToken;
    mapping(address => uint256) private _earned;

    constructor(address underlying) {
        stashToken = new MockStashWrapper(underlying);
    }

    function rewardToken() external view returns (address) {
        return address(stashToken);
    }

    function setEarned(address a, uint256 amt) external {
        _earned[a] = amt;
    }

    function earned(address a) external view returns (uint256) {
        return _earned[a];
    }
}

/// @notice Mock Convex BaseRewardPool.
contract MockConvexRewarder {
    address public pool; // the Curve LP pool
    address public rewardToken;
    uint256 public pid_;
    mapping(address => uint256) public balanceOf; // staked LP
    mapping(address => uint256) private _earned;
    address[] private _extras;

    constructor(address pool_, address crv_, uint256 pid) {
        pool = pool_;
        rewardToken = crv_;
        pid_ = pid;
    }

    function pid() external view returns (uint256) {
        return pid_;
    }

    function earned(address a) external view returns (uint256) {
        return _earned[a];
    }

    function setStaked(address a, uint256 amt) external {
        balanceOf[a] = amt;
    }

    function setEarned(address a, uint256 amt) external {
        _earned[a] = amt;
    }

    function addExtra(address e) external {
        _extras.push(e);
    }

    function extraRewardsLength() external view returns (uint256) {
        return _extras.length;
    }

    function extraRewards(uint256 i) external view returns (address) {
        return _extras[i];
    }
}

/// @notice Mock Convex Booster.
contract MockConvexBooster {
    mapping(uint256 => address) private _lptoken;

    function setPool(uint256 pid, address lp) external {
        _lptoken[pid] = lp;
    }

    function poolInfo(uint256 pid) external view returns (address lptoken, address, address, address, address, bool) {
        return (_lptoken[pid], address(0), address(0), address(0), address(0), false);
    }
}

/// @notice Mock CVX token (tracks totalSupply for cliff schedule).
contract MockCvxToken {
    uint256 public totalSupply;
    uint8 public decimals = 18;
    string public symbol = "CVX";
    mapping(address => uint256) public balanceOf;

    function setTotalSupply(uint256 ts) external {
        totalSupply = ts;
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────

contract ConvexRewardsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockConvexBooster booster;
    MockCvxToken cvx;
    ConvexRewardsMetaBalanceAdapter meta;

    MockToken usdc;
    MockToken weth;
    MockToken crv;
    MockToken ldo; // extra reward

    MockCurvePool pool;
    MockConvexRewarder rewarder;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        booster = new MockConvexBooster();
        cvx = new MockCvxToken();

        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        crv = new MockToken("CRV", 18);
        ldo = new MockToken("LDO", 18);

        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(crv), 18, "CRV");
        nav.registerAsset(address(ldo), 18, "LDO");
        nav.registerAsset(address(cvx), 18, "CVX");

        // Pool IS the LP token (self-LP), 50/50 USDC/WETH
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(weth);
        pool = new MockCurvePool(coins);
        pool.setPoolBalance(0, 500e6);
        pool.setPoolBalance(1, 500e18);
        pool.setTotalSupply(1_000e18);

        // Rewarder: pid=42, LP=pool, rewardToken=CRV
        rewarder = new MockConvexRewarder(address(pool), address(crv), 42);
        booster.setPool(42, address(pool));

        meta = new ConvexRewardsMetaBalanceAdapter(address(booster), address(cvx), "Convex", address(nav));
    }

    function _instance(address r) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(r)));
    }

    // ─── Interface ────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    // ─── LP decomposition ─────────────────────────────────────────────────────

    function test_stakedLp_decomposesProRata() public {
        rewarder.setStaked(alice, 100e18); // 10% of 1000 LP

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        uint256 staking = _count(pos, PositionKind.Staking);
        assertEq(staking, 2, "2 Staking legs (USDC + WETH)");
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 50e6); // 10% of 500 USDC
        assertEq(pos[1].balanceAsset.asset, address(weth));
        assertEq(pos[1].amount, 50e18); // 10% of 500 WETH
        assertFalse(pos[0].isDebt);
    }

    function test_positionIdentity() public {
        rewarder.setStaked(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));
        assertGt(pos.length, 0);
        assertEq(pos[0].protocolId, ProtocolIds.CONVEX);
        assertEq(pos[0].positionId, abi.encode(address(rewarder)));
        assertEq(pos[0].balanceAdapter, address(meta));
    }

    function test_noStake_noStakingLegs() public {
        // Only rewards, no staked LP
        rewarder.setEarned(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));
        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].positionKind == PositionKind.Staking);
        }
    }

    // ─── CRV rewards ──────────────────────────────────────────────────────────

    function test_crvRewards_emittedAsRewards() public {
        rewarder.setEarned(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory crvPos = _find(pos, address(crv));
        assertEq(crvPos.amount, 500e18);
        assertEq(uint8(crvPos.positionKind), uint8(PositionKind.Rewards));
    }

    function test_noCrvRewards_zeroEarned() public {
        rewarder.setStaked(alice, 100e18);
        // earned = 0 → no CRV leg

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].balanceAsset.asset == address(crv));
        }
    }

    // ─── CVX derivation ───────────────────────────────────────────────────────

    function test_cvx_derivedFromCrv_cliffSchedule() public {
        // CVX supply = 50M → cliff 500, remaining 500 cliffs
        cvx.setTotalSupply(50_000_000e18);
        rewarder.setEarned(alice, 1_000e18); // 1000 CRV earned

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory cvxPos = _find(pos, address(cvx));
        // cliff = 50_000_000 / 100_000 = 500; remaining = 1000 - 500 = 500
        // cvxAmount = 1000 * 500 / 1000 = 500 CVX
        assertEq(cvxPos.amount, 500e18);
        assertEq(uint8(cvxPos.positionKind), uint8(PositionKind.Rewards));
    }

    function test_cvx_capped_atMaxSupply() public {
        // CVX supply = 99.9M → only 100k remaining to max
        cvx.setTotalSupply(99_900_000e18);
        rewarder.setEarned(alice, 10_000e18); // large CRV

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory cvxPos = _find(pos, address(cvx));
        // Uncapped would be: cliff = 999, remaining = 1, cvxAmt = 10_000 * 1 / 1000 = 10
        // amtTillMax = 100_000e18; so result = min(10e18, 100_000e18) = 10e18
        assertEq(cvxPos.amount, 10e18);
    }

    function test_noCvxToken_noCvxLeg() public {
        ConvexRewardsMetaBalanceAdapter noCvx =
            new ConvexRewardsMetaBalanceAdapter(address(booster), address(0), "Convex", address(nav));
        rewarder.setEarned(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            noCvx.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].balanceAsset.asset == address(cvx));
        }
    }

    // ─── Extra rewards ────────────────────────────────────────────────────────

    function test_extraReward_directToken() public {
        MockExtraRewarder extra = new MockExtraRewarder(address(ldo));
        extra.setEarned(alice, 42e18);
        rewarder.addExtra(address(extra));

        rewarder.setStaked(alice, 50e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory ldoPos = _find(pos, address(ldo));
        assertEq(ldoPos.amount, 42e18);
        assertEq(uint8(ldoPos.positionKind), uint8(PositionKind.Rewards));
    }

    function test_extraReward_stashWrapper_unwrapped() public {
        MockExtraRewarderWithStash extra = new MockExtraRewarderWithStash(address(ldo));
        extra.setEarned(alice, 77e18);
        rewarder.addExtra(address(extra));

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory ldoPos = _find(pos, address(ldo));
        assertEq(ldoPos.amount, 77e18);
    }

    function test_extraReward_unregistered_skipped() public {
        MockToken unknown = new MockToken("UNKN", 18);
        MockExtraRewarder extra = new MockExtraRewarder(address(unknown));
        extra.setEarned(alice, 100e18);
        rewarder.addExtra(address(extra));

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(0));

        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].balanceAsset.asset == address(unknown));
        }
    }

    // ─── Asset filter ─────────────────────────────────────────────────────────

    function test_assetFilter() public {
        rewarder.setStaked(alice, 100e18);
        rewarder.setEarned(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(rewarder)), address(usdc));

        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].balanceAsset.asset, address(usdc));
        }
        assertGt(pos.length, 0);
    }

    // ─── Isolation ────────────────────────────────────────────────────────────

    function test_badInstance_isolated() public {
        rewarder.setStaked(alice, 100e18);

        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xdead))));
        instances[1] = bytes32(uint256(uint160(address(rewarder))));

        INAVCalculator.PositionBalance[] memory pos = meta.getAdapterPositionsForInstances(alice, instances, address(0));
        assertGt(pos.length, 0, "good rewarder returned");
    }

    // ─── underlyingAssetsSupported ────────────────────────────────────────────

    function test_instanceAssets_coinsAndRewards() public view {
        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_instance(address(rewarder)));
        // USDC + WETH (coins) + CRV (main) + CVX
        assertEq(assets.length, 4);
    }

    // ─── describePosition ─────────────────────────────────────────────────────

    function test_describePosition_format() public view {
        string memory label = meta.describePosition(abi.encode(address(rewarder)));
        assertEq(label, "USDC/WETH Convex");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _count(INAVCalculator.PositionBalance[] memory pos, PositionKind k) internal pure returns (uint256 n) {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == k) n++;
        }
    }

    function _find(INAVCalculator.PositionBalance[] memory pos, address asset)
        internal
        pure
        returns (INAVCalculator.PositionBalance memory)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == asset) return pos[i];
        }
        revert("not found");
    }
}
