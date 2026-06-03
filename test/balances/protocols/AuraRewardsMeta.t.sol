// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {AuraRewardsMetaBalanceAdapter} from "src/balances/protocols/AuraRewardsMeta.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

// ─── Mocks ─────────────────────────────────────────────────────────────────────

/// @notice Minimal ERC20 mock with symbol/decimals.
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

/// @notice AURA token mock — slot 2 is `minterMinted`.
/// @dev The adapter reads `minterMinted` via raw assembly: staticcall to the token with
///      32-byte calldata = slot number (2), expecting 32 bytes of return data = slot value.
///      The real Aura token has a storage-read fallback implementing `return(sload(calldataload(0)))`.
///
///      We replicate this with a careful fallback that ONLY responds to the 32-byte slot-read
///      pattern (calldatasize == 32 and no recognised function selector). Function calls with
///      4-byte selectors (like `auraOFT()`) are NOT matched and revert, preserving the
///      mainnet vs L2 detection logic in the adapter.
///
///      Storage layout (must match the order below for slot 2 = minterMinted):
///        slot 0: INIT_MINT_AMOUNT
///        slot 1: totalSupply
///        slot 2: minterMinted   ← read by _readSlot2
contract MockAuraToken {
    // solhint-disable-next-line var-name-mixedcase
    uint256 public INIT_MINT_AMOUNT; // slot 0
    uint256 public totalSupply; // slot 1
    uint256 public minterMinted; // slot 2 — read by assembly in _readSlot2

    string public symbol = "AURA";
    uint8 public decimals = 18;

    uint256 public reductionPerCliff;
    uint256 public totalCliffs;
    // solhint-disable-next-line var-name-mixedcase
    uint256 public EMISSIONS_MAX_SUPPLY;

    constructor(
        uint256 initMint_,
        uint256 supply_,
        uint256 minterMinted_,
        uint256 reductionPerCliff_,
        uint256 totalCliffs_,
        uint256 emissionsMax_
    ) {
        INIT_MINT_AMOUNT = initMint_;
        totalSupply = supply_;
        minterMinted = minterMinted_;
        reductionPerCliff = reductionPerCliff_;
        totalCliffs = totalCliffs_;
        EMISSIONS_MAX_SUPPLY = emissionsMax_;
    }

    /// @dev Storage-slot read fallback: only active when calldatasize == 32 (raw slot read pattern).
    ///      4-byte selector calls (e.g. auraOFT()) have calldatasize < 32 and revert, so
    ///      the adapter's L2 detection correctly treats this contract as mainnet (no auraOFT).
    fallback() external {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Only serve raw 32-byte slot reads; reject everything else
            if iszero(eq(calldatasize(), 32)) { revert(0, 0) }
            let slot := calldataload(0)
            let val := sload(slot)
            mstore(0, val)
            return(0, 32)
        }
    }
}

/// @notice L2Coordinator mock — has auraOFT() and mintRate().
contract MockL2Coordinator {
    address public auraToken;
    uint256 public mintRate;

    constructor(address auraToken_, uint256 mintRate_) {
        auraToken = auraToken_;
        mintRate = mintRate_;
    }

    function auraOFT() external view returns (address) {
        return auraToken;
    }
}

/// @notice Booster mock — mainnet variant: minter() returns MockAuraToken (no auraOFT()).
contract MockBooster {
    address public minter_;
    mapping(uint256 => address) private _lptoken;
    mapping(address => uint256) private _multiplier;
    uint256 public denominatorVal = 10_000;

    constructor(address minter__) {
        minter_ = minter__;
    }

    function minter() external view returns (address) {
        return minter_;
    }

    function setPool(uint256 pid, address lptoken) external {
        _lptoken[pid] = lptoken;
    }

    function poolInfo(uint256 pid) external view returns (address lptoken, address, address, address, address, bool) {
        return (_lptoken[pid], address(0), address(0), address(0), address(0), false);
    }

    function setMultiplier(address rewarder, uint256 mult) external {
        _multiplier[rewarder] = mult;
    }

    // solhint-disable-next-line func-name-mixedcase
    function REWARD_MULTIPLIER_DENOMINATOR() external view returns (uint256) {
        return denominatorVal;
    }

    function getRewardMultipliers(address rewarder) external view returns (uint256) {
        return _multiplier[rewarder] == 0 ? denominatorVal : _multiplier[rewarder];
    }
}

