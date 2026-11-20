// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {DeriveOptionMath} from "src/balances/AttestedBalanceAdapters/derive/DeriveOptionMath.sol";
import {DeriveRecord} from "src/balances/AttestedBalanceAdapters/derive/DeriveRecord.sol";
import {IDeriveOptionPricer} from "src/balances/AttestedBalanceAdapters/derive/IDeriveOptionPricer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title DeriveOptionPricer
/// @author KPK
/// @notice Stateless, immutable pricer for `DeriveCelestiaAttestedBalanceAdapter`: verifies Derive's signed oracle
///         feeds and values options at Derive's mark (see {IDeriveOptionPricer-value}).
/// @dev **Feed signatures.** Derive signs its feeds with the Lyra v2 `BaseLyraFeed` scheme, unchanged: EIP-712
///      `FeedData(bytes data,uint256 deadline,uint64 timestamp)` under the domain (name `Lyra{Spot,Forward,Rate,Vol}Feed`,
///      version "1", chain 957 = Derive chain, verifyingContract = that feed's Derive-chain contract). Recovered from
///      live `public/get_latest_signed_feeds` data on 2026-11-20 (derive-spike); not documented by Derive.
///      `data` is re-encoded here from the item's fields, so what is verified is exactly what is priced.
///
///      **Trust.** The signer set is fixed at deployment; every item must carry one signature from each signer.
///      Rotating Derive's signers means deploying a new pricer and a new adapter. The resulting mark is Derive's own
///      model price at the feed timestamps; it is not proven by Derive's state root.
contract DeriveOptionPricer is IDeriveOptionPricer {
    /// @notice Upper bound on signers.
    uint256 public constant MAX_SIGNERS = 8;

    /// @notice Upper bound on configured markets.
    uint256 public constant MAX_MARKETS = 8;

    /// @notice Upper bound on items of each feed kind per call.
    uint256 public constant MAX_FEED_ITEMS = 32;

    /// @notice Maximum age of a spot, forward, rate or vol item used to price a live option.
    uint256 public constant MAX_FEED_AGE = 5 minutes;

    /// @dev A strike is 8-decimal USD; prices are 1e18.
    uint256 private constant _STRIKE_TO_WAD = 1e10;

    /// @dev Settlement price = (currentSpotAggregate − settlementStartAggregate) / 1800 (a 30-minute TWAP; checked
    ///      against Derive's published settlement of ETH-20261116: 1819.511710943306, all digits).
    uint256 private constant _SETTLEMENT_SAMPLES = 1800;

    /// @dev Expiry occupies bits 0-31 of an option's `subId`; strike bits 32-94; bit 95 marks a call.
    uint256 private constant _EXPIRY_MASK = 0xffffffff;
    uint256 private constant _STRIKE_MASK = (1 << 63) - 1;
    uint256 private constant _CALL_BIT = 95;

    uint256 private constant _NONE = type(uint256).max;

    uint256 private constant _DERIVE_CHAIN_ID = 957;
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _FEED_TYPEHASH = keccak256("FeedData(bytes data,uint256 deadline,uint64 timestamp)");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _SPOT_NAME = keccak256("LyraSpotFeed");
    bytes32 private constant _FORWARD_NAME = keccak256("LyraForwardFeed");
    bytes32 private constant _RATE_NAME = keccak256("LyraRateFeed");
    bytes32 private constant _VOL_NAME = keccak256("LyraVolFeed");

    /// @notice Derive option asset id → its market (feed contracts). Set once in the constructor.
    mapping(address optionAsset => OptionMarket market) public marketOf;

    address[] private _optionAssets;

    /// @dev The feed signers, set once in the constructor.
    address[] private _signers;

    /// @dev The verified feed items of one call and which of them an option has used.
    struct FeedBook {
        Feeds feeds;
        bool[] spotUsed;
        bool[] forwardUsed;
        bool[] rateUsed;
        bool[] volUsed;
    }

    /// @param markets_ Option assets to value, with their Derive-chain feed contracts (1 to {MAX_MARKETS}).
    /// @param signers_ The feed signers (1 to {MAX_SIGNERS}, unique). Every feed item must carry one signature from
    ///                 each.
    constructor(OptionMarket[] memory markets_, address[] memory signers_) {
        uint256 s = signers_.length;
        if (s == 0 || s > MAX_SIGNERS) revert InvalidArguments();
        for (uint256 i; i < s; ++i) {
            address signer = signers_[i];
            if (signer == address(0)) revert InvalidArguments();
            for (uint256 j; j < i; ++j) {
                if (signers_[j] == signer) revert InvalidArguments();
            }
            _signers.push(signer);
        }

        uint256 m = markets_.length;
        if (m == 0 || m > MAX_MARKETS) revert InvalidArguments();
        for (uint256 i; i < m; ++i) {
            OptionMarket memory om = markets_[i];
            if (
                om.optionAsset == address(0) || om.spotFeed == address(0) || om.forwardFeed == address(0)
                    || om.rateFeed == address(0) || om.volFeed == address(0)
                    || marketOf[om.optionAsset].optionAsset != address(0)
            ) revert InvalidArguments();
            marketOf[om.optionAsset] = om;
            _optionAssets.push(om.optionAsset);
        }
    }

    /// @notice The configured option asset ids, in constructor order.
    function optionAssets() external view returns (address[] memory) {
        return _optionAssets;
    }

    /// @notice The feed signers, in constructor order.
    function signers() external view returns (address[] memory) {
        return _signers;
    }

    /// @inheritdoc IDeriveOptionPricer
    function isMarket(address optionAsset) external view returns (bool) {
        return marketOf[optionAsset].optionAsset != address(0);
    }

    /// @inheritdoc IDeriveOptionPricer
    function value(bytes calldata feeds, DeriveRecord.Option[] calldata options)
        external
        view
        returns (uint256 credit, uint256 debit)
    {
        FeedBook memory fb = _verifyFeeds(abi.decode(feeds, (Feeds)));
        for (uint256 k; k < options.length; ++k) {
            DeriveRecord.Option calldata o = options[k];
            if (o.amount == 0) continue;
            if (marketOf[o.asset].optionAsset == address(0)) revert UnmappedOption(o.asset);
            uint256 mag = o.amount > 0 ? uint256(o.amount) : uint256(-o.amount);
            uint256 num = mag * _optionPrice18(o.asset, o.subId, fb);
            if (o.amount > 0) credit += num / 1e18;
            else debit += (num + 1e18 - 1) / 1e18;
        }
        _requireAllUsed(fb);
    }

    /// @dev One option's value per unit, 1e18 USD.
    function _optionPrice18(address asset, uint256 subId, FeedBook memory fb) private view returns (uint256) {
        uint256 expiry = subId & _EXPIRY_MASK;
        uint256 strike18 = ((subId >> 32) & _STRIKE_MASK) * _STRIKE_TO_WAD;
        bool isCall = (subId >> _CALL_BIT) & 1 == 1;

        uint256 fi = _forwardIndex(fb.feeds.forwards, asset, expiry);
        if (fi == _NONE) revert MissingFeed(asset, expiry);
        fb.forwardUsed[fi] = true;
        ForwardFeed memory fw = fb.feeds.forwards[fi];

        if (expiry <= block.timestamp) {
            if (fw.timestamp != expiry) revert SettlementNotPublished(asset, expiry);
            if (fw.currentSpotAggregate < fw.settlementStartAggregate) {
                revert SettlementWindowInverted(asset, expiry);
            }
            uint256 settle = (fw.currentSpotAggregate - fw.settlementStartAggregate) / _SETTLEMENT_SAMPLES;
            if (isCall) return settle > strike18 ? settle - strike18 : 0;
            return strike18 > settle ? strike18 - settle : 0;
        }

        _requireFresh(fw.timestamp);
        return _livePrice18(asset, expiry, strike18, isCall, fw, fb);
    }

    /// @dev Black-76 value of a live option from its spot, forward, rate and vol items.
    function _livePrice18(
        address asset,
        uint256 expiry,
        uint256 strike18,
        bool isCall,
        ForwardFeed memory fw,
        FeedBook memory fb
    ) private view returns (uint256) {
        uint256 si = _spotIndex(fb.feeds.spots, asset);
        if (si == _NONE) revert MissingSpot(asset);
        fb.spotUsed[si] = true;
        SpotFeed memory sp = fb.feeds.spots[si];
        _requireFresh(sp.timestamp);
        if (sp.price == 0) revert ZeroSpot(asset);

        uint256 ri = _rateIndex(fb.feeds.rates, asset, expiry);
        if (ri == _NONE) revert MissingFeed(asset, expiry);
        fb.rateUsed[ri] = true;
        RateFeed memory rt = fb.feeds.rates[ri];
        _requireFresh(rt.timestamp);

        uint256 vi = _volIndex(fb.feeds.vols, asset, expiry);
        if (vi == _NONE) revert MissingFeed(asset, expiry);
        fb.volUsed[vi] = true;
        VolFeed memory vf = fb.feeds.vols[vi];
        _requireFresh(vf.timestamp);

        DeriveOptionMath.Svi memory svi = DeriveOptionMath.Svi({
            a: vf.a, b: vf.b, rho: vf.rho, m: vf.m, sigma: vf.sigma, sviFwd: vf.sviFwd, refTau: vf.refTau
        });
        return DeriveOptionMath.optionPrice(
            svi, strike18, sp.price, fw.fwdDiff, rt.rate, DeriveOptionMath.yearsTo(expiry, block.timestamp), isCall
        );
    }

    /// @dev Verifies every item's signatures, deadline and timestamp, and returns the usage book.
    function _verifyFeeds(Feeds memory f) private view returns (FeedBook memory fb) {
        uint256 ns = f.spots.length;
        uint256 nf = f.forwards.length;
        uint256 nr = f.rates.length;
        uint256 nv = f.vols.length;
        if (ns > MAX_FEED_ITEMS) revert TooManyFeedItems(ns);
        if (nf > MAX_FEED_ITEMS) revert TooManyFeedItems(nf);
        if (nr > MAX_FEED_ITEMS) revert TooManyFeedItems(nr);
        if (nv > MAX_FEED_ITEMS) revert TooManyFeedItems(nv);

        for (uint256 i; i < ns; ++i) {
            SpotFeed memory it = f.spots[i];
            _verifySigned(
                _SPOT_NAME,
                _marketFor(it.optionAsset).spotFeed,
                abi.encode(it.price, it.confidence),
                it.deadline,
                it.timestamp,
                it.signatures
            );
        }
        for (uint256 i; i < nf; ++i) {
            ForwardFeed memory it = f.forwards[i];
            bytes memory data =
                abi.encode(it.expiry, it.settlementStartAggregate, it.currentSpotAggregate, it.fwdDiff, it.confidence);
            _verifySigned(
                _FORWARD_NAME, _marketFor(it.optionAsset).forwardFeed, data, it.deadline, it.timestamp, it.signatures
            );
        }
        for (uint256 i; i < nr; ++i) {
            RateFeed memory it = f.rates[i];
            _verifySigned(
                _RATE_NAME,
                _marketFor(it.optionAsset).rateFeed,
                abi.encode(it.expiry, it.rate, it.confidence),
                it.deadline,
                it.timestamp,
                it.signatures
            );
        }
        for (uint256 i; i < nv; ++i) {
            VolFeed memory it = f.vols[i];
            bytes memory data =
                abi.encode(it.expiry, it.a, it.b, it.rho, it.m, it.sigma, it.sviFwd, it.refTau, it.confidence);
            _verifySigned(_VOL_NAME, _marketFor(it.optionAsset).volFeed, data, it.deadline, it.timestamp, it.signatures);
        }

        fb.feeds = f;
        fb.spotUsed = new bool[](ns);
        fb.forwardUsed = new bool[](nf);
        fb.rateUsed = new bool[](nr);
        fb.volUsed = new bool[](nv);
    }

    function _marketFor(address optionAsset) private view returns (OptionMarket memory m) {
        m = marketOf[optionAsset];
        if (m.optionAsset == address(0)) revert UnmappedFeed(optionAsset);
    }

    /// @dev Checks an item's deadline and timestamp, then that every signer signed its EIP-712 digest.
    function _verifySigned(
        bytes32 nameHash,
        address feed,
        bytes memory data,
        uint256 deadline,
        uint256 timestamp,
        bytes[] memory sigs
    ) private view {
        if (block.timestamp > deadline) revert FeedExpired(deadline);
        if (timestamp > block.timestamp) revert FeedFromFuture(timestamp);
        bytes32 structHash = keccak256(abi.encode(_FEED_TYPEHASH, keccak256(data), deadline, timestamp));
        bytes32 domain = keccak256(abi.encode(_DOMAIN_TYPEHASH, nameHash, _VERSION_HASH, _DERIVE_CHAIN_ID, feed));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));

        uint256 want = _signers.length;
        if (sigs.length != want) revert FeedSignatureCount(sigs.length, want);
        uint256 seen;
        for (uint256 i; i < want; ++i) {
            address who = ECDSA.recover(digest, sigs[i]);
            uint256 idx = _signerIndex(who);
            if (seen >> idx & 1 == 1) revert DuplicateSignature(who);
            seen |= 1 << idx;
        }
    }

    function _signerIndex(address who) private view returns (uint256) {
        for (uint256 i; i < _signers.length; ++i) {
            if (_signers[i] == who) return i;
        }
        revert UnknownSigner(who);
    }

    /// @dev Freshness of a live-pricing item. `_verifySigned` already refused timestamps after `block.timestamp`.
    function _requireFresh(uint256 timestamp) private view {
        if (block.timestamp - timestamp > MAX_FEED_AGE) revert FeedStale(timestamp);
    }

    function _spotIndex(SpotFeed[] memory items, address asset) private pure returns (uint256) {
        for (uint256 i; i < items.length; ++i) {
            if (items[i].optionAsset == asset) return i;
        }
        return _NONE;
    }

    function _forwardIndex(ForwardFeed[] memory items, address asset, uint256 expiry) private pure returns (uint256) {
        for (uint256 i; i < items.length; ++i) {
            if (items[i].optionAsset == asset && items[i].expiry == expiry) return i;
        }
        return _NONE;
    }

    function _rateIndex(RateFeed[] memory items, address asset, uint256 expiry) private pure returns (uint256) {
        for (uint256 i; i < items.length; ++i) {
            if (items[i].optionAsset == asset && items[i].expiry == expiry) return i;
        }
        return _NONE;
    }

    function _volIndex(VolFeed[] memory items, address asset, uint256 expiry) private pure returns (uint256) {
        for (uint256 i; i < items.length; ++i) {
            if (items[i].optionAsset == asset && items[i].expiry == expiry) return i;
        }
        return _NONE;
    }

    /// @dev Every verified feed item must have priced an option: no unused (padding or stale-substitute) items.
    function _requireAllUsed(FeedBook memory fb) private pure {
        for (uint256 i; i < fb.spotUsed.length; ++i) {
            if (!fb.spotUsed[i]) revert UnusedFeed(fb.feeds.spots[i].optionAsset);
        }
        for (uint256 i; i < fb.forwardUsed.length; ++i) {
            if (!fb.forwardUsed[i]) revert UnusedFeed(fb.feeds.forwards[i].optionAsset);
        }
        for (uint256 i; i < fb.rateUsed.length; ++i) {
            if (!fb.rateUsed[i]) revert UnusedFeed(fb.feeds.rates[i].optionAsset);
        }
        for (uint256 i; i < fb.volUsed.length; ++i) {
            if (!fb.volUsed[i]) revert UnusedFeed(fb.feeds.vols[i].optionAsset);
        }
    }
}
