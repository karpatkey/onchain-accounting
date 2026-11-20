// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {DeriveBlobBuilder} from "test/balances/AttestedBalanceAdapters/derive/DeriveBlobBuilder.sol";
import {MockDeriveVapp} from "test/balances/AttestedBalanceAdapters/DeriveConformance.t.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {DeriveOptionPricer} from "src/balances/AttestedBalanceAdapters/derive/DeriveOptionPricer.sol";
import {IDeriveOptionPricer} from "src/balances/AttestedBalanceAdapters/derive/IDeriveOptionPricer.sol";
import {DeriveRecord} from "src/balances/AttestedBalanceAdapters/derive/DeriveRecord.sol";
import {CelestiaShareProof} from "src/balances/AttestedBalanceAdapters/derive/CelestiaShareProof.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Unit tests for `DeriveCelestiaAttestedBalanceAdapter`: every acceptance rule on synthetic blobs and
///         signed feeds, plus real Derive batches whose commitments were recorded on Ethereum.
contract DeriveCelestiaAttestedBalanceAdapterTest is BalanceAdapterTestBase {
    using DeriveBlobBuilder for DeriveBlobBuilder.Blob;

    address internal constant DERIVE_A = address(0xD1);
    address internal constant DERIVE_SIX = address(0xD6);
    /// @dev Derive's USDC protocol asset id: the cash asset of the real option batches.
    address internal constant DERIVE_USDC = 0x57B03E14d409ADC7fAb6CFc44b5886CAD2D5f02b;
    /// @dev Derive's HYPE protocol asset id (`WithdrawalOutbox.resolveAsset` → HYPE OFT, 18 decimals).
    address internal constant DERIVE_HYPE = 0x2dd469DB6ee0dBF0277F0f3021fd8a6486A751ce;
    /// @dev hype-split Portfolio Safe, owner of real subaccount 122119.
    address internal constant HYPE_SPLIT_SAFE = 0x8C79753AAD88183f5747C91684d6C0CBfCB27476;

    /// @dev Synthetic option assets. Their feed contracts are derived from `_base`.
    address internal constant OPT_ETH = address(0x0E71);
    address internal constant OPT_BTC = address(0x0B7C);
    address internal constant OPT_HYPE = address(0x0E9A);

    uint256 internal constant KEY_1 = 0xA11CE;
    uint256 internal constant KEY_2 = 0xB0B;
    uint256 internal constant KEY_3 = 0xC0FFEE;

    uint256 internal constant NOW_T = 1_795_000_000;
    uint256 internal constant EXPIRED = NOW_T - 1 days;
    uint256 internal constant LIVE = NOW_T + 30 days;
    uint256 internal constant DEADLINE = NOW_T + 1 days;
    /// @dev Settlement window of an expired series that settled at 60: 1800 samples of 60, starting at 0.
    uint256 internal constant LATEST_EXPIRED = 60e18 * 1800;

    MockDeriveVapp internal vapp;
    DeriveCelestiaAttestedBalanceAdapter internal adapter;
    Mock_ERC20 internal tokenA;
    Mock_ERC20 internal tokenSix;
    Mock_ERC20 internal hype;
    address internal keeper = makeAddr("keeper");
    address[] internal feedSigners;

    function setUp() public override {
        super.setUp();
        vm.warp(NOW_T);
        vapp = new MockDeriveVapp();
        tokenA = new Mock_ERC20("A", 18);
        tokenSix = new Mock_ERC20("SIX", 6);
        hype = new Mock_ERC20("HYPE", 18);
        balances.addSupportedAssetForTest(address(tokenA));
        balances.addSupportedAssetForTest(address(tokenSix));
        balances.addSupportedAssetForTest(address(hype));
        feedSigners = new address[](2);
        feedSigners[0] = vm.addr(KEY_1);
        feedSigners[1] = vm.addr(KEY_2);
        adapter = _deploy(vapp.programVKey(), vapp.verifier());
        bytes32 role = adapter.SUBMITTER_ROLE();
        vm.prank(admin);
        adapter.grantRole(role, keeper);
    }

    function _assets() internal view returns (address[] memory ids, address[] memory toks) {
        ids = new address[](3);
        toks = new address[](3);
        (ids[0], ids[1], ids[2]) = (DERIVE_A, DERIVE_SIX, DERIVE_HYPE);
        (toks[0], toks[1], toks[2]) = (address(tokenA), address(tokenSix), address(hype));
    }

    function _deploy(bytes32 vkey, address verifier) internal returns (DeriveCelestiaAttestedBalanceAdapter) {
        (address[] memory ids, address[] memory toks) = _assets();
        return _construct(ids, toks, DERIVE_SIX, _pricer(_markets(), feedSigners), vkey, verifier);
    }

    function _pricer(IDeriveOptionPricer.OptionMarket[] memory markets, address[] memory sigs)
        internal
        returns (address)
    {
        return _pricer(markets, sigs, _collateralSpots());
    }

    function _pricer(
        IDeriveOptionPricer.OptionMarket[] memory markets,
        address[] memory sigs,
        IDeriveOptionPricer.CollateralSpot[] memory spots
    ) internal returns (address) {
        return address(new DeriveOptionPricer(markets, sigs, spots));
    }

    /// @dev Derive's HYPE collateral is priced at OPT_HYPE's spot feed.
    function _collateralSpots() internal pure returns (IDeriveOptionPricer.CollateralSpot[] memory out) {
        out = new IDeriveOptionPricer.CollateralSpot[](1);
        out[0] = IDeriveOptionPricer.CollateralSpot({collateralAsset: DERIVE_HYPE, optionAsset: OPT_HYPE});
    }

    function _construct(
        address[] memory ids,
        address[] memory toks,
        address cash,
        address pricer,
        bytes32 vkey,
        address verifier
    ) internal returns (DeriveCelestiaAttestedBalanceAdapter) {
        return new DeriveCelestiaAttestedBalanceAdapter(
            address(vapp), address(balances), admin, vkey, verifier, ids, toks, cash, pricer
        );
    }

    /// @dev Reads the pinned program pair before `vm.expectRevert`: an external call in the constructor arguments
    ///      would otherwise take the expectation instead of the deployment.
    function _expectConstructRevert(address[] memory ids, address[] memory toks, address cash, address pricer)
        internal
    {
        bytes32 vkey = vapp.programVKey();
        address verifier = vapp.verifier();
        vm.expectRevert(InvalidArguments.selector);
        _construct(ids, toks, cash, pricer, vkey, verifier);
    }

    function _expectPricerRevert(IDeriveOptionPricer.OptionMarket[] memory markets, address[] memory sigs) internal {
        vm.expectRevert(InvalidArguments.selector);
        new DeriveOptionPricer(markets, sigs, _collateralSpots());
    }

    // ─────────────────────────────────────────────────────────────── helpers

    function _rec(uint256 id, address owner, address asset, int256 bal)
        internal
        pure
        returns (DeriveBlobBuilder.Rec memory r)
    {
        r.id = id;
        r.owner = owner;
        r.coll = new DeriveBlobBuilder.Coll[](1);
        r.coll[0] = DeriveBlobBuilder.Coll(asset, bal);
    }

    function _opt(address asset, uint256 strike8, bool isCall, int256 amount, uint256 expiry)
        internal
        pure
        returns (DeriveBlobBuilder.Opt memory)
    {
        return DeriveBlobBuilder.Opt({asset: asset, strike8: strike8, isCall: isCall, amount: amount, expiry: expiry});
    }

    function _opts1(DeriveBlobBuilder.Opt memory a) internal pure returns (DeriveBlobBuilder.Opt[] memory out) {
        out = new DeriveBlobBuilder.Opt[](1);
        out[0] = a;
    }

    function _ps1(DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
        internal
        pure
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory out)
    {
        out = new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        out[0] = p;
    }

    function _spots1(IDeriveOptionPricer.SpotFeed memory f)
        internal
        pure
        returns (IDeriveOptionPricer.SpotFeed[] memory out)
    {
        out = new IDeriveOptionPricer.SpotFeed[](1);
        out[0] = f;
    }

    function _fwds1(IDeriveOptionPricer.ForwardFeed memory f)
        internal
        pure
        returns (IDeriveOptionPricer.ForwardFeed[] memory out)
    {
        out = new IDeriveOptionPricer.ForwardFeed[](1);
        out[0] = f;
    }

    function _rates1(IDeriveOptionPricer.RateFeed memory f)
        internal
        pure
        returns (IDeriveOptionPricer.RateFeed[] memory out)
    {
        out = new IDeriveOptionPricer.RateFeed[](1);
        out[0] = f;
    }

    function _vols1(IDeriveOptionPricer.VolFeed memory f)
        internal
        pure
        returns (IDeriveOptionPricer.VolFeed[] memory out)
    {
        out = new IDeriveOptionPricer.VolFeed[](1);
        out[0] = f;
    }

    /// @dev Three records: `first` and `second` as given, then 900 owned by someone else to frame `second`.
    function _blob(DeriveBlobBuilder.Rec memory first, DeriveBlobBuilder.Rec memory second)
        internal
        returns (DeriveBlobBuilder.Blob memory b)
    {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](3);
        recs[0] = first;
        recs[1] = second;
        recs[2] = _rec(900, address(0xFEED), DERIVE_A, 1e12);
        b = DeriveBlobBuilder.build(recs);
        vapp.setCommitment(b.commitment);
    }

    function _submit(address account, bytes memory data) internal {
        vm.prank(keeper);
        adapter.submit(account, data);
    }

    function _expectSubmitRevert(address account, bytes memory data, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(keeper);
        adapter.submit(account, data);
    }

    // ─────────────────────────────────────────────────────────────── markets and feeds

    function _base(address asset) internal pure returns (uint160) {
        if (asset == OPT_ETH) return 0x5100;
        if (asset == OPT_BTC) return 0x5200;
        return 0x5300;
    }

    /// @dev The synthetic feed contract of `kind` for `asset`: 1 spot, 2 forward, 3 rate, 4 vol.
    function _feedAddr(address asset, uint160 kind) internal pure returns (address) {
        return address(_base(asset) + kind);
    }

    function _market(address asset) internal pure returns (IDeriveOptionPricer.OptionMarket memory) {
        return IDeriveOptionPricer.OptionMarket({
            optionAsset: asset,
            spotFeed: _feedAddr(asset, 1),
            forwardFeed: _feedAddr(asset, 2),
            rateFeed: _feedAddr(asset, 3),
            volFeed: _feedAddr(asset, 4)
        });
    }

    function _markets() internal pure returns (IDeriveOptionPricer.OptionMarket[] memory m) {
        m = new IDeriveOptionPricer.OptionMarket[](3);
        m[0] = _market(OPT_ETH);
        m[1] = _market(OPT_BTC);
        m[2] = _market(OPT_HYPE);
    }

    function _digest(string memory name, address feed, bytes memory data, uint256 deadline, uint256 timestamp)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                uint256(957),
                feed
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("FeedData(bytes data,uint256 deadline,uint64 timestamp)"),
                keccak256(data),
                deadline,
                timestamp
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _sigOf(uint256 k, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signBy(uint256 ka, uint256 kb, bytes32 digest) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sigOf(ka, digest);
        sigs[1] = _sigOf(kb, digest);
    }

    function _spot(address asset, uint256 price, uint256 ts, uint256 deadline)
        internal
        view
        returns (IDeriveOptionPricer.SpotFeed memory f)
    {
        f = IDeriveOptionPricer.SpotFeed({
            optionAsset: asset,
            price: price,
            confidence: 1e18,
            deadline: deadline,
            timestamp: ts,
            signatures: new bytes[](0)
        });
        f.signatures = _signBy(KEY_1, KEY_2, _spotDigest(f));
    }

    function _spotDigest(IDeriveOptionPricer.SpotFeed memory f) internal pure returns (bytes32) {
        return _digest(
            "LyraSpotFeed", _feedAddr(f.optionAsset, 1), abi.encode(f.price, f.confidence), f.deadline, f.timestamp
        );
    }

    function _fwd(address asset, uint256 expiry, uint256 start, uint256 latest, uint256 ts, uint256 deadline)
        internal
        view
        returns (IDeriveOptionPricer.ForwardFeed memory f)
    {
        f = IDeriveOptionPricer.ForwardFeed({
            optionAsset: asset,
            expiry: expiry,
            settlementStartAggregate: start,
            currentSpotAggregate: latest,
            fwdDiff: 0,
            confidence: 1e18,
            deadline: deadline,
            timestamp: ts,
            signatures: new bytes[](0)
        });
        f.signatures = _signBy(KEY_1, KEY_2, _fwdDigest(f));
    }

    function _fwdDigest(IDeriveOptionPricer.ForwardFeed memory f) internal pure returns (bytes32) {
        return _digest(
            "LyraForwardFeed",
            _feedAddr(f.optionAsset, 2),
            abi.encode(f.expiry, f.settlementStartAggregate, f.currentSpotAggregate, f.fwdDiff, f.confidence),
            f.deadline,
            f.timestamp
        );
    }

    function _rate(address asset, uint256 expiry, uint256 ts, uint256 deadline)
        internal
        view
        returns (IDeriveOptionPricer.RateFeed memory f)
    {
        f = IDeriveOptionPricer.RateFeed({
            optionAsset: asset,
            expiry: expiry,
            rate: 5e16,
            confidence: 1e18,
            deadline: deadline,
            timestamp: ts,
            signatures: new bytes[](0)
        });
        f.signatures = _signBy(KEY_1, KEY_2, _rateDigest(f));
    }

    function _rateDigest(IDeriveOptionPricer.RateFeed memory f) internal pure returns (bytes32) {
        return _digest(
            "LyraRateFeed",
            _feedAddr(f.optionAsset, 3),
            abi.encode(f.expiry, f.rate, f.confidence),
            f.deadline,
            f.timestamp
        );
    }

    function _vol(address asset, uint256 expiry, uint256 ts, uint256 deadline)
        internal
        view
        returns (IDeriveOptionPricer.VolFeed memory f)
    {
        f = IDeriveOptionPricer.VolFeed({
            optionAsset: asset,
            expiry: expiry,
            a: 1e16,
            b: 2e17,
            rho: -1e17,
            m: 0,
            sigma: 2e17,
            sviFwd: 60e18,
            refTau: 1e18,
            confidence: 1e18,
            deadline: deadline,
            timestamp: ts,
            signatures: new bytes[](0)
        });
        f.signatures = _signBy(KEY_1, KEY_2, _volDigest(f));
    }

    function _volDigest(IDeriveOptionPricer.VolFeed memory f) internal pure returns (bytes32) {
        return _digest(
            "LyraVolFeed",
            _feedAddr(f.optionAsset, 4),
            abi.encode(f.expiry, f.a, f.b, f.rho, f.m, f.sigma, f.sviFwd, f.refTau, f.confidence),
            f.deadline,
            f.timestamp
        );
    }

    /// @dev Expired OPT_HYPE series settled at 60 (the forward timestamp is the expiry, as Derive publishes it).
    function _expiredFeeds() internal view returns (IDeriveOptionPricer.Feeds memory fd) {
        fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, LATEST_EXPIRED, EXPIRED, DEADLINE));
    }

    /// @dev alice holds one long 50-call on an expired OPT_HYPE series; bob frames the blob.
    function _expiredBlob() internal returns (DeriveBlobBuilder.Blob memory) {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_SIX, 0);
        r.opts = _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, EXPIRED));
        return _blob(r, _rec(101, bob, DERIVE_A, 1e12));
    }

    /// @dev alice holds one long 50-call on a live OPT_HYPE series.
    function _liveBlob() internal returns (DeriveBlobBuilder.Blob memory) {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_SIX, 0);
        r.opts = _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, LIVE));
        return _blob(r, _rec(101, bob, DERIVE_A, 1e12));
    }

    // ─────────────────────────────────────────────────────────────── happy paths

    function test_submit_cachesCollateralAsOneLeg() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 7 ether);
        assertFalse(isDebt);

        INAVCalculator.PositionBalance[] memory legs = adapter.getAdapterPositions(alice, address(0));
        assertEq(legs.length, 1);
        assertEq(legs[0].amount, 7 ether);
        assertEq(uint8(legs[0].positionKind), uint8(PositionKind.Collateral));
        assertEq(legs[0].protocolBrand, ProtocolIds.DERIVE);
        assertEq(legs[0].protocolId, ProtocolIds.DERIVE_V3);
        assertEq(legs[0].protocolSubId, ProtocolIds.DERIVE_V3_SUBACCOUNTS);
        assertEq(legs[0].positionId, abi.encode(address(vapp)));
        assertEq(legs[0].balanceAdapter, address(adapter));
    }

    function test_submit_sumsSubaccountsOfOneOwner() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, alice, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(1, 101, false);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first = b.shareProof(0);
        vm.prank(keeper);
        adapter.submitSubaccounts(alice, first, ps, abi.encode(DeriveBlobBuilder.noFeeds()));

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 3 ether);
    }

    function test_submit_scalesToTokenDecimalsRoundingDown() public {
        // 1.5 units plus 1e-12: the sub-microunit part cannot be represented at 6 decimals and is dropped.
        DeriveBlobBuilder.Blob memory b =
            _blob(_rec(100, alice, DERIVE_SIX, 1.5e12 + 1), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertEq(amount, 1_500_000);
    }

    function test_lastRecordInSection_needsPreviousRecordFraming() public {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](2);
        recs[0] = _rec(100, bob, DERIVE_A, 1e12);
        recs[1] = _rec(101, alice, DERIVE_A, 4e12);
        DeriveBlobBuilder.Blob memory b = DeriveBlobBuilder.build(recs);
        vapp.setCommitment(b.commitment);

        // After the last record comes the next section, not a record head.
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(1, 101, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.BadBoundary.selector, 101)
        );

        _submit(alice, b.payload(b.proof(1, 101, true)));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 4 ether);
    }

    function test_preview_matchesCache() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 9e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(alice, data);
        _submit(alice, data);
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(alice, address(0));
        assertEq(preview.length, 1);
        assertEq(cached.length, 1);
        assertEq(preview[0].amount, cached[0].amount);
        assertEq(preview[0].balanceAsset.asset, cached[0].balanceAsset.asset);
    }

    // ─────────────────────────────────────────────────────────────── options

    /// @dev S = 60. Long 2 × 50-call (+10 each), long 1 × 50-put (out of the money), short 3 × 70-put (−10 each),
    ///      short 4 × 55-call (−5 each): 10000 + 20 − 30 − 20 = 9970.
    function test_options_expiredIntrinsic_nettedIntoCash() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_SIX, 10_000e12);
        DeriveBlobBuilder.Opt[] memory os = new DeriveBlobBuilder.Opt[](4);
        os[0] = _opt(OPT_HYPE, 50e8, true, 2e12, EXPIRED);
        os[1] = _opt(OPT_HYPE, 50e8, false, 1e12, EXPIRED);
        os[2] = _opt(OPT_HYPE, 70e8, false, -3e12, EXPIRED);
        os[3] = _opt(OPT_HYPE, 55e8, true, -4e12, EXPIRED);
        r.opts = os;
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(_ps1(b.proof(0, 100, false)), _expiredFeeds()));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertFalse(isDebt);
        assertEq(amount, 9_970_000_000);
    }

    /// @dev A short in one subaccount is not netted against cash in another: if it were, a submitter could leave the
    ///      short's subaccount out and over-report. Subaccount 100 (short 2 × 70-put, −20, no cash) is refused even
    ///      though 101 holds 100 USDC.
    function test_revert_shortNotCoveredByOtherSubaccount() public {
        DeriveBlobBuilder.Rec memory r0 = _rec(100, alice, DERIVE_SIX, 0);
        r0.opts = _opts1(_opt(OPT_HYPE, 70e8, false, -2e12, EXPIRED));
        DeriveBlobBuilder.Blob memory b = _blob(r0, _rec(101, alice, DERIVE_SIX, 100e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(1, 101, false);
        _expectSubmitRevert(
            alice,
            b.payload(ps, _expiredFeeds()),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev Within one batch only the option prices can move (new signed feeds); the records cannot. A long call
    ///      worth 10 must read 0 after a resubmit at a settlement that leaves it out of the money, not keep 10.
    function test_options_valueFallingToZeroReplacesCachedCash() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob(); // alice: long 1 × 50-call, no collateral
        _submit(alice, b.payload(_ps1(b.proof(0, 100, false)), _expiredFeeds())); // settles at 60
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertEq(amount, 10_000_000);

        IDeriveOptionPricer.Feeds memory atForty = DeriveBlobBuilder.noFeeds();
        atForty.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, 40e18 * 1800, EXPIRED, DEADLINE));
        _submit(alice, b.payload(_ps1(b.proof(0, 100, false)), atForty));
        (amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertEq(amount, 0);
    }

    function test_revert_liabilityExceedsCollateral() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_SIX, 5e12);
        r.opts = _opts1(_opt(OPT_HYPE, 70e8, false, -3e12, EXPIRED));
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), _expiredFeeds()),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    function test_revert_unmappedOption() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_SIX, 5e12);
        r.opts = _opts1(_opt(address(0xDEAD), 50e8, true, 1e12, EXPIRED));
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false))),
            abi.encodeWithSelector(IDeriveOptionPricer.UnmappedOption.selector, address(0xDEAD))
        );
    }

    // ─────────────────────────────────────────────────────────────── feed verification

    function test_revert_feedSignatureCount() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = _expiredFeeds();
        bytes[] memory one = new bytes[](1);
        one[0] = fd.forwards[0].signatures[0];
        fd.forwards[0].signatures = one;
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedSignatureCount.selector, 1, 2)
        );
    }

    function test_revert_feedUnknownSigner() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = _expiredFeeds();
        fd.forwards[0].signatures = _signBy(KEY_1, KEY_3, _fwdDigest(fd.forwards[0]));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.UnknownSigner.selector, vm.addr(KEY_3))
        );
    }

    function test_revert_feedDuplicateSignature() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = _expiredFeeds();
        fd.forwards[0].signatures = _signBy(KEY_1, KEY_1, _fwdDigest(fd.forwards[0]));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.DuplicateSignature.selector, vm.addr(KEY_1))
        );
    }

    function test_revert_feedExpired() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, LATEST_EXPIRED, EXPIRED, NOW_T - 1));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedExpired.selector, NOW_T - 1)
        );
    }

    function test_revert_feedFromFuture() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, LATEST_EXPIRED, NOW_T + 1, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedFromFuture.selector, NOW_T + 1)
        );
    }

    function test_revert_unmappedFeed() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(address(0xCAFE), EXPIRED, 0, LATEST_EXPIRED, EXPIRED, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.UnmappedFeed.selector, address(0xCAFE))
        );
    }

    function test_revert_unusedFeed() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = _expiredFeeds();
        fd.spots = _spots1(_spot(OPT_BTC, 60e18, NOW_T, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.UnusedFeed.selector, OPT_BTC)
        );
    }

    function test_revert_settlementNotPublished() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, LATEST_EXPIRED, EXPIRED - 1, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.SettlementNotPublished.selector, OPT_HYPE, EXPIRED)
        );
    }

    function test_revert_settlementWindowInverted() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, LATEST_EXPIRED, 0, EXPIRED, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.SettlementWindowInverted.selector, OPT_HYPE, EXPIRED)
        );
    }

    function test_revert_missingForward() public {
        DeriveBlobBuilder.Blob memory b = _expiredBlob();
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), DeriveBlobBuilder.noFeeds()),
            abi.encodeWithSelector(IDeriveOptionPricer.MissingFeed.selector, OPT_HYPE, EXPIRED)
        );
    }

    // ─────────────────────────────────────────────────────────────── live pricing rejections

    function test_revert_liveForwardStale() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T - 301, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedStale.selector, NOW_T - 301)
        );
    }

    function test_revert_liveSpotStale() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        fd.spots = _spots1(_spot(OPT_HYPE, 60e18, NOW_T - 301, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedStale.selector, NOW_T - 301)
        );
    }

    function test_revert_liveMissingSpot() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.MissingSpot.selector, OPT_HYPE)
        );
    }

    function test_revert_liveZeroSpot() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        fd.spots = _spots1(_spot(OPT_HYPE, 0, NOW_T, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.ZeroSpot.selector, OPT_HYPE)
        );
    }

    function test_revert_liveMissingRate() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        fd.spots = _spots1(_spot(OPT_HYPE, 60e18, NOW_T, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.MissingFeed.selector, OPT_HYPE, LIVE)
        );
    }

    function test_revert_liveMissingVol() public {
        DeriveBlobBuilder.Blob memory b = _liveBlob();
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        fd.spots = _spots1(_spot(OPT_HYPE, 60e18, NOW_T, DEADLINE));
        fd.rates = _rates1(_rate(OPT_HYPE, LIVE, NOW_T, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_ps1(b.proof(0, 100, false)), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.MissingFeed.selector, OPT_HYPE, LIVE)
        );
    }

    // ─────────────────────────────────────────────────────────────── staleness

    function test_nextBatch_readsZero() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));
        vapp.setCommitment(keccak256("next batch"));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0);
        assertFalse(adapter.isAttestationLive(alice, address(tokenA)));
    }

    /// @dev Derive stops posting batches but its sequencer keeps trading: the commitment, and so the epoch, stays
    ///      put while the collateral may be spent. The entry must expire with the batch's proven time.
    function test_stalledBatches_readZeroAfterMaxAge() public {
        vapp.setLastOpTimestamp(uint64(block.timestamp));
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));

        skip(adapter.MAX_ATTESTATION_AGE());
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 7 ether, "still live at exactly the max age");

        skip(1);
        (amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0, "same batch, but older than the max age");
        assertFalse(adapter.isAttestationLive(alice, address(tokenA)));
    }

    /// @dev The age is the batch's, not the entry's: neither a first submit made late nor a replay of the same proof
    ///      can make a stalled batch count again.
    function test_revert_lateSubmitOrReplayOfStalledBatch() public {
        uint64 batchTime = uint64(block.timestamp);
        vapp.setLastOpTimestamp(batchTime);
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        _submit(alice, data);

        skip(adapter.MAX_ATTESTATION_AGE() + 1);
        _expectSubmitRevert(
            alice, data, abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.BatchTooOld.selector, batchTime)
        );
        _expectSubmitRevert(
            bob,
            b.payload(b.proof(1, 101, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.BatchTooOld.selector, batchTime)
        );
    }

    function test_programRotation_readsZeroAndRefusesSubmits() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        _submit(alice, data);

        vapp.setProgram(keccak256("new program"), address(0xB0B));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0, "same commitment, but the program changed");
        _expectSubmitRevert(
            alice,
            data,
            abi.encodeWithSelector(
                DeriveCelestiaAttestedBalanceAdapter.ProgramChanged.selector, keccak256("new program"), address(0xB0B)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────── rejections

    function test_revert_wrongOwner() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, bob, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.WrongOwner.selector, 100, bob)
        );
    }

    function test_revert_wrongSubaccountId() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(0, 100, false);
        p.subaccountId = 99;
        _expectSubmitRevert(
            alice,
            b.payload(p),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.WrongSubaccount.selector, 99, 100)
        );
    }

    /// @dev Without a pricer there is nothing to value debt with: a negative balance is refused as before.
    function test_revert_negativeBalance_withoutPricer() public {
        (address[] memory ids, address[] memory toks) = _assets();
        adapter = _construct(ids, toks, address(0), address(0), vapp.programVKey(), vapp.verifier());
        bytes32 role = adapter.SUBMITTER_ROLE();
        vm.prank(admin);
        adapter.grantRole(role, keeper);
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, -5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeBalance.selector, 100, DERIVE_A)
        );
    }

    function test_revert_unmappedAsset() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, address(0xD9), 5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.UnmappedAsset.selector, 100, address(0xD9))
        );
    }

    function test_revert_openPerps() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_A, 5e12);
        r.perps = 2;
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.PerpsNotAllowed.selector, 100, 2)
        );
    }

    function test_revert_subaccountsNotAscending() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, alice, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(1, 101, false);
        ps[1] = b.proof(0, 100, false);
        _expectSubmitRevert(
            alice,
            b.payload(ps),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.SubaccountsNotAscending.selector, 100)
        );
    }

    function test_revert_sameSubaccountTwice() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, bob, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(0, 100, false);
        _expectSubmitRevert(
            alice,
            b.payload(ps),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.SubaccountsNotAscending.selector, 100)
        );
    }

    function test_revert_proofAgainstOlderBatch() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        vapp.setCommitment(keccak256("next batch"));
        _expectSubmitRevert(
            alice, data, abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    // ─────────────────────────────────────────────────────────────── share positions

    /// @dev A blob of at least three shares, and the index of a record that starts in share 0 and ends in share 1.
    function _threeShareBlob() internal returns (DeriveBlobBuilder.Blob memory b, uint256 k) {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](20);
        for (uint256 i; i < recs.length; ++i) {
            recs[i] = _rec(100 + i, bob, DERIVE_A, 1e12);
        }
        b = DeriveBlobBuilder.build(recs);
        assertGe(b.shares.length, 3, "fixture: at least three shares");
        while (b.ends[k] <= DeriveBlobBuilder.FIRST_DATA) ++k;
        assertLt(b.starts[k], DeriveBlobBuilder.FIRST_DATA, "fixture: record straddles shares 0 and 1");
        vapp.setCommitment(b.commitment);
    }

    /// @dev Each share is real, but share 2 is presented as share 1, so the joined bytes are not what Derive
    ///      posted. The share must be checked at the index it claims.
    function test_revert_spliceRealShareFromElsewhere() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(k, 100 + k, false);
        assertEq(p.shares[1].index, 1);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory other = b.shareProof(2);
        other.index = 1;
        p.shares[1] = other;
        _expectSubmitRevert(
            bob, b.payload(p), abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    function test_revert_repeatedShare() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(k, 100 + k, false);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory again = b.shareProof(0);
        again.index = 1;
        p.shares[1] = again;
        _expectSubmitRevert(
            bob, b.payload(p), abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    /// @dev The share count, and so the tree shape every index is checked against, comes from share 0. A later
    ///      share cannot stand in for it.
    function test_revert_firstShareMustBeShareZero() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = b.proof(k, 100 + k, false);

        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first = b.shareProof(1);
        first.index = 0;
        vm.expectRevert(CelestiaShareProof.NotFirstShare.selector);
        vm.prank(keeper);
        adapter.submitSubaccounts(bob, first, ps, abi.encode(DeriveBlobBuilder.noFeeds()));

        first = b.shareProof(1);
        vm.expectRevert(CelestiaShareProof.NotFirstShare.selector);
        vm.prank(keeper);
        adapter.submitSubaccounts(bob, first, ps, abi.encode(DeriveBlobBuilder.noFeeds()));
    }

    // ─────────────────────────────────────────────────────────────── constructor

    function test_constructor_refusesUnreviewedProgram() public {
        (address[] memory ids, address[] memory toks) = _assets();
        address pricer = _pricer(_markets(), feedSigners);
        bytes32 vkey = vapp.programVKey();
        address verifier = vapp.verifier();
        vm.expectRevert(
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.ProgramChanged.selector, vkey, verifier)
        );
        _construct(ids, toks, DERIVE_SIX, pricer, keccak256("some other program"), verifier);
    }

    function test_constructor_refusesDuplicateAssetId() public {
        address[] memory ids = new address[](2);
        address[] memory toks = new address[](2);
        (ids[0], ids[1]) = (DERIVE_A, DERIVE_A);
        (toks[0], toks[1]) = (address(tokenA), address(tokenSix));
        _expectConstructRevert(ids, toks, DERIVE_SIX, _pricer(_markets(), feedSigners));
    }

    function test_constructor_refusesLengthMismatch() public {
        address[] memory ids = new address[](1);
        address[] memory toks = new address[](0);
        ids[0] = DERIVE_A;
        _expectConstructRevert(ids, toks, DERIVE_SIX, _pricer(_markets(), feedSigners));
    }

    function test_constructor_refusesMarketsWithoutCashAsset() public {
        (address[] memory ids, address[] memory toks) = _assets();
        _expectConstructRevert(ids, toks, address(0), _pricer(_markets(), feedSigners));
    }

    function test_constructor_refusesNoSigners() public {
        _expectPricerRevert(_markets(), new address[](0));
    }

    function test_constructor_refusesDuplicateSigner() public {
        address[] memory sigs = new address[](2);
        (sigs[0], sigs[1]) = (vm.addr(KEY_1), vm.addr(KEY_1));
        _expectPricerRevert(_markets(), sigs);
    }

    function test_constructor_refusesZeroFeedAddress() public {
        IDeriveOptionPricer.OptionMarket[] memory m = _markets();
        m[0].spotFeed = address(0);
        _expectPricerRevert(m, feedSigners);
    }

    // ─────────────────────────────────────────────────────────────── debt and covered options

    /// @dev HYPE spot of the synthetic CDP cases, and the expired series' settlement (60, see `LATEST_EXPIRED`).
    uint256 internal constant SPOT = 60e18;

    function _c(address asset, int256 bal) internal pure returns (DeriveBlobBuilder.Coll memory) {
        return DeriveBlobBuilder.Coll(asset, bal);
    }

    function _coll2(DeriveBlobBuilder.Coll memory a, DeriveBlobBuilder.Coll memory b)
        internal
        pure
        returns (DeriveBlobBuilder.Coll[] memory out)
    {
        out = new DeriveBlobBuilder.Coll[](2);
        (out[0], out[1]) = (a, b);
    }

    function _recWith(
        uint256 id,
        address owner,
        DeriveBlobBuilder.Coll[] memory coll,
        DeriveBlobBuilder.Opt[] memory opts
    ) internal pure returns (DeriveBlobBuilder.Rec memory r) {
        r.id = id;
        r.owner = owner;
        r.coll = coll;
        r.opts = opts;
    }

    function _noOpts() internal pure returns (DeriveBlobBuilder.Opt[] memory) {
        return new DeriveBlobBuilder.Opt[](0);
    }

    /// @dev `recs` (ids 100, 101, ...) followed by 900, owned by someone else, to frame the last one.
    function _blobOf(DeriveBlobBuilder.Rec[] memory recs) internal returns (DeriveBlobBuilder.Blob memory b) {
        DeriveBlobBuilder.Rec[] memory all = new DeriveBlobBuilder.Rec[](recs.length + 1);
        for (uint256 i; i < recs.length; ++i) {
            all[i] = recs[i];
        }
        all[recs.length] = _rec(900, address(0xFEED), DERIVE_A, 1e12);
        b = DeriveBlobBuilder.build(all);
        vapp.setCommitment(b.commitment);
    }

    function _blob1(DeriveBlobBuilder.Rec memory r) internal returns (DeriveBlobBuilder.Blob memory) {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](1);
        recs[0] = r;
        return _blobOf(recs);
    }

    /// @dev The proofs of the first `n` records of `b`, ids 100 + k.
    function _proofsOf(DeriveBlobBuilder.Blob memory b, uint256 n)
        internal
        pure
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps)
    {
        ps = new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](n);
        for (uint256 k; k < n; ++k) {
            ps[k] = b.proof(k, 100 + k, false);
        }
    }

    /// @dev Spot item only: prices collateral, no option series.
    function _spotFeeds(uint256 price) internal view returns (IDeriveOptionPricer.Feeds memory fd) {
        fd = DeriveBlobBuilder.noFeeds();
        fd.spots = _spots1(_spot(OPT_HYPE, price, NOW_T, DEADLINE));
    }

    /// @dev The expired series settled at 60, and the HYPE spot.
    function _expiredAndSpot(uint256 price) internal view returns (IDeriveOptionPricer.Feeds memory fd) {
        fd = _expiredFeeds();
        fd.spots = _spots1(_spot(OPT_HYPE, price, NOW_T, DEADLINE));
    }

    function _hypeLeg(address account) internal view returns (uint256 amount) {
        bool isDebt;
        (amount, isDebt) = adapter.getAdapterBalanceForAsset(account, address(hype));
        assertFalse(isDebt);
    }

    function _cashLeg(address account) internal view returns (uint256 amount) {
        bool isDebt;
        (amount, isDebt) = adapter.getAdapterBalanceForAsset(account, address(tokenSix));
        assertFalse(isDebt);
    }

    /// @dev Equity 50 = HYPE 60 − USDC 20 + a 50-call worth 10 (settled at 60). The cash side nets to −10, so the
    ///      HYPE leg gives up 10 / 60 HYPE, rounded up against the fund: 1 − 0.166666666667, not … 666.
    function test_cdp_longCallWithUsdcDebt_shortfallTakenFromHype() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -20e12)),
            _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredAndSpot(SPOT)));

        assertEq(_hypeLeg(alice), 0.833333333333 ether);
        assertEq(_cashLeg(alice), 0);
        // The legs are worth no more than the equity (50) at the signed spot: 0.833333333333 × 60 = 49.99999999998.
        assertLe((_hypeLeg(alice) / 1e6) * 60, 50e12);
    }

    /// @dev The long call alone clears the debt: HYPE stays whole, the surplus is cash. 60 − 5 + 10 = 65.
    function test_cdp_longCallCoversDebt_hypeKeptWhole() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -5e12)),
            _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredAndSpot(SPOT)));

        assertEq(_hypeLeg(alice), 1 ether);
        assertEq(_cashLeg(alice), 5_000_000);
    }

    /// @dev Live Black-76 call bought on credit: the option's value (from the pricer itself) pays down the USDC debt
    ///      and the HYPE leg gives up the rest.
    function test_cdp_liveLongCallWithUsdcDebt() public {
        DeriveBlobBuilder.Opt[] memory os = _opts1(_opt(OPT_HYPE, 75e8, true, 10e12, LIVE));
        DeriveBlobBuilder.Rec memory r = _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -20e12)), os);
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.spots = _spots1(_spot(OPT_HYPE, SPOT, NOW_T, DEADLINE));
        fd.forwards = _fwds1(_fwd(OPT_HYPE, LIVE, 0, 0, NOW_T, DEADLINE));
        fd.rates = _rates1(_rate(OPT_HYPE, LIVE, NOW_T, DEADLINE));
        fd.vols = _vols1(_vol(OPT_HYPE, LIVE, NOW_T, DEADLINE));

        DeriveRecord.Option[] memory one = new DeriveRecord.Option[](1);
        one[0] = DeriveRecord.Option({
            asset: OPT_HYPE, subId: DeriveBlobBuilder.optionSubId(LIVE, 75e8, true), amount: 10e12
        });
        (int256[] memory v,) = adapter.PRICER().values(abi.encode(fd), one, new address[](0));
        assertGt(v[0], 0);
        assertLt(v[0], 20e12); // the debt is not covered by the option alone

        _submit(alice, b.payload(_proofsOf(b, 1), fd));

        // shortfall = 20 − option value (12 decimals); the HYPE leg gives up the units worth it, rounded up.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 shortfall = 20e12 - uint256(v[0]);
        uint256 given = (shortfall * 1e18 + SPOT - 1) / SPOT;
        assertEq(_hypeLeg(alice), (1e12 - given) * 1e6);
        assertEq(_cashLeg(alice), 0);
    }

    /// @dev Long put in the money (strike 70 against 60: +10) on top of cash: it is credited to cash.
    function test_cdp_longPut_creditedToCash() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_SIX, 100e12), _c(DERIVE_HYPE, 0)),
            _opts1(_opt(OPT_HYPE, 70e8, false, 1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredFeeds()));
        assertEq(_cashLeg(alice), 110_000_000);
        assertEq(_hypeLeg(alice), 0);
    }

    /// @dev Covered call: HYPE 1, short 50-call (−10), no USDC. Before: `LiabilityExceedsCollateral`.
    function test_cdp_shortCallCoveredByHype() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, 0)),
            _opts1(_opt(OPT_HYPE, 50e8, true, -1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredAndSpot(SPOT)));
        assertEq(_hypeLeg(alice), 0.833333333333 ether);
        assertEq(_cashLeg(alice), 0);
    }

    /// @dev Cash-secured put: USDC 100, short 70-put (−10): 90 cash, no spot needed.
    function test_cdp_shortPutCoveredByUsdc_needsNoSpot() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_SIX, 100e12), _c(DERIVE_HYPE, 0)),
            _opts1(_opt(OPT_HYPE, 70e8, false, -1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredFeeds()));
        assertEq(_cashLeg(alice), 90_000_000);
    }

    /// @dev Put covered by HYPE (2 HYPE = 120, short 70-put −10): HYPE gives up 10 / 60.
    function test_cdp_shortPutCoveredByHype() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 2e12), _c(DERIVE_SIX, 0)),
            _opts1(_opt(OPT_HYPE, 70e8, false, -1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _expiredAndSpot(SPOT)));
        assertEq(_hypeLeg(alice), 1.833333333333 ether);
        assertEq(_cashLeg(alice), 0);
    }

    /// @dev A pure USDC borrow against HYPE, no options: the pricer is called for the HYPE spot alone.
    function test_cdp_pureUsdcBorrowAgainstHype() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -6e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _spotFeeds(SPOT)));
        assertEq(_hypeLeg(alice), 0.9 ether); // 1 − 6 / 60
        assertEq(_cashLeg(alice), 0);
    }

    function test_cdp_pureBorrow_previewMatchesCache() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -6e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        bytes memory data = b.payload(_proofsOf(b, 1), _spotFeeds(SPOT));
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(alice, data);
        _submit(alice, data);
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(alice, address(0));
        assertEq(preview.length, cached.length);
        for (uint256 i; i < cached.length; ++i) {
            assertEq(preview[i].amount, cached[i].amount);
            assertEq(preview[i].balanceAsset.asset, cached[i].balanceAsset.asset);
        }
    }

    function test_cdp_pureBorrow_needsSpotItem() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -6e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), DeriveBlobBuilder.noFeeds()),
            abi.encodeWithSelector(IDeriveOptionPricer.MissingSpot.selector, OPT_HYPE)
        );
    }

    function test_cdp_pureBorrow_staleSpotRefused() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -6e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.spots = _spots1(_spot(OPT_HYPE, SPOT, NOW_T - 301, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.FeedStale.selector, NOW_T - 301)
        );
    }

    function test_cdp_pureBorrow_unusedFeedRefused() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -6e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        IDeriveOptionPricer.Feeds memory fd = _spotFeeds(SPOT);
        fd.forwards = _fwds1(_fwd(OPT_HYPE, EXPIRED, 0, LATEST_EXPIRED, EXPIRED, DEADLINE));
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), fd),
            abi.encodeWithSelector(IDeriveOptionPricer.UnusedFeed.selector, OPT_HYPE)
        );
    }

    /// @dev A debt in an asset with no spot mapping cannot be valued.
    function test_cdp_revert_debtInAssetWithoutSpot() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, -5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(IDeriveOptionPricer.UnmappedSpotAsset.selector, DERIVE_A)
        );
    }

    /// @dev Equity −5: a debt and nothing to cover it.
    function test_cdp_revert_debtWithoutCollateral() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_SIX, -5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev HYPE worth 60 against a 61 USDC debt: equity −1.
    function test_cdp_revert_debtExceedsHypeValue() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -61e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), _spotFeeds(SPOT)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev Long option plus HYPE cannot hide a bigger debt: 60 + 10 − 71 < 0.
    function test_cdp_revert_equityNegativeWithLongOption() public {
        DeriveBlobBuilder.Rec memory r = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -71e12)),
            _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, EXPIRED))
        );
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), _expiredAndSpot(SPOT)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev Equity exactly 0 is accepted and writes zero legs: HYPE 1 (60) against a 60 USDC debt.
    function test_cdp_zeroEquity_writesZeroLegs() public {
        _submit(alice, _zeroEquityData());
        assertEq(_hypeLeg(alice), 0);
        assertEq(_cashLeg(alice), 0);
        assertTrue(adapter.isAttestationLive(alice, address(hype)));
        assertTrue(adapter.isAttestationLive(alice, address(tokenSix)));
    }

    function _zeroEquityData() internal returns (bytes memory) {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -60e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        return b.payload(_proofsOf(b, 1), _spotFeeds(SPOT));
    }

    /// @dev One more unit of debt than the collateral is worth (rounded up at spot) is below zero.
    function test_cdp_revert_oneUnitOverZeroEquity() public {
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -60e12 - 1)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 1), _spotFeeds(SPOT)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev Three subaccounts of one owner. 100: HYPE 1, USDC −20, long call (+10) → HYPE 0.833…, no cash.
    ///      101: USDC 100, short 70-put (−10) → 90 cash. 102: HYPE 0.5, nothing else → as is.
    ///      100's shortfall is taken from 100's HYPE although 101 holds cash, and omitting 101 only lowers the total.
    function test_cdp_mixedSubaccounts_neverNetAcross() public {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](3);
        recs[0] = _recWith(
            100,
            alice,
            _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -20e12)),
            _opts1(_opt(OPT_HYPE, 50e8, true, 1e12, EXPIRED))
        );
        recs[1] = _recWith(
            101,
            alice,
            _coll2(_c(DERIVE_SIX, 100e12), _c(DERIVE_HYPE, 0)),
            _opts1(_opt(OPT_HYPE, 70e8, false, -1e12, EXPIRED))
        );
        recs[2] = _recWith(102, alice, _coll2(_c(DERIVE_HYPE, 0.5e12), _c(DERIVE_SIX, 0)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blobOf(recs);

        _submit(alice, b.payload(_proofsOf(b, 3), _expiredAndSpot(SPOT)));
        assertEq(_hypeLeg(alice), 1.333333333333 ether); // 0.833333333333 + 0.5
        assertEq(_cashLeg(alice), 90_000_000);

        // Omit 101: its cash goes, 100's HYPE is not restored.
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(2, 102, false);
        _submit(alice, b.payload(ps, _expiredAndSpot(SPOT)));
        assertEq(_hypeLeg(alice), 1.333333333333 ether);
        assertEq(_cashLeg(alice), 0);
    }

    /// @dev A deficit in one subaccount is not netted against another's surplus: 100 holds HYPE 1 and owes 61 USDC.
    function test_cdp_revert_deficitNotCoveredByOtherSubaccount() public {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](2);
        recs[0] = _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -61e12)), _noOpts());
        recs[1] = _recWith(101, alice, _coll2(_c(DERIVE_SIX, 1000e12), _c(DERIVE_HYPE, 0)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blobOf(recs);
        _expectSubmitRevert(
            alice,
            b.payload(_proofsOf(b, 2), _spotFeeds(SPOT)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeEquity.selector, 100)
        );
    }

    /// @dev Rounding of the shortfall: HYPE 1, USDC −5, spot 61.7. Units given up are 5 / 61.7 rounded UP
    ///      (81037277148, not …147), so the legs are worth at most the equity 56.7 and within one spot-unit of it.
    function test_cdp_rounding_shortfallUnitsRoundUp() public {
        uint256 spot = 61.7e18;
        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_HYPE, 1e12), _c(DERIVE_SIX, -5e12)), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _spotFeeds(spot)));

        uint256 units12 = _hypeLeg(alice) / 1e6;
        assertEq(units12, 1e12 - 81_037_277_148);
        uint256 legUsd12 = units12 * spot / 1e18; // 12-decimal USD at the signed spot, rounded down
        assertLe(legUsd12, 56.7e12);
        assertLt(56.7e12 - legUsd12, spot / 1e18 + 1);
    }

    /// @dev Rounding of a non-cash debt: USDC 100 and a HYPE debt of 1 + 1e-12 at spot 61.7 is 61.7 + 6.17e-11,
    ///      rounded UP to 61.700000000062. Cash is an 18-decimal token here, so the 12-decimal result shows.
    function test_cdp_rounding_nonCashDebtRoundsUp() public {
        (address[] memory ids, address[] memory toks) = _assets();
        adapter = _construct(
            ids,
            toks,
            DERIVE_A,
            _pricer(_markets(), feedSigners, _collateralSpots()),
            vapp.programVKey(),
            vapp.verifier()
        );
        bytes32 role = adapter.SUBMITTER_ROLE();
        vm.prank(admin);
        adapter.grantRole(role, keeper);

        DeriveBlobBuilder.Rec memory r =
            _recWith(100, alice, _coll2(_c(DERIVE_A, 100e12), _c(DERIVE_HYPE, -(1e12 + 1))), _noOpts());
        DeriveBlobBuilder.Blob memory b = _blob1(r);
        _submit(alice, b.payload(_proofsOf(b, 1), _spotFeeds(61.7e18)));

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 38_299_999_999_938 * 1e6); // 100 − 61.700000000062
        assertEq(_hypeLeg(alice), 0);
    }

    /// @dev A submit holding only non-negative collateral needs no feeds even with a pricer set, as before.
    function test_cdp_plainCollateral_needsNoPricerCall() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_HYPE, 3e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));
        assertEq(_hypeLeg(alice), 3 ether);
    }

    function test_pricer_constructor_refusesCollateralSpotOfUnknownMarket() public {
        IDeriveOptionPricer.CollateralSpot[] memory spots = _collateralSpots();
        spots[0].optionAsset = address(0xDEAD);
        vm.expectRevert(InvalidArguments.selector);
        new DeriveOptionPricer(_markets(), feedSigners, spots);
    }

    function test_pricer_constructor_refusesDuplicateCollateralSpot() public {
        IDeriveOptionPricer.CollateralSpot[] memory spots = new IDeriveOptionPricer.CollateralSpot[](2);
        spots[0] = IDeriveOptionPricer.CollateralSpot({collateralAsset: DERIVE_HYPE, optionAsset: OPT_HYPE});
        spots[1] = IDeriveOptionPricer.CollateralSpot({collateralAsset: DERIVE_HYPE, optionAsset: OPT_ETH});
        vm.expectRevert(InvalidArguments.selector);
        new DeriveOptionPricer(_markets(), feedSigners, spots);
    }

    // ─────────────────────────────────────────────────────────────── real Derive batches

    /// @dev hype-split's subaccount 122119, from the blob of the Ethereum batch at block 26,450,225 (Celestia
    ///      16,041,645). The blob's subtree width is 16, so this exercises real NMT paths.
    function test_realBatch_hypeSplitSubaccount() public {
        (bytes memory data,, bytes32 commitment) = _loadReal("hype_split_122119.json");
        vapp.setCommitment(commitment);
        _submit(HYPE_SPLIT_SAFE, data);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HYPE_SPLIT_SAFE, address(hype));
        assertEq(amount, 0.12 ether);
    }

    /// @dev Subaccount 108093 holds 2 perps in the batch at block 26,450,577 (Celestia 16,043,118), a real record
    ///      spanning 23 shares. Perps are not valued, so the batch is refused.
    function test_realBatch_perpsRefused() public {
        (bytes memory data,, bytes32 commitment) = _loadReal("sub_108093.json");
        vapp.setCommitment(commitment);
        address owner = 0x6845630cB654E050312e0Cb4169b19e83De5Eb08;
        _expectSubmitRevert(
            owner,
            data,
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.PerpsNotAllowed.selector, 108093, 2)
        );
    }

    function test_realBatch_alteredShareRefused() public {
        (, DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first, bytes32 commitment) =
            _loadReal("hype_split_122119.json");
        string memory json = _readFixture("hype_split_122119.json");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _proofFrom(json);
        vapp.setCommitment(commitment);
        bytes memory s = ps[0].shares[0].share;
        s[300] = bytes1(uint8(s[300]) ^ 0x01);
        _expectSubmitRevert(
            HYPE_SPLIT_SAFE,
            abi.encode(first, ps, abi.encode(DeriveBlobBuilder.noFeeds())),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    /// @dev Subaccount 117522 (USDC, 6 ETH and 2 BTC options, long and short), priced from Derive's real signed feeds
    ///      in `mark_feeds.json` at `valuationTime`. Pins the adapter's output for this fixture, which the proof
    ///      script's float reference also gives (`script/test/test_derive_celestia_proof.py`). Not a comparison with
    ///      Derive's API: the feeds changed between fetches, so `margin_watch` marks of that moment differ by up to 0.9%.
    function test_realBatch_optionsAt117522() public {
        string memory feeds = _readFixture("mark_feeds.json");
        (bytes memory data, bytes32 commitment, address owner) =
            _loadMark(_readFixture("mark_117522.json"), feeds, ".subaccounts.117522");
        _deployReal(feeds);
        vapp.setCommitment(commitment);
        vm.warp(vm.parseJsonUint(feeds, ".valuationTime"));

        uint256 g = gasleft();
        _submit(owner, data);
        emit log_named_uint("117522 submit gas", g - gasleft());

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(owner, address(tokenSix));
        assertFalse(isDebt);
        assertEq(amount, 26_015_997_422);
    }

    /// @dev Subaccount 119408 (HYPE puts, one long and one short), priced from Derive's real signed feeds. Pins the
    ///      adapter's output, which the proof script's float reference also gives.
    function test_realBatch_optionsAt119408() public {
        string memory feeds = _readFixture("mark_feeds.json");
        (bytes memory data, bytes32 commitment, address owner) =
            _loadMark(_readFixture("mark_119408.json"), feeds, ".subaccounts.119408");
        _deployReal(feeds);
        vapp.setCommitment(commitment);
        vm.warp(vm.parseJsonUint(feeds, ".valuationTime"));

        _submit(owner, data);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(owner, address(tokenSix));
        assertFalse(isDebt);
        assertEq(amount, 88_801_606_434);
    }

    /// @dev The proof script's output, unedited, end to end: `derive-celestia-proof.py --pick-options` picked
    ///      subaccount 67937 (USDC and six long ETH calls over 4 expiries) and wrote its share proof, Derive's signed
    ///      feeds as fetched, and `expected` from the script's float reference of the pricer. Passing means the
    ///      script encodes feeds exactly as Derive signed them and the two pricers agree; the 1 micro-USDC allows the
    ///      reference's float error to cross the 6-decimal floor.
    function test_scriptFixture_optionsMatchReference() public {
        string memory json = _readFixture("script_options_67937.json");
        (bytes memory data, bytes32 commitment, address owner) = _loadMark(json, json, ".feeds");
        _deployReal(json);
        vapp.setCommitment(commitment);
        vm.warp(vm.parseJsonUint(json, ".valuationTime"));

        _submit(owner, data);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(owner, address(tokenSix));
        assertFalse(isDebt);
        assertApproxEqAbs(amount, vm.parseJsonUint(json, ".expected[0].amount"), 1);
    }

    /// @dev Derive's real signatures, one field moved by 1 wei: the digest changes, so the recovered address is no
    ///      signer and the submit is refused.
    function test_realFeeds_alteredFieldRefused() public {
        string memory feeds = _readFixture("mark_feeds.json");
        IDeriveOptionPricer.Feeds memory fd = _loadFeeds(feeds, ".subaccounts.119408");
        fd.spots[0].price += 1;
        _expectRealFeedsRefused(feeds, fd);
    }

    /// @dev A genuine HYPE spot item presented as ETH's: the EIP-712 domain is ETH's spot feed contract, which Derive
    ///      did not sign it under.
    function test_realFeeds_otherMarketsDomainRefused() public {
        string memory feeds = _readFixture("mark_feeds.json");
        IDeriveOptionPricer.Feeds memory fd = _loadFeeds(feeds, ".subaccounts.119408");
        fd.spots[0].optionAsset = vm.parseJsonAddress(feeds, ".optionAssets.ETH");
        _expectRealFeedsRefused(feeds, fd);
    }

    function _expectRealFeedsRefused(string memory feeds, IDeriveOptionPricer.Feeds memory fd) internal {
        string memory json = _readFixture("mark_119408.json");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _markProof(json);
        bytes memory data = abi.encode(_shareFrom(json, ".firstShare"), ps, abi.encode(fd));
        _deployReal(feeds);
        vapp.setCommitment(vm.parseJsonBytes32(json, ".commitment"));
        vm.warp(vm.parseJsonUint(feeds, ".valuationTime"));
        vm.expectPartialRevert(IDeriveOptionPricer.UnknownSigner.selector);
        vm.prank(keeper);
        adapter.submit(vm.parseJsonAddress(json, ".account"), data);
    }

    /// @dev hype-split's subaccount 122119 after it bought 10 × HYPE-20261127-75-C on credit: 0.12 HYPE, −3.890496741630
    ///      USDC and the calls. The record is from the batch at Ethereum block 26,456,460 (2026-11-20 12:59 UTC); the
    ///      signed feeds and Derive's `margin_watch` were captured together at 2026-11-22 20:03:07 UTC (the account
    ///      had not changed). The adapter's legs, priced at the signed HYPE spot, must match `margin_watch`'s
    ///      `subaccount_value` (5.715103424349 USD) within 0.1%.
    function test_realBatch_hypeSplitCdp_matchesMarginWatch() public {
        string memory json = _readFixture("hype_split_122119_cdp.json");
        (bytes memory data, bytes32 commitment, address owner) = _loadMark("hype_split_122119_cdp.json", json);
        _deployReal(json);
        vapp.setCommitment(commitment);
        vm.warp(vm.parseJsonUint(json, ".valuationTime"));
        assertEq(owner, HYPE_SPLIT_SAFE);

        uint256 g = gasleft();
        _submit(owner, data);
        emit log_named_uint("122119 CDP submit gas", g - gasleft());

        uint256 hypeUnits12 = _hypeLeg(owner) / 1e6;
        uint256 cash12 = _cashLeg(owner) * 1e6;
        uint256 spot = vm.parseJsonUint(json, ".subaccounts.122119.spots[0].price");
        uint256 adapterUsd12 = hypeUnits12 * spot / 1e18 + cash12;
        uint256 derive12 = vm.parseJsonUint(json, ".marginWatch.subaccountValueE12");
        emit log_named_uint("HYPE leg, 12 decimals", hypeUnits12);
        emit log_named_uint("USDC leg, 12 decimals", cash12);
        emit log_named_uint("adapter USD, 12 decimals", adapterUsd12);
        emit log_named_uint("margin_watch USD, 12 decimals", derive12);

        // The USDC debt and the option's value net to a negative cash side, so the HYPE leg carries the shortfall.
        assertEq(cash12, 0);
        assertLt(hypeUnits12, 0.12e12);
        uint256 diff = adapterUsd12 > derive12 ? adapterUsd12 - derive12 : derive12 - adapterUsd12;
        assertLe(diff * 1000, derive12);
    }

    /// @dev Derive's published settlement of an expired ETH series, replayed through the adapter: a long 1800-call
    ///      of 1 unit must net to the intrinsic value at Derive's settlement, 1819.511710943306 − 1800.
    function test_realBatch_expiredSettlementMatchesDerive() public {
        string memory feeds = _readFixture("mark_feeds.json");
        _deployReal(feeds);
        vm.warp(vm.parseJsonUint(feeds, ".valuationTime"));

        address eth = vm.parseJsonAddress(feeds, ".optionAssets.ETH");
        uint256 expiry = vm.parseJsonUint(feeds, ".expiredSettlement.forward.expiry");
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_USDC, 0);
        r.opts = _opts1(_opt(eth, 1800e8, true, 1e12, expiry));
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        IDeriveOptionPricer.Feeds memory fd = DeriveBlobBuilder.noFeeds();
        fd.forwards = _fwds1(_fwdOf(feeds, ".expiredSettlement.forward", eth));
        _submit(alice, b.payload(_ps1(b.proof(0, 100, false)), fd));

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertEq(amount, 19_511_710);
    }

    // ─────────────────────────────────────────────────────────────── real-batch fixtures

    /// @dev Real-batch adapter: the Derive assets of the fixtures, and the option markets and signers in `feeds`.
    function _deployReal(string memory feeds) internal {
        address[] memory ids = new address[](2);
        address[] memory toks = new address[](2);
        (ids[0], ids[1]) = (DERIVE_USDC, DERIVE_HYPE);
        (toks[0], toks[1]) = (address(tokenSix), address(hype));
        adapter = _construct(
            ids,
            toks,
            DERIVE_USDC,
            _pricer(_realMarkets(feeds), vm.parseJsonAddressArray(feeds, ".signers"), _realCollateralSpots(feeds)),
            vapp.programVKey(),
            vapp.verifier()
        );
        bytes32 role = adapter.SUBMITTER_ROLE();
        vm.prank(admin);
        adapter.grantRole(role, keeper);
    }

    /// @dev Derive's HYPE collateral is priced at the real HYPE option market's spot feed.
    function _realCollateralSpots(string memory feeds)
        internal
        view
        returns (IDeriveOptionPricer.CollateralSpot[] memory out)
    {
        out = new IDeriveOptionPricer.CollateralSpot[](1);
        out[0] = IDeriveOptionPricer.CollateralSpot({
            collateralAsset: DERIVE_HYPE, optionAsset: vm.parseJsonAddress(feeds, ".optionAssets.HYPE")
        });
    }

    function _realMarkets(string memory feeds) internal view returns (IDeriveOptionPricer.OptionMarket[] memory m) {
        m = new IDeriveOptionPricer.OptionMarket[](3);
        m[0] = _realMarket(feeds, "ETH");
        m[1] = _realMarket(feeds, "BTC");
        m[2] = _realMarket(feeds, "HYPE");
    }

    function _realMarket(string memory feeds, string memory sym)
        internal
        view
        returns (IDeriveOptionPricer.OptionMarket memory)
    {
        string memory fc = string.concat(".feedContracts.", sym);
        return IDeriveOptionPricer.OptionMarket({
            optionAsset: vm.parseJsonAddress(feeds, string.concat(".optionAssets.", sym)),
            spotFeed: vm.parseJsonAddress(feeds, string.concat(fc, ".spot")),
            forwardFeed: vm.parseJsonAddress(feeds, string.concat(fc, ".forward")),
            rateFeed: vm.parseJsonAddress(feeds, string.concat(fc, ".rate")),
            volFeed: vm.parseJsonAddress(feeds, string.concat(fc, ".vol"))
        });
    }

    /// @param json  A proof-script fixture (one subaccount proof).
    /// @param feeds The JSON holding that subaccount's signed feeds at `base` (see {_loadFeeds}).
    /// @return data       The submit payload: share 0, the subaccount's proof, and its signed feeds.
    /// @return commitment The commitment the Ethereum batch recorded for that blob.
    /// @return owner      The account the batch belongs to.
    function _loadMark(string memory json, string memory feeds, string memory base)
        internal
        view
        returns (bytes memory data, bytes32 commitment, address owner)
    {
        commitment = vm.parseJsonBytes32(json, ".commitment");
        owner = vm.parseJsonAddress(json, ".account");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _markProof(json);
        data = abi.encode(_shareFrom(json, ".firstShare"), ps, abi.encode(_loadFeeds(feeds, base)));
    }

    function _markProof(string memory json)
        internal
        view
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
    {
        p.subaccountId = vm.parseJsonUint(json, ".proofs[0].subaccountId");
        p.recordOffset = vm.parseJsonUint(json, ".proofs[0].recordOffset");
        p.usePrevious = vm.parseJsonBool(json, ".proofs[0].usePrevious");
        p.prevOffset = vm.parseJsonUint(json, ".proofs[0].prevOffset");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".proofs[0].shares[", vm.toString(n), "]"))) ++n;
        p.shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](n);
        for (uint256 i; i < n; ++i) {
            p.shares[i] = _shareFrom(json, string.concat(".proofs[0].shares[", vm.toString(i), "]"));
        }
    }

    /// @dev The signed feeds at `base` (`mark_feeds.json`'s `.subaccounts.<id>`, or a proof-script fixture's `.feeds`):
    ///      its spots, and per expiry its forward, plus a rate and a vol when the expiry is live (has `rate`). Each
    ///      feed's option asset comes from its `currency`.
    function _loadFeeds(string memory feeds, string memory base)
        internal
        view
        returns (IDeriveOptionPricer.Feeds memory fd)
    {
        uint256 ns;
        while (vm.keyExistsJson(feeds, string.concat(base, ".spots[", vm.toString(ns), "].price"))) ++ns;
        uint256 ne;
        uint256 nl;
        for (; vm.keyExistsJson(feeds, string.concat(base, ".expiries[", vm.toString(ne), "].currency")); ++ne) {
            if (vm.keyExistsJson(feeds, string.concat(base, ".expiries[", vm.toString(ne), "].rate"))) ++nl;
        }

        fd = DeriveBlobBuilder.noFeeds();
        fd.spots = new IDeriveOptionPricer.SpotFeed[](ns);
        for (uint256 i; i < ns; ++i) {
            string memory p = string.concat(base, ".spots[", vm.toString(i), "]");
            fd.spots[i] = _spotOf(feeds, p, _assetOf(feeds, p));
        }
        fd.forwards = new IDeriveOptionPricer.ForwardFeed[](ne);
        fd.rates = new IDeriveOptionPricer.RateFeed[](nl);
        fd.vols = new IDeriveOptionPricer.VolFeed[](nl);
        uint256 l;
        for (uint256 i; i < ne; ++i) {
            string memory e = string.concat(base, ".expiries[", vm.toString(i), "]");
            address asset = _assetOf(feeds, e);
            fd.forwards[i] = _fwdOf(feeds, string.concat(e, ".forward"), asset);
            if (!vm.keyExistsJson(feeds, string.concat(e, ".rate"))) continue;
            fd.rates[l] = _rateOf(feeds, string.concat(e, ".rate"), asset);
            fd.vols[l++] = _volOf(feeds, string.concat(e, ".vol"), asset);
        }
    }

    function _assetOf(string memory feeds, string memory p) internal view returns (address) {
        string memory sym = vm.parseJsonString(feeds, string.concat(p, ".currency"));
        return vm.parseJsonAddress(feeds, string.concat(".optionAssets.", sym));
    }

    function _spotOf(string memory feeds, string memory p, address asset)
        internal
        view
        returns (IDeriveOptionPricer.SpotFeed memory f)
    {
        f.optionAsset = asset;
        f.price = vm.parseJsonUint(feeds, string.concat(p, ".price"));
        f.confidence = vm.parseJsonUint(feeds, string.concat(p, ".confidence"));
        f.deadline = vm.parseJsonUint(feeds, string.concat(p, ".deadline"));
        f.timestamp = vm.parseJsonUint(feeds, string.concat(p, ".timestamp"));
        f.signatures = vm.parseJsonBytesArray(feeds, string.concat(p, ".signatures"));
    }

    function _fwdOf(string memory feeds, string memory p, address asset)
        internal
        view
        returns (IDeriveOptionPricer.ForwardFeed memory f)
    {
        f.optionAsset = asset;
        f.expiry = vm.parseJsonUint(feeds, string.concat(p, ".expiry"));
        f.settlementStartAggregate = vm.parseJsonUint(feeds, string.concat(p, ".start"));
        f.currentSpotAggregate = vm.parseJsonUint(feeds, string.concat(p, ".latest"));
        f.fwdDiff = vm.parseJsonInt(feeds, string.concat(p, ".fwdDiff"));
        f.confidence = vm.parseJsonUint(feeds, string.concat(p, ".confidence"));
        f.deadline = vm.parseJsonUint(feeds, string.concat(p, ".deadline"));
        f.timestamp = vm.parseJsonUint(feeds, string.concat(p, ".timestamp"));
        f.signatures = vm.parseJsonBytesArray(feeds, string.concat(p, ".signatures"));
    }

    function _rateOf(string memory feeds, string memory p, address asset)
        internal
        view
        returns (IDeriveOptionPricer.RateFeed memory f)
    {
        f.optionAsset = asset;
        f.expiry = vm.parseJsonUint(feeds, string.concat(p, ".expiry"));
        f.rate = vm.parseJsonInt(feeds, string.concat(p, ".rate"));
        f.confidence = vm.parseJsonUint(feeds, string.concat(p, ".confidence"));
        f.deadline = vm.parseJsonUint(feeds, string.concat(p, ".deadline"));
        f.timestamp = vm.parseJsonUint(feeds, string.concat(p, ".timestamp"));
        f.signatures = vm.parseJsonBytesArray(feeds, string.concat(p, ".signatures"));
    }

    function _volOf(string memory feeds, string memory p, address asset)
        internal
        view
        returns (IDeriveOptionPricer.VolFeed memory f)
    {
        f.optionAsset = asset;
        f.expiry = vm.parseJsonUint(feeds, string.concat(p, ".expiry"));
        f.a = vm.parseJsonInt(feeds, string.concat(p, ".a"));
        f.b = vm.parseJsonUint(feeds, string.concat(p, ".b"));
        f.rho = vm.parseJsonInt(feeds, string.concat(p, ".rho"));
        f.m = vm.parseJsonInt(feeds, string.concat(p, ".m"));
        f.sigma = vm.parseJsonUint(feeds, string.concat(p, ".sigma"));
        f.sviFwd = vm.parseJsonUint(feeds, string.concat(p, ".sviFwd"));
        f.refTau = vm.parseJsonUint(feeds, string.concat(p, ".refTau"));
        f.confidence = vm.parseJsonUint(feeds, string.concat(p, ".confidence"));
        f.deadline = vm.parseJsonUint(feeds, string.concat(p, ".deadline"));
        f.timestamp = vm.parseJsonUint(feeds, string.concat(p, ".timestamp"));
        f.signatures = vm.parseJsonBytesArray(feeds, string.concat(p, ".signatures"));
    }

    function _readFixture(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/", name));
    }

    /// @return data       The submit payload: the blob's share 0, the one subaccount proof, and no feeds.
    /// @return first      The share 0 proof alone.
    /// @return commitment The commitment the Ethereum batch recorded for that blob.
    function _loadReal(string memory name)
        internal
        view
        returns (bytes memory data, DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first, bytes32 commitment)
    {
        string memory json = _readFixture(name);
        commitment = vm.parseJsonBytes32(json, ".commitment");
        first = _shareFrom(json, ".firstShare");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _proofFrom(json);
        data = abi.encode(first, ps, abi.encode(DeriveBlobBuilder.noFeeds()));
    }

    function _proofFrom(string memory json)
        internal
        view
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
    {
        p.subaccountId = vm.parseJsonUint(json, ".subaccount");
        p.recordOffset = vm.parseJsonUint(json, ".recordOffset");
        p.usePrevious = vm.parseJsonBool(json, ".boundary.usePrevious");
        p.prevOffset = vm.parseJsonUint(json, ".boundary.prevOffset");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".shares[", vm.toString(n), "]"))) ++n;
        p.shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](n);
        for (uint256 i; i < n; ++i) {
            p.shares[i] = _shareFrom(json, string.concat(".shares[", vm.toString(i), "]"));
        }
    }

    function _shareFrom(string memory json, string memory k)
        internal
        pure
        returns (DeriveCelestiaAttestedBalanceAdapter.ShareProof memory s)
    {
        s.index = vm.parseJsonUint(json, string.concat(k, ".index"));
        s.share = vm.parseJsonBytes(json, string.concat(k, ".share"));
        s.nmtSiblings = vm.parseJsonBytesArray(json, string.concat(k, ".nmtSiblings"));
        s.rfcSiblings = vm.parseJsonBytes32Array(json, string.concat(k, ".rfcSiblings"));
    }
}
