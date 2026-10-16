// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {SickleHeldPositions} from "src/balances/MetaBalanceAdapters/vfat/SickleHeldPositions.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {NotAContract} from "src/errors.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockToken} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";
import {
    MockSickleFactory,
    MockSickle,
    MockRevertingOwnerSickle,
    MockDirtyWordFactory,
    MockDirtyOwnerSickle,
    MockZeroOwnerSickle
} from "test/balances/MetaBalanceAdapters/vfat/SickleMocks.sol";

/// @notice Smallest possible concrete {SickleHeldPositions}: the instance coordinate is a token address and each
///         holder reports one `Supplied` leg of a test-set amount. It carries NO protocol logic, so every
///         assertion below is about the mixin's admission rule and its concatenation, not about any venue.
/// @dev Declared here rather than in a shared mocks file because it exists only to make the abstract mixin
///      instantiable; nothing else should reuse it.
contract TestSickleAdapter is SickleHeldPositions {
    mapping(address => mapping(address => uint256)) public amountOf; // holder => token => amount

    constructor(address navCalculator_, address sickleFactory_)
        MetaBalanceAdapter(navCalculator_)
        SickleHeldPositions(sickleFactory_)
    {}

    function setAmount(address holder, address token, uint256 amount) external {
        amountOf[holder][token] = amount;
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    /// @dev One leg per holder, gated exactly as a real adapter gates: `_eligible` (assetFilter + registry).
    function _holderPositions(address holder, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory out)
    {
        address token = _toAddress(instance);
        uint256 amount = amountOf[holder][token];
        (INAVCalculator.Asset memory info, bool ok) = _eligible(token, assetFilter);
        if (!ok || amount == 0) return new INAVCalculator.PositionBalance[](0);
        out = new INAVCalculator.PositionBalance[](1);
        out[0] = _leg(info, amount, false, abi.encode(token), PositionKind.Supplied);
    }

    function _instanceAssets(bytes32 instance) internal pure override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _toAddress(instance);
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        return new string[](0);
    }
}

