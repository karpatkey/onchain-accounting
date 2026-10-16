// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// Mocks for the Fables family: a configurable hook, the two hostile hook shapes the adapter and the index
// are required to survive, and a PoolManager that answers `extsload` out of a slot map the test writes
// through {V4StateLibrary}'s own key derivations.

import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {V4StateLibrary} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4StateLibrary.sol";
import {
    IFablesHook,
    FablesRangeState,
    FablesUserPosition
} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";

/// @notice A Fables hook whose whole observable surface is settable.
/// @dev Deliberately NOT `is IFablesHook`: several tests need shapes a conforming implementation cannot
///      produce (a reverting `claimFeeRecipient`, a `effectiveClaimFee` answering a full word above
///      `type(uint16).max`), and inheriting the interface would make those structurally impossible.
contract MockFablesHook {
    struct RangeCfg {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        bool set;
    }

    mapping(uint256 => RangeCfg) private _ranges;
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(uint256 => FablesRangeState) private _states;
    mapping(uint256 => mapping(address => FablesUserPosition)) private _positions;
    mapping(uint256 => uint256) private _claimFee;

    address private _claimFeeRecipient;
    bool public paused;

    /// @dev "This hook does not answer that selector at all" — the measured 4663 ABI drift.
    bool public claimFeeRecipientReverts;
    bool public effectiveClaimFeeReverts;
    /// @dev A hook that stops answering `balanceOf` AFTER an entry was filed against it. The index must read
    ///      that as zero — so the entry stays prunable and stays out of `liveRanges` — rather than letting
    ///      one broken hook revert a read that spans many entries.
    bool public balanceOfReverts;
    /// @dev Answer `claimFeeRecipient()` with a word whose upper 96 bits are dirty: answered, but not with
    ///      an address. The typed getter structurally cannot produce it.
    bool public claimFeeRecipientDirty;

    constructor(address claimFeeRecipient_) {
        _claimFeeRecipient = claimFeeRecipient_;
    }

    //
    // configuration
    //

    function setRange(uint256 id, PoolKey memory key, int24 tickLower, int24 tickUpper, bool set) external {
        _ranges[id] = RangeCfg({key: key, tickLower: tickLower, tickUpper: tickUpper, set: set});
    }

    function setBalance(address owner, uint256 id, uint256 amount) external {
        _balances[owner][id] = amount;
    }

    function setRangeState(uint256 id, FablesRangeState memory st) external {
        _states[id] = st;
    }

    function setUserPosition(uint256 id, address owner, FablesUserPosition memory p) external {
        _positions[id][owner] = p;
    }

    function setClaimFee(uint256 id, uint256 bps) external {
        _claimFee[id] = bps;
    }

    function setClaimFeeRecipient(address recipient) external {
        _claimFeeRecipient = recipient;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setClaimFeeRecipientReverts(bool v) external {
        claimFeeRecipientReverts = v;
    }

    function setEffectiveClaimFeeReverts(bool v) external {
        effectiveClaimFeeReverts = v;
    }

    function setBalanceOfReverts(bool v) external {
        balanceOfReverts = v;
    }

    function setClaimFeeRecipientDirty(bool v) external {
        claimFeeRecipientDirty = v;
    }

    //
    // IFablesHook surface
    //

    function rangeKey(uint256 id) external view returns (PoolKey memory, int24, int24, bool) {
        RangeCfg memory c = _ranges[id];
        return (c.key, c.tickLower, c.tickUpper, c.set);
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        require(!balanceOfReverts, "hook down");
        return _balances[owner][id];
    }

    function rangeState(uint256 id) external view returns (FablesRangeState memory) {
        return _states[id];
    }

    function userPosition(uint256 id, address owner) external view returns (FablesUserPosition memory) {
        return _positions[id][owner];
    }

    function effectiveClaimFee(uint256 id) external view returns (uint256) {
        require(!effectiveClaimFeeReverts, "no such selector");
        return _claimFee[id];
    }

    function claimFeeRecipient() external view returns (bytes32) {
        require(!claimFeeRecipientReverts, "no such selector");
        uint256 word = uint256(uint160(_claimFeeRecipient));
        if (claimFeeRecipientDirty) word |= uint256(1) << 255;
        return bytes32(word);
    }
}

/// @notice A contract that answers {IFablesHook} with whatever it was constructed with.
/// @dev Exists to prove the adapter's third authority check does something. Returning a REAL PoolKey is
///      trivially within a hostile contract's power, so a valuer that only checked
///      `keccak256(abi.encode(key)) == instance` would be fully satisfied by this and would then trust its
///      balance — which is set to `type(uint128).max` precisely to make the consequence unmissable.
contract MockForgedHook {
    PoolKey private _key;
    uint256 private _balance;
    int24 private _tickLower;
    int24 private _tickUpper;

    constructor(PoolKey memory key, uint256 balance, int24 tickLower, int24 tickUpper) {
        _key = key;
        _balance = balance;
        _tickLower = tickLower;
        _tickUpper = tickUpper;
    }

    function rangeKey(uint256) external view returns (PoolKey memory, int24, int24, bool) {
        return (_key, _tickLower, _tickUpper, true);
    }

    function balanceOf(address, uint256) external view returns (uint256) {
        return _balance;
    }

    function rangeState(uint256) external pure returns (FablesRangeState memory s) {
        s.totalShares = type(uint128).max;
    }

    function userPosition(uint256, address) external pure returns (FablesUserPosition memory p) {
        return p;
    }

    function effectiveClaimFee(uint256) external pure returns (uint16) {
        return 0;
    }

    function claimFeeRecipient() external pure returns (address) {
        return address(0);
    }
}

/// @notice Answers the index (so it can be filed, and {FablesRangeIndex.prune} refuses it) and reverts for
///         everyone else.
/// @dev The review of PR #46 (24 Sep 2026) used exactly this shape to blind the first version of the
///      adapter: the read loop walked every filed entry, so one stranger's entry reverted the holder's rows
///      for every instance. Pinned in the unit suite as well as the fork suite, because it is the single
///      behaviour the per-(holder, hook) bucketing exists for.
contract MockGriefHook {
    address public immutable INDEX;
    PoolKey private _key;

    constructor(address index_, PoolKey memory key) {
        INDEX = index_;
        _key = key;
    }

    function rangeKey(uint256) external view returns (PoolKey memory, int24, int24, bool) {
        return (_key, int24(-100), int24(100), true);
    }

    function balanceOf(address, uint256) external view returns (uint256) {
        if (msg.sender == INDEX) return 1;
        revert("grief");
    }
}

/// @notice A Uniswap V4 PoolManager stand-in: a raw slot map behind the `extsload` array overload.
/// @dev Pool state is written through {V4StateLibrary}'s own `poolStateSlot`/`tickBaseSlot`/`positionKey`
///      derivations, so the mock cannot drift from the layout the adapter reads: a wrong derivation would
///      make the setters and the reader disagree and every amount would come back zero.
contract MockV4PoolManager {
    mapping(bytes32 => bytes32) private _words;

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            out[i] = _words[slots[i]];
        }
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _words[slot];
    }

    /// @notice Set a pool's `Slot0` — the packed `sqrtPriceX96 | tick | protocolFee | lpFee` word.
    function setSlot0(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        // `int24 -> uint24` is a reinterpretation into its slot in the packed word, not a narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(protocolFee) << 184)
            | (uint256(lpFee) << 208);
        _words[V4StateLibrary.poolStateSlot(poolId)] = bytes32(packed);
    }

    function setFeeGrowthGlobals(bytes32 poolId, uint256 g0, uint256 g1) external {
        bytes32 state = V4StateLibrary.poolStateSlot(poolId);
        _words[bytes32(uint256(state) + V4StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET)] = bytes32(g0);
        _words[bytes32(uint256(state) + V4StateLibrary.FEE_GROWTH_GLOBAL1_OFFSET)] = bytes32(g1);
    }

    /// @notice Set a boundary tick's `feeGrowthOutside0/1X128` pair.
    function setTickFeeGrowthOutside(bytes32 poolId, int24 tick, uint256 o0, uint256 o1) external {
        bytes32 base = V4StateLibrary.tickBaseSlot(V4StateLibrary.poolStateSlot(poolId), tick);
        _words[bytes32(uint256(base) + V4StateLibrary.TICK_FEE_GROWTH_OFFSET)] = bytes32(o0);
        _words[bytes32(uint256(base) + V4StateLibrary.TICK_FEE_GROWTH_OFFSET + 1)] = bytes32(o1);
    }

    /// @notice Set one position's `{liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128}` triple.
    function setPosition(
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity,
        uint256 fgInside0Last,
        uint256 fgInside1Last
    ) external {
        bytes32 state = V4StateLibrary.poolStateSlot(poolId);
        bytes32 pos =
            V4StateLibrary.positionStateSlot(state, V4StateLibrary.positionKey(owner, tickLower, tickUpper, salt));
        _words[pos] = bytes32(uint256(liquidity));
        _words[bytes32(uint256(pos) + 1)] = bytes32(fgInside0Last);
        _words[bytes32(uint256(pos) + 2)] = bytes32(fgInside1Last);
    }
}

/// @notice Minimal ERC20 metadata for label and registry assertions.
contract MockFablesToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}

/// @notice Compile-time proof that {MockFablesHook}'s conforming subset matches the real interface.
/// @dev The mock cannot declare `is IFablesHook` (it must be able to answer the non-conforming shapes the
///      drift tests need), so this records the selectors the adapter depends on and fails the build if
///      {IFablesHook} ever renames one underneath the mocks.
library FablesHookSelectors {
    bytes4 internal constant RANGE_KEY = IFablesHook.rangeKey.selector;
    bytes4 internal constant BALANCE_OF = IFablesHook.balanceOf.selector;
    bytes4 internal constant RANGE_STATE = IFablesHook.rangeState.selector;
    bytes4 internal constant USER_POSITION = IFablesHook.userPosition.selector;
    bytes4 internal constant EFFECTIVE_CLAIM_FEE = IFablesHook.effectiveClaimFee.selector;
    bytes4 internal constant CLAIM_FEE_RECIPIENT = IFablesHook.claimFeeRecipient.selector;
}