/// @notice Aura BaseRewardPool4626 mock.
contract MockAuraBaseRewardPool {
    address public rewardTokenAddr;
    uint256 public pidVal;
    mapping(address => uint256) private _balance;
    mapping(address => uint256) private _earned;
    address[] private _extras;

    constructor(address rewardToken_, uint256 pid_) {
        rewardTokenAddr = rewardToken_;
        pidVal = pid_;
    }

    function pid() external view returns (uint256) {
        return pidVal;
    }

    function rewardToken() external view returns (address) {
        return rewardTokenAddr;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balance[account];
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function extraRewardsLength() external view returns (uint256) {
        return _extras.length;
    }

    function extraRewards(uint256 i) external view returns (address) {
        return _extras[i];
    }

    function setBalance(address account, uint256 amt) external {
        _balance[account] = amt;
    }

    function setEarned(address account, uint256 amt) external {
        _earned[account] = amt;
    }

    function addExtra(address extra) external {
        _extras.push(extra);
    }
}

/// @notice Balancer V3 StablePool mock — 2-token pool, no scaling or rate effects.
/// @dev Returns IStablePool structs so BalancerV3PoolLib can decode them correctly.
///      decimalScalingFactors = [1e18, 1e18], tokenRates = [1e18, 1e18] → raw == liveScaled.
contract MockStablePool {
    IERC20[] private _tokens;
    uint256[] private _balances18;
    uint256 private _totalSupply;

    constructor(address tok0, address tok1, uint256 bal0, uint256 bal1, uint256 ts) {
        _tokens.push(IERC20(tok0));
        _tokens.push(IERC20(tok1));
        _balances18.push(bal0);
        _balances18.push(bal1);
        _totalSupply = ts;
    }

    // ── IERC20 stubs ──────────────────────────────────────────────────────────

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    // ── IStablePool ────────────────────────────────────────────────────────────

    function getStablePoolDynamicData() external view returns (IStablePool.StablePoolDynamicData memory d) {
        d.balancesLiveScaled18 = new uint256[](2);
        d.balancesLiveScaled18[0] = _balances18[0];
        d.balancesLiveScaled18[1] = _balances18[1];
        d.tokenRates = new uint256[](2);
        d.tokenRates[0] = 1e18;
        d.tokenRates[1] = 1e18;
        d.totalSupply = _totalSupply;
        d.bptRate = 1e18;
        d.amplificationParameter = 200;
        d.isPoolInitialized = true;
    }

    function getStablePoolImmutableData() external view returns (IStablePool.StablePoolImmutableData memory d) {
        d.tokens = _tokens;
        d.decimalScalingFactors = new uint256[](2);
        d.decimalScalingFactors[0] = 1e18;
        d.decimalScalingFactors[1] = 1e18;
        d.amplificationParameterPrecision = 1000;
    }
}

/// @notice Extra reward pool with a direct (non-stash) token.
contract MockExtraRewardPool {
    address public rewardToken;
    mapping(address => uint256) private _earned;

    constructor(address tok) {
        rewardToken = tok;
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function setEarned(address account, uint256 amt) external {
        _earned[account] = amt;
    }
}

/// @notice Stash token wrapper (has baseToken()).
contract MockStashToken {
    address public baseToken;

    constructor(address base) {
        baseToken = base;
    }
}

/// @notice Extra reward pool whose rewardToken() is a stash wrapper.
contract MockExtraRewardPoolWithStash {
    MockStashToken public stashToken;
    mapping(address => uint256) private _earned;

    constructor(address underlying) {
        stashToken = new MockStashToken(underlying);
    }

    function rewardToken() external view returns (address) {
        return address(stashToken);
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function setEarned(address account, uint256 amt) external {
        _earned[account] = amt;
    }
}

// ─── Balancer V2 mocks ────────────────────────────────────────────────────────

/// @notice Mock Balancer V2 Vault — implements getPoolTokens.
contract MockBalancerV2Vault {
    mapping(bytes32 => address[]) private _tokens;
    mapping(bytes32 => uint256[]) private _balances;

    function setPool(bytes32 poolId, address[] memory tokens, uint256[] memory bals) external {
        _tokens[poolId] = tokens;
        _balances[poolId] = bals;
    }

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock)
    {
        return (_tokens[poolId], _balances[poolId], 0);
    }
}

/// @notice Mock Balancer V2 Pool (no getStablePoolDynamicData — triggers V2 branch in adapter).
contract MockBalancerV2Pool {
    bytes32 private _poolId;
    uint256 public totalSupply;

    constructor(address vault, address tok0, address tok1, uint256 bal0, uint256 bal1) {
        // Register with vault using a deterministic poolId
        _poolId = bytes32(uint256(uint160(address(this))));
        totalSupply = 1_000e18;
        address[] memory tokens = new address[](2);
        tokens[0] = tok0;
        tokens[1] = tok1;
        uint256[] memory bals = new uint256[](2);
        bals[0] = bal0;
        bals[1] = bal1;
        if (vault != address(0)) MockBalancerV2Vault(vault).setPool(_poolId, tokens, bals);
    }

    function getPoolId() external view returns (bytes32) {
        return _poolId;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
    // No getStablePoolDynamicData() — this is what makes it a V2 pool
}

// ─── Main test contract ────────────────────────────────────────────────────────

contract AuraRewardsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockBooster boosterMainnet;
    MockBooster boosterL2;
    MockAuraToken aura;
    MockL2Coordinator l2Coord;
    MockToken auraL2Token;
    AuraRewardsMetaBalanceAdapter meta;
    AuraRewardsMetaBalanceAdapter metaL2;

    MockToken tok0;
    MockToken tok1;
    MockToken bal;

    MockStablePool pool;
    MockAuraBaseRewardPool rewarder;

    address alice = makeAddr("alice");

    // AURA cliff schedule params:
    //   INIT_MINT_AMOUNT = 50_000_000e18 (initial mint)
    //   totalSupply = 50_000_000e18 (= INIT_MINT_AMOUNT → emissionsMinted=0)
    //   minterMinted (slot 2) = 0
    //   emissionsMinted = supply - INIT_MINT_AMOUNT - minterMinted = 0
    //   cliff = 0, totalCliffs=500, reductionPerCliff=1 (any non-zero)
    //   reduction = (500-0)*5/2 + 700 = 1250 + 700 = 1950
    //   for 1000 BAL: auraAmount = 1000 * 1950 / 500 = 3900
    //   EMISSIONS_MAX_SUPPLY must be > emissionsMinted so amtTillMax doesn't cap
    uint256 constant AURA_INIT_MINT = 50_000_000e18;
    uint256 constant AURA_TOTAL_CLIFFS = 500;
    uint256 constant AURA_REDUCTION_PER_CLIFF = 1;
    uint256 constant AURA_EMISSIONS_MAX = 50_000_000e18;

    function setUp() public {
        nav = new Mock_NAVCalculator();

        tok0 = new MockToken("GHO", 18);
        tok1 = new MockToken("USDC", 6);
        bal = new MockToken("BAL", 18);

        nav.registerAsset(address(tok0), 18, "GHO");
        nav.registerAsset(address(tok1), 6, "USDC");
        nav.registerAsset(address(bal), 18, "BAL");

        // Pool: 1000 GHO (scaled 1e18), 1000 USDC (scaled 1e18 by mock), totalSupply=1000e18
        pool = new MockStablePool(address(tok0), address(tok1), 1000e18, 1000e18, 1000e18);

        // AURA token (mainnet) — totalSupply = INIT_MINT_AMOUNT so emissionsMinted = 0
        // emissionsMinted = totalSupply - INIT_MINT_AMOUNT - minterMinted = 50M - 50M - 0 = 0
        // cliff = 0 / 1 = 0; supply > 0 so the early-return guard is bypassed
        aura = new MockAuraToken(
            AURA_INIT_MINT, // INIT_MINT_AMOUNT
            AURA_INIT_MINT, // totalSupply (= INIT_MINT_AMOUNT → emissionsMinted=0)
            0, // minterMinted (slot 2)
            AURA_REDUCTION_PER_CLIFF,
            AURA_TOTAL_CLIFFS,
            AURA_EMISSIONS_MAX
        );
        nav.registerAsset(address(aura), 18, "AURA");

        // Mainnet Booster: minter() = aura token (no auraOFT())
        boosterMainnet = new MockBooster(address(aura));
        // 1:1 multiplier (multiplier == denominator)
        boosterMainnet.setPool(0, address(pool));

        // Rewarder: pid=0, pool=pool, rewardToken=BAL
        rewarder = new MockAuraBaseRewardPool(address(bal), 0);
        boosterMainnet.setPool(0, address(pool));

        meta = new AuraRewardsMetaBalanceAdapter(address(boosterMainnet), address(0), "Aura", address(nav));

        // L2 setup
        auraL2Token = new MockToken("AURA", 18);
        nav.registerAsset(address(auraL2Token), 18, "AURA-L2");
        l2Coord = new MockL2Coordinator(address(auraL2Token), 3e17); // mintRate = 0.3 AURA per BAL
        boosterL2 = new MockBooster(address(l2Coord));
        boosterL2.setPool(0, address(pool));
        metaL2 = new AuraRewardsMetaBalanceAdapter(address(boosterL2), address(0), "Aura", address(nav));
    }

    // ─── Instance helpers ─────────────────────────────────────────────────────

    function _single(address r) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(r)));
    }

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
        revert("asset not found in positions");
    }

    function _has(INAVCalculator.PositionBalance[] memory pos, address asset) internal pure returns (bool) {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == asset) return true;
        }
        return false;
    }

    // ─── 1. Interface detection ───────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    // ─── 2. Mainnet detection ─────────────────────────────────────────────────

    function test_mainnet_detection() public view {
        assertTrue(meta.IS_MAINNET(), "IS_MAINNET should be true when minter has no auraOFT()");
        assertEq(meta.AURA_TOKEN(), address(aura), "AURA_TOKEN is the minter on mainnet");
    }

    // ─── 3. L2 detection ─────────────────────────────────────────────────────

    function test_l2_detection() public view {
        assertFalse(metaL2.IS_MAINNET(), "IS_MAINNET should be false when minter has auraOFT()");
        assertEq(metaL2.AURA_TOKEN(), address(auraL2Token), "AURA_TOKEN resolves via L2Coordinator.auraOFT()");
    }

    // ─── 4. Staked BPT decomposition ─────────────────────────────────────────

    function test_stakedBpt_decomposesProRata() public {
        // Alice has 100e18 of 1000e18 total = 10%
        // Pool has 1000 GHO (1e18 each scaled) and 1000 USDC (1e18 scaled)
        // With decimalScalingFactor=1e18, tokenRate=1e18:
        //   raw = (liveScaled * userBpt / totalSupply) * 1e18 / (1e18 * 1e18)
        //       = (1000e18 * 100e18 / 1000e18) * 1e18 / 1e36 = 100e18 * 1e18 / 1e36 = 100
        // So GHO raw = 100e18*1e18/1e36 = 100 (18 decimals → but the pool mock stores 1000e18 as the 18-dec-scaled)
        // Let's re-derive: liveScaled[0] = 1000e18, userBpt=100e18, totalSupply=1000e18
        //   share = 1000e18 * 100e18 / 1000e18 = 100e18
        //   raw = 100e18 * 1e18 / (1e18 * 1e18) = 100e18 / 1e18 = 100
        // For tok1 (USDC 6 dec) the pool also stores 1000e18 in 18-dec-scaled form
        //   → raw = 100 (this is in 18-dec units, but then divided by decimalScalingFactor=1e18 → 100e-18?)
        // Actually with decimalScalingFactor = 1e18 for both tokens:
        //   raw = share * 1e18 / (decimalScalingFactor * tokenRate)
        //       = 100e18 * 1e18 / (1e18 * 1e18) = 100e18 / 1e18 = 100
        // So the raw output for GHO = 100 and USDC = 100 (both in their native decimal units)
        // GHO has 18 dec → 100 means 100 wei, very small but that's OK for the math test
        // Let's use larger numbers: 1000e18 pool balance, 100e18 user BPT → gets 100e18 * 1e18 / 1e36 = 100
        // To get readable results: set pool balance = 1000e18 * 1e18 (in 18-dec-scaled) and totalSupply = 1000e18
        // Actually let's set pool balances so the output is nice:
        //   liveScaled = 1000e36 (so raw = 1000e36 / 1e36 = 1000 per full supply)
        // For simplicity just verify pro-rata holds: amount0 / amount1 == balances18[0] / balances18[1]
        rewarder.setBalance(alice, 100e18); // 10% of 1000e18

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        uint256 suppliedCount = _count(pos, PositionKind.Supplied);
        assertEq(suppliedCount, 2, "2 Supplied legs for 2-token pool");

        INAVCalculator.PositionBalance memory p0 = _find(pos, address(tok0));
        INAVCalculator.PositionBalance memory p1 = _find(pos, address(tok1));
        assertEq(uint8(p0.positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p1.positionKind), uint8(PositionKind.Supplied));
        assertFalse(p0.isDebt);
        assertFalse(p1.isDebt);

        // Pro-rata: both pool balances are equal (1000e18 each), so amounts should be equal too
        assertEq(p0.amount, p1.amount, "equal pool balances => equal user shares");
        assertGt(p0.amount, 0);
    }

    // ─── 5. BAL earned leg ────────────────────────────────────────────────────

    function test_balRewards_emittedAsEarned() public {
        uint256 balEarned = 500e18;
        rewarder.setEarned(alice, balEarned);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory balPos = _find(pos, address(bal));
        assertEq(balPos.amount, balEarned, "BAL amount equals rewarder.earned()");
        assertEq(uint8(balPos.positionKind), uint8(PositionKind.Rewards));
        assertFalse(balPos.isDebt);
    }

    // ─── 6. AURA mainnet cliff schedule ──────────────────────────────────────

    function test_aura_mainnet_derivedFromBal() public {
        // totalSupply=50M, INIT_MINT_AMOUNT=50M, minterMinted(slot2)=0
        //   emissionsMinted = 50M - 50M - 0 = 0
        //   cliff = 0 / 1 = 0
        //   reduction = (500 - 0) * 5 / 2 + 700 = 1250 + 700 = 1950
        //   auraAmount = 1000e18 * 1950 / 500 = 3900e18
        //   amtTillMax = 50_000_000e18 - 0 = 50_000_000e18
        //   result = min(3900e18, 50_000_000e18) = 3900e18
        // Multiplier: REWARD_MULTIPLIER_DENOMINATOR = 10_000, getRewardMultipliers returns 10_000 (1:1 default)
        //   multiplied = 1000e18 * 10_000 / 10_000 = 1000e18
        uint256 balEarned = 1000e18;
        rewarder.setEarned(alice, balEarned);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory auraPos = _find(pos, address(aura));
        uint256 expectedAura = 3900e18;
        assertEq(auraPos.amount, expectedAura, "AURA from cliff schedule: 1000 * 1950 / 500 = 3900");
        assertEq(uint8(auraPos.positionKind), uint8(PositionKind.Rewards));
    }

    // ─── 7. AURA L2 via mintRate ──────────────────────────────────────────────

    function test_aura_l2_derivedFromMintRate() public {
        // mintRate = 3e17 (0.3 AURA per BAL), balEarned = 1000e18
        // aura = 1000e18 * 3e17 / 1e18 = 300e18
        uint256 balEarned = 1000e18;
        rewarder.setEarned(alice, balEarned);

        // metaL2 uses a separate rewarder (same mock rewarder but queried via metaL2's booster)
        // The rewarder.pid() = 0 which boosterL2 maps to address(pool)
        INAVCalculator.PositionBalance[] memory pos =
            metaL2.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory auraPos = _find(pos, address(auraL2Token));
        uint256 expectedAura = (balEarned * 3e17) / 1e18;
        assertEq(auraPos.amount, expectedAura, "AURA L2 = balEarned * mintRate / 1e18");
        assertEq(uint8(auraPos.positionKind), uint8(PositionKind.Rewards));
    }

    // ─── 8. Extra reward direct token ─────────────────────────────────────────

    function test_extraReward_directToken() public {
        MockToken ldo = new MockToken("LDO", 18);
        nav.registerAsset(address(ldo), 18, "LDO");

        MockExtraRewardPool extra = new MockExtraRewardPool(address(ldo));
        extra.setEarned(alice, 77e18);
        rewarder.addExtra(address(extra));

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory ldoPos = _find(pos, address(ldo));
        assertEq(ldoPos.amount, 77e18, "Extra direct reward amount");
        assertEq(uint8(ldoPos.positionKind), uint8(PositionKind.Rewards));
    }

    // ─── 9. Extra reward stash-wrapped ───────────────────────────────────────

    function test_extraReward_stashWrapped() public {
        MockToken snx = new MockToken("SNX", 18);
        nav.registerAsset(address(snx), 18, "SNX");

        MockExtraRewardPoolWithStash extra = new MockExtraRewardPoolWithStash(address(snx));
        extra.setEarned(alice, 55e18);
        rewarder.addExtra(address(extra));

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory snxPos = _find(pos, address(snx));
        assertEq(snxPos.amount, 55e18, "Stash-wrapped extra reward unwrapped to base token");
        assertEq(uint8(snxPos.positionKind), uint8(PositionKind.Rewards));
    }

    // ─── 10. AURA accumulates from main + extra pools ─────────────────────────

    function test_aura_accumulatesFromMainAndExtra() public {
        // Main pool: 1000e18 BAL earned → 3900e18 AURA
        // Extra pool: also rewards BAL (via some stash), 500e18 BAL → extra AURA contribution
        //   extra contributes to AURA via _auraFrom(extraPool, extraEarned)
        //   For extraEarned=500e18: reduction=1950, aura = 500e18 * 1950 / 500 = 1950e18
        //   total AURA = 3900e18 + 1950e18 = 5850e18
        rewarder.setEarned(alice, 1000e18);

        // Extra pool that itself triggers AURA accumulation.
        // rewardToken() != AURA_TOKEN and != balToken so it emits its own earned leg too.
        MockToken extraBal = new MockToken("xBAL", 18);
        nav.registerAsset(address(extraBal), 18, "xBAL");
        MockExtraRewardPool extraPool = new MockExtraRewardPool(address(extraBal));
        extraPool.setEarned(alice, 500e18);
        rewarder.addExtra(address(extraPool));

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        INAVCalculator.PositionBalance memory auraPos = _find(pos, address(aura));
        // Main: 1000e18 * 1950 / 500 = 3900e18
        // Extra: 500e18 * 1950 / 500 = 1950e18
        // Total = 5850e18
        assertEq(auraPos.amount, 5850e18, "AURA aggregated from main + extra pools");

        // Exactly one AURA leg in output
        uint256 auraLegs;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == address(aura)) auraLegs++;
        }
        assertEq(auraLegs, 1, "single AURA leg regardless of how many pools contribute");
    }

    // ─── 11. Asset filter ────────────────────────────────────────────────────

    function test_assetFilter() public {
        rewarder.setBalance(alice, 100e18);
        rewarder.setEarned(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(tok0));

        assertGt(pos.length, 0, "filter must return at least one position");
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].balanceAsset.asset, address(tok0), "all positions match filter");
        }
    }

    // ─── 12. No stake, only rewards ──────────────────────────────────────────

    function test_noStake_onlyRewards() public {
        rewarder.setEarned(alice, 200e18); // BAL earned, no staked BPT

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        // No Supplied legs
        assertEq(_count(pos, PositionKind.Supplied), 0, "no Supplied legs when stakedBpt = 0");
        // Has BAL and AURA Earned legs
        assertTrue(_has(pos, address(bal)), "BAL Earned leg present");
        assertTrue(_has(pos, address(aura)), "AURA Earned leg present");
    }

    // ─── 13. Bad instance isolation ──────────────────────────────────────────

    function test_badInstance_isolated() public {
        rewarder.setBalance(alice, 100e18);

        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xdead)))); // bad instance
        instances[1] = bytes32(uint256(uint160(address(rewarder))));

        INAVCalculator.PositionBalance[] memory pos = meta.getOraclePositionsForInstances(alice, instances, address(0));

        assertGt(pos.length, 0, "good rewarder still returns positions");
    }

    // ─── 14. instanceAssets returns all tokens ────────────────────────────────

    function test_instanceAssets_returnsAllTokens() public {
        MockToken ldo = new MockToken("LDO", 18);
        nav.registerAsset(address(ldo), 18, "LDO");

        MockExtraRewardPool extra = new MockExtraRewardPool(address(ldo));
        rewarder.addExtra(address(extra));

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_single(address(rewarder)));

        // Expected: tok0, tok1 (pool), bal (main reward), aura, ldo (extra)
        assertEq(assets.length, 5, "pool tokens + BAL + AURA + LDO");

        bool hasTok0;
        bool hasTok1;
        bool hasBal;
        bool hasAura;
        bool hasLdo;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == address(tok0)) hasTok0 = true;
            if (assets[i] == address(tok1)) hasTok1 = true;
            if (assets[i] == address(bal)) hasBal = true;
            if (assets[i] == address(aura)) hasAura = true;
            if (assets[i] == address(ldo)) hasLdo = true;
        }
        assertTrue(hasTok0 && hasTok1 && hasBal && hasAura && hasLdo, "all expected assets present");
    }

    // ─── 15. Position identity ────────────────────────────────────────────────

    function test_positionIdentity() public {
        rewarder.setBalance(alice, 100e18);
        rewarder.setEarned(alice, 500e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(alice, _single(address(rewarder)), address(0));

        assertGt(pos.length, 0);
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].protocolId, ProtocolIds.AURA, "protocolId = AURA");
            assertEq(pos[i].positionId, abi.encode(address(rewarder)), "positionId = abi.encode(rewarder)");
            assertEq(pos[i].balanceOracle, address(meta), "balanceOracle = meta address");
        }
    }

    // ─── 16. describePosition format ─────────────────────────────────────────

    function test_describePosition_format() public view {
        string memory label = meta.describePosition(abi.encode(address(rewarder)));
        // Tokens in pool order: tok0 = "GHO", tok1 = "USDC" → "GHO/USDC Aura"
        assertEq(label, "GHO/USDC Aura");
    }

    // ─── 17. Balancer V2 pool support ────────────────────────────────────────

    function test_v2pool_suppliedLegs_decomposedViaVault() public {
        // Deploy a mock Balancer V2 pool and mock Vault
        MockBalancerV2Vault vault = new MockBalancerV2Vault();
        MockBalancerV2Pool v2Pool = new MockBalancerV2Pool(address(vault), address(tok0), address(tok1), 500e18, 500e6);

        // Wire up: booster pid=1 → v2Pool as lptoken
        boosterMainnet.setPool(1, address(v2Pool));

        // Deploy Aura meta with the mock vault address
        AuraRewardsMetaBalanceAdapter v2Meta =
            new AuraRewardsMetaBalanceAdapter(address(boosterMainnet), address(vault), "Aura", address(nav));

        // Rewarder for the V2 pool: pid=1, staked=100e18 (10% of 1000e18 totalSupply)
        MockAuraBaseRewardPool v2Rewarder = new MockAuraBaseRewardPool(address(bal), 1);
        v2Rewarder.setBalance(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            v2Meta.getOraclePositionsForInstances(alice, _single(address(v2Rewarder)), address(0));

        uint256 suppliedCount;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == PositionKind.Supplied) suppliedCount++;
        }
        assertEq(suppliedCount, 2, "2 Supplied legs from V2 Vault decomposition");

        // 10% of 500e18 GHO = 50e18
        INAVCalculator.PositionBalance memory ghoPos = _find(pos, address(tok0));
        assertEq(ghoPos.amount, 50e18, "V2 GHO share = 50");

        // 10% of 500e6 USDC = 50e6
        INAVCalculator.PositionBalance memory usdcPos = _find(pos, address(tok1));
        assertEq(usdcPos.amount, 50e6, "V2 USDC share = 50");
    }

    function test_v2pool_instanceAssets_includesVaultTokens() public {
        MockBalancerV2Vault vault = new MockBalancerV2Vault();
        MockBalancerV2Pool v2Pool = new MockBalancerV2Pool(address(vault), address(tok0), address(tok1), 500e18, 500e6);
        boosterMainnet.setPool(1, address(v2Pool));
        AuraRewardsMetaBalanceAdapter v2Meta =
            new AuraRewardsMetaBalanceAdapter(address(boosterMainnet), address(vault), "Aura", address(nav));
        MockAuraBaseRewardPool v2Rewarder = new MockAuraBaseRewardPool(address(bal), 1);

        address[] memory assets = v2Meta.underlyingAssetsSupportedForInstances(_single(address(v2Rewarder)));
        // Should include: tok0, tok1 (pool tokens) + bal (rewardToken) + aura
        assertGe(assets.length, 2, "at least the two pool tokens");
    }

    function test_v2pool_noVault_noSuppliedLegs_rewardsStillWork() public {
        // Meta deployed with address(0) vault — V2 Supplied legs are skipped
        MockBalancerV2Pool v2Pool = new MockBalancerV2Pool(address(0), address(tok0), address(tok1), 500e18, 500e6);
        boosterMainnet.setPool(1, address(v2Pool));
        AuraRewardsMetaBalanceAdapter noVaultMeta =
            new AuraRewardsMetaBalanceAdapter(address(boosterMainnet), address(0), "Aura", address(nav));
        MockAuraBaseRewardPool v2Rewarder = new MockAuraBaseRewardPool(address(bal), 1);
        v2Rewarder.setBalance(alice, 100e18);
        v2Rewarder.setEarned(alice, 200e18); // BAL earned

        INAVCalculator.PositionBalance[] memory pos =
            noVaultMeta.getOraclePositionsForInstances(alice, _single(address(v2Rewarder)), address(0));

        // No Supplied legs (vault is address(0)) but BAL Earned leg present
        for (uint256 i; i < pos.length; ++i) {
            assertFalse(pos[i].positionKind == PositionKind.Supplied, "no Supplied legs without vault");
        }
        assertTrue(_has(pos, address(bal)), "BAL Earned leg still emitted");
    }
}