/// @title SickleHeldPositions unit tests (no fork)
/// @notice Pins the mixin's ADMISSION RULE — a second holder is admitted only when the factory's forward map and
///         the Sickle's own `owner()` agree, in both directions — and its concatenation of the two holders' legs.
contract SickleHeldPositionsTest is Test {
    Mock_NAVCalculator nav;
    MockSickleFactory factory;
    TestSickleAdapter meta;
    MockToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        factory = new MockSickleFactory();
        token = new MockToken("TKN", 18);
        nav.registerAsset(address(token), 18, "TKN");
        meta = new TestSickleAdapter(address(nav), address(factory));
    }

    function _instance() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(token))));
    }

    function _read(address account) internal view returns (INAVCalculator.PositionBalance[] memory) {
        return meta.getAdapterPositionsForInstances(account, _instance(), address(0));
    }

    /// @dev Files a Sickle owned by `owner` under `filedUnder`; the two differ only in the hostile cases.
    function _deploySickle(address owner, address filedUnder) internal returns (address sickle) {
        sickle = address(new MockSickle(owner));
        factory.setSickle(filedUnder, sickle);
    }

    function test_constructor_rejectsNonContractFactory() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new TestSickleAdapter(address(nav), address(0));

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new TestSickleAdapter(address(nav), makeAddr("eoa"));
    }

    /// @notice No factory entry: the account is its own only holder.
    function test_noSickle_onlyOwnLegs() public {
        meta.setAmount(alice, address(token), 5);
        assertEq(meta.sickleOf(alice), address(0), "no Sickle filed");
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 5);
    }

    /// @notice The admitted case: both directions agree, so the Sickle's legs are reported as the account's.
    function test_admittedSickle_reportsBothHolders() public {
        address sickle = _deploySickle(alice, alice);
        assertEq(meta.sickleOf(alice), sickle, "both directions agree");

        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 7);

        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 2, "own legs then the Sickle's, concatenated");
        assertEq(p[0].amount, 5, "the account's own leg comes first");
        assertEq(p[1].amount, 7, "the Sickle's leg follows");
    }

    /// @notice Only the Sickle holds anything — the usual shape for a deployed portfolio.
    function test_sickleOnly() public {
        address sickle = _deploySickle(alice, alice);
        meta.setAmount(sickle, address(token), 9);
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 9);
    }

    /// @notice THE REVERSE CHECK. The factory files bob's Sickle under alice; `owner()` says bob. Alice must see
    ///         ONLY her own legs — the forward map alone is not authority over what an account appears to own.
    function test_reverseCheckFails_reportsOnlyOwnLegs() public {
        address sickle = _deploySickle(bob, alice);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 1_000_000);

        assertEq(meta.sickleOf(alice), address(0), "owner() names someone else: not admitted");
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1, "only the account's own leg");
        assertEq(p[0].amount, 5, "the foreign Sickle's balance is not borrowed");
    }

    /// @notice A Sickle that will not answer `owner()` is not admitted, and does not revert the read.
    function test_revertingOwner_failsOpen() public {
        address sickle = address(new MockRevertingOwnerSickle());
        factory.setSickle(alice, sickle);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 11);

        assertEq(meta.sickleOf(alice), address(0), "unreadable owner() is not an attestation");
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 5);
    }

    /// @notice A factory that reverts resolves to "no second holder" rather than taking the whole read down.
    function test_revertingFactory_failsOpen() public {
        address sickle = _deploySickle(alice, alice);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 11);
        factory.setReverts(true);

        assertEq(meta.sickleOf(alice), address(0));
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1, "the account's own legs survive a dead factory");
        assertEq(p[0].amount, 5);
    }

    /// @notice An EOA filed as a Sickle holds no code and cannot attest; not admitted.
    function test_codelessSickle_notAdmitted() public {
        factory.setSickle(alice, makeAddr("notAContract"));
        meta.setAmount(alice, address(token), 5);
        assertEq(meta.sickleOf(alice), address(0));
        assertEq(_read(alice).length, 1);
    }

    /// @notice Querying a Sickle DIRECTLY is supported: it is its own holder, read exactly once.
    function test_queryingTheSickleItself_readsItOnce() public {
        address sickle = _deploySickle(alice, alice);
        meta.setAmount(sickle, address(token), 7);
        // The factory has no entry for the Sickle, so there is no second holder to add.
        assertEq(meta.sickleOf(sickle), address(0));
        INAVCalculator.PositionBalance[] memory p = _read(sickle);
        assertEq(p.length, 1, "no double count");
        assertEq(p[0].amount, 7);
    }

    /// @notice A self-referential factory entry (`sickles(a) == a`) is never a second holder.
    function test_selfReferentialEntry_notAdmitted() public {
        // Filed under itself AND attesting to itself, so the bidirectional check alone would ADMIT it and the
        // holder would be read twice. Only the explicit `sickle == account` guard rejects it.
        MockSickle selfOwned = new MockSickle(address(0));
        selfOwned.setOwner(address(selfOwned));
        factory.setSickle(address(selfOwned), address(selfOwned));

        meta.setAmount(address(selfOwned), address(token), 7);
        assertEq(meta.sickleOf(address(selfOwned)), address(0), "an account is never its own second holder");

        INAVCalculator.PositionBalance[] memory p = _read(address(selfOwned));
        assertEq(p.length, 1, "read once, not twice");
        assertEq(p[0].amount, 7);
    }

    /// @notice The registered-asset gate and `assetFilter` apply to BOTH holders, not just the account.
    function test_filterAndRegistryGateApplyToBothHolders() public {
        address sickle = _deploySickle(alice, alice);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 7);

        MockToken other = new MockToken("OTH", 18);
        assertEq(
            meta.getAdapterPositionsForInstances(alice, _instance(), address(other)).length,
            0,
            "a filter matching neither holder's asset drops both"
        );

        nav.unregisterAssetHelper(address(token));
        assertEq(_read(alice).length, 0, "an unregistered asset drops both holders");
    }

    /// @notice A factory answering with a DIRTY word (upper 96 bits set) is rejected, not masked. Masking would
    ///         admit the Sickle encoded in the low 160 bits, which nobody attested to.
    function test_malformedFactoryWord_rejectedNotMasked() public {
        address realSickle = address(new MockSickle(alice));
        MockDirtyWordFactory dirty = new MockDirtyWordFactory(realSickle);
        TestSickleAdapter m = new TestSickleAdapter(address(nav), address(dirty));
        m.setAmount(alice, address(token), 5);
        m.setAmount(realSickle, address(token), 1_000_000);

        assertEq(m.sickleOf(alice), address(0), "a dirty word is not an address");
        INAVCalculator.PositionBalance[] memory p = m.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 1, "only the account's own leg");
        assertEq(p[0].amount, 5, "the masked-down Sickle's balance is NOT borrowed");
    }

    /// @notice Same rule on the reverse read: a Sickle whose `owner()` is a dirty word is not admitted.
    function test_malformedOwnerWord_rejectedNotMasked() public {
        address sickle = address(new MockDirtyOwnerSickle(alice));
        factory.setSickle(alice, sickle);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 1_000_000);

        assertEq(meta.sickleOf(alice), address(0), "a dirty owner word is not an attestation");
        INAVCalculator.PositionBalance[] memory p = _read(alice);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 5);
    }

    /// @notice `owner() == address(0)` is no attestation at all.
    function test_zeroOwner_notAdmitted() public {
        address sickle = address(new MockZeroOwnerSickle());
        factory.setSickle(alice, sickle);
        meta.setAmount(alice, address(token), 5);
        meta.setAmount(sickle, address(token), 11);

        assertEq(meta.sickleOf(alice), address(0));
        assertEq(_read(alice).length, 1);
    }
}
