// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PolygonStakingMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal Polygon `ValidatorShare` mock: settable stake/rewards per account and a settable validator id.
contract MockValidatorShare {
    uint256 private _validatorId;
    bool private _revertOnValidatorId;
    mapping(address => uint256) private _stake;
    mapping(address => uint256) private _rewards;

    constructor(uint256 validatorId_) {
        _validatorId = validatorId_;
    }

    error ValidatorIdNotSupported();

    function validatorId() external view returns (uint256) {
        if (_revertOnValidatorId) revert ValidatorIdNotSupported();
        return _validatorId;
    }

    function setRevertOnValidatorId(bool v) external {
        _revertOnValidatorId = v;
    }

    function getStakeAndRewards(address user) external view returns (uint256, uint256) {
        return (_stake[user], _rewards[user]);
    }

    function set(address user, uint256 stake_, uint256 rewards_) external {
        _stake[user] = stake_;
        _rewards[user] = rewards_;
    }
}

/// @notice `validatorId()` succeeds but returns ZERO bytes — the ERC-1967 shape where the implementation slot
///         points at a code-less address, so the `delegatecall` succeeds and returns nothing.
contract MockEmptyReturndataShare {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @notice `validatorId()` returns a SHORT (16-byte) payload — not a `uint256`, so it must be rejected rather than
///         zero-extended into a confident, wrong validator number.
contract MockShortReturnShare {
    fallback() external {
        assembly {
            mstore(0x00, 0)
            return(0x00, 0x10)
        }
    }
}

/// @notice `validatorId()` returns a 64-byte payload — MORE than one word. Not a `uint256` reply either, and the
///         `size != 32` guard must reject it in this direction too: silently taking the first word would render a
///         confident, wrong validator number from a contract that is not answering this selector.
contract MockLongReturnShare {
    fallback() external {
        assembly {
            mstore(0x00, 4242)
            mstore(0x20, 1)
            return(0x00, 0x40)
        }
    }
}

/// @notice `validatorId()` burns gas without writing state, so it OOGs inside the capped `staticcall`. A storage
///         burner would abort on write-protection instead and never loop.
contract MockGasBurnerShare {
    function validatorId() external view returns (uint256) {
        uint256 acc;
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        return acc;
    }
}

/// @notice Answers EVERY selector with a zero word — a very common contract shape (many proxies and stubs do
///         this). `validatorId()` therefore "succeeds" with 0, which is not a real validator: StakeManager ids are
///         1-based and `getValidatorContract(0)` is address(0).
contract MockZeroWordShare {
    fallback() external {
        assembly {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

contract MockPol {
    string public symbol = "POL";
    uint8 public decimals = 18;
}

/// @title PolygonStakingMetaBalanceAdapter unit tests (no fork)
contract PolygonStakingMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    PolygonStakingMetaBalanceAdapter meta;
    MockPol pol;
    MockValidatorShare shareA; // validator 192 — the one actually held on mainnet
    MockValidatorShare shareB; // validator 7 — stake only, no rewards

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        pol = new MockPol();
        nav.registerAsset(address(pol), 18, "POL");

        shareA = new MockValidatorShare(192);
        shareB = new MockValidatorShare(7);

        shareA.set(alice, 100e18, 5e18); // staked + rewards
        shareB.set(alice, 40e18, 0); // staked only

        meta = new PolygonStakingMetaBalanceAdapter(address(pol), address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(shareA))));
        ins[1] = bytes32(uint256(uint160(address(shareB))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    /// @dev Both legs are non-debt and share one positionId — they are told apart by `positionKind`.
    function test_fanOut_legsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // shareA: Staking(100) + Rewards(5); shareB: Staking(40) -> 3 legs
        assertEq(p.length, 3);

        assertEq(p[0].balanceAsset.asset, address(pol));
        assertEq(p[0].amount, 100e18);
        assertFalse(p[0].isDebt, "staking leg is never debt");
        assertEq(p[0].balanceAdapter, address(meta));
        assertEq(p[0].positionId, abi.encode(address(shareA)));

        assertEq(p[1].amount, 5e18, "rewards leg");
        assertFalse(p[1].isDebt, "rewards leg is never debt");
        assertEq(p[1].positionId, abi.encode(address(shareA)), "both legs share one positionId");

        assertEq(p[2].amount, 40e18);
        assertEq(p[2].positionId, abi.encode(address(shareB)));
    }

    function test_assetFilter_match_and_miss() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(pol)).length, 2);
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(0xdead)).length, 0);
    }

    /// @dev Must return empty, NOT revert — an unregistered asset is an ordinary outcome.
    function test_unregisteredUnderlying_skipped() public {
        Mock_NAVCalculator bare = new Mock_NAVCalculator();
        PolygonStakingMetaBalanceAdapter m = new PolygonStakingMetaBalanceAdapter(address(pol), address(bare));
        assertEq(m.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_noPosition_empty() public {
        address bob = makeAddr("bob");
        assertEq(meta.getAdapterPositionsForInstances(bob, _instances(), address(0)).length, 0);
    }

    /// @dev A code-less instance must be dropped without taking its siblings down with it.
    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code
        ins[1] = bytes32(uint256(uint160(address(shareA))));
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 2, "shareA's two legs survive the bad sibling");
        assertEq(p[0].positionId, abi.encode(address(shareA)));
    }

    /// @dev One entry PER INSTANCE, not a deduped set — the meta base concatenates `_instanceAssets` without
    ///      uniquing, so a single-asset adapter over N instances answers N copies. Pinned so a future dedup
    ///      would surface as a deliberate behaviour change rather than a silent one.
    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2, "one per instance");
        assertEq(a[0], address(pol));
        assertEq(a[1], address(pol));
    }

    // ─────────────────────────── positionLabels ───────────────────────────

    /// @dev Tier 1: the leaf comes from `validatorId()`, NOT from `name()`. That is the whole point of this
    ///      adapter's label override — the live shares' `name()` ("Delegated POL #c0") carries no recoverable
    ///      validator number.
    function test_positionLabels_usesValidatorId() public view {
        string[] memory l = meta.positionLabels(abi.encode(address(shareA)));
        assertEq(l.length, 2);
        assertEq(l[0], "Validator");
        assertEq(l[1], "#192");
    }

    function test_positionLabels_distinctPerInstance() public view {
        assertEq(meta.positionLabels(abi.encode(address(shareA)))[1], "#192");
        assertEq(meta.positionLabels(abi.encode(address(shareB)))[1], "#7");
    }

    /// @dev Tier 2: a reverting `validatorId()` degrades to "<symbol> <address>", never blank, never reverting.
    function test_positionLabels_revertingValidatorId_fallsBackToSymbolAndAddress() public {
        shareA.setRevertOnValidatorId(true);
        string[] memory l = meta.positionLabels(abi.encode(address(shareA)));
        assertEq(l.length, 2);
        assertEq(l[1], string.concat("POL ", address(shareA).toHexString()));
    }

    /// @dev With POL unregistered there is no symbol to prefix, so the leaf is the bare address.
    function test_positionLabels_unregisteredUnderlying_bareAddress() public {
        Mock_NAVCalculator bare = new Mock_NAVCalculator();
        PolygonStakingMetaBalanceAdapter m = new PolygonStakingMetaBalanceAdapter(address(pol), address(bare));
        shareA.setRevertOnValidatorId(true);
        assertEq(m.positionLabels(abi.encode(address(shareA)))[1], address(shareA).toHexString());
    }

    function test_positionLabels_emptyReturndata_fallsBack() public {
        MockEmptyReturndataShare s = new MockEmptyReturndataShare();
        assertEq(meta.positionLabels(abi.encode(address(s)))[1], string.concat("POL ", address(s).toHexString()));
    }

    /// @dev A 16-byte reply is not a `uint256`. Decoding it anyway would print a confident, wrong validator number.
    function test_positionLabels_shortReturndata_rejected() public {
        MockShortReturnShare s = new MockShortReturnShare();
        assertEq(meta.positionLabels(abi.encode(address(s)))[1], string.concat("POL ", address(s).toHexString()));
    }

    /// @dev The other rejection direction from `test_positionLabels_shortReturndata_rejected`. A guard that only
    ///      caught SHORT replies would take word 0 of this one and print "#4242" for a contract that never
    ///      answered `validatorId()`.
    function test_positionLabels_longReturndata_rejected() public {
        MockLongReturnShare s = new MockLongReturnShare();
        assertEq(meta.positionLabels(abi.encode(address(s)))[1], string.concat("POL ", address(s).toHexString()));
    }

    /// @dev A zero id must fall back, not render "Validator #0". This is the one rejection the `size == 32`
    ///      check cannot make: the reply is a well-formed word, it is just not a validator.
    function test_positionLabels_zeroValidatorId_fallsBack() public {
        MockZeroWordShare s = new MockZeroWordShare();
        string[] memory l = meta.positionLabels(abi.encode(address(s)));
        assertEq(l[1], string.concat("POL ", address(s).toHexString()), "must not render #0");
    }

    function test_positionLabels_gasBurner_isBounded() public {
        MockGasBurnerShare s = new MockGasBurnerShare();
        uint256 before = gasleft();
        string[] memory l = meta.positionLabels(abi.encode(address(s)));
        uint256 used = before - gasleft();
        assertEq(l[1], string.concat("POL ", address(s).toHexString()));
        assertLt(used, 1_000_000, "the validatorId probe must stay gas-capped");
    }

    function test_positionLabels_codeless_fallsBack() public view {
        address codeless = address(0xBEEF);
        assertEq(meta.positionLabels(abi.encode(codeless))[1], string.concat("POL ", codeless.toHexString()));
    }

    function test_positionLabels_shortPid_empty() public view {
        assertEq(meta.positionLabels(hex"1234").length, 0);
    }

    /// @dev A multi-word coordinate belongs to some other adapter; labelling it from word 0 would be a confident
    ///      breadcrumb for a position this adapter never emitted.
    function test_positionLabels_overLongPid_empty() public view {
        assertEq(meta.positionLabels(abi.encode(address(shareA), uint256(1))).length, 0);
    }

    /// @dev Dirty upper bits must degrade to the category, not revert — `abi.decode(_, (address))` would revert.
    function test_positionLabels_dirtyUpperBits_categoryOnly() public view {
        bytes memory pid = abi.encode(uint256(type(uint256).max));
        string[] memory l = meta.positionLabels(pid);
        assertEq(l.length, 1);
        assertEq(l[0], "Validator");
    }
}
