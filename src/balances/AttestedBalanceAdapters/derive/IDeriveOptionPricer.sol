// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {DeriveRecord} from "src/balances/AttestedBalanceAdapters/derive/DeriveRecord.sol";

/// @title IDeriveOptionPricer
/// @author KPK
/// @notice Values Derive options at Derive's mark from Derive's signed oracle feeds. Kept out of
///         `DeriveCelestiaAttestedBalanceAdapter` so the adapter stays under the EIP-170 size limit; the types and
///         errors live here so the adapter, the pricer and their callers share one definition.
interface IDeriveOptionPricer {
    /// @notice One Derive option asset and the Derive feed contracts that sign its prices. Each feed is verified
    ///         against its own EIP-712 domain (`verifyingContract` = that feed).
    struct OptionMarket {
        address optionAsset;
        address spotFeed;
        address forwardFeed;
        address rateFeed;
        address volFeed;
    }

    /// @notice A signed spot price of one option asset's underlying (1e18 USD).
    struct SpotFeed {
        address optionAsset;
        uint256 price;
        uint256 confidence;
        uint256 deadline;
        uint256 timestamp;
        bytes[] signatures;
    }

    /// @notice A signed forward for one (option asset, expiry). `fwdDiff` is added to spot to give the forward. For an
    ///         expired expiry, the aggregates are the settlement window's (see {IDeriveOptionPricer-value}).
    struct ForwardFeed {
        address optionAsset;
        uint256 expiry;
        uint256 settlementStartAggregate;
        uint256 currentSpotAggregate;
        int256 fwdDiff;
        uint256 confidence;
        uint256 deadline;
        uint256 timestamp;
        bytes[] signatures;
    }

    /// @notice A signed continuously compounded rate for one (option asset, expiry), 1e18.
    struct RateFeed {
        address optionAsset;
        uint256 expiry;
        int256 rate;
        uint256 confidence;
        uint256 deadline;
        uint256 timestamp;
        bytes[] signatures;
    }

    /// @notice A signed SVI slice for one (option asset, expiry), 1e18 fixed point.
    struct VolFeed {
        address optionAsset;
        uint256 expiry;
        int256 a;
        uint256 b;
        int256 rho;
        int256 m;
        uint256 sigma;
        uint256 sviFwd;
        uint256 refTau;
        uint256 confidence;
        uint256 deadline;
        uint256 timestamp;
        bytes[] signatures;
    }

    /// @notice The signed feed items of one submit. Each item is looked up by its key and must be used by an option.
    struct Feeds {
        SpotFeed[] spots;
        ForwardFeed[] forwards;
        RateFeed[] rates;
        VolFeed[] vols;
    }

    error UnmappedOption(address optionAsset);
    error UnmappedFeed(address optionAsset);
    error TooManyFeedItems(uint256 count);
    error FeedSignatureCount(uint256 got, uint256 want);
    error UnknownSigner(address signer);
    error DuplicateSignature(address signer);
    error FeedExpired(uint256 deadline);
    error FeedFromFuture(uint256 timestamp);
    error FeedStale(uint256 timestamp);
    error MissingSpot(address optionAsset);
    error MissingFeed(address optionAsset, uint256 expiry);
    error ZeroSpot(address optionAsset);
    error SettlementNotPublished(address optionAsset, uint256 expiry);
    error SettlementWindowInverted(address optionAsset, uint256 expiry);
    error UnusedFeed(address optionAsset);

    /// @notice Values `options` at Derive's mark, priced from `feeds` (`abi.encode(Feeds)`), at `block.timestamp`.
    /// @dev Every feed item must be signed by every signer, be within its deadline and not from the future, and be
    ///      used by an option. A live option (expiry after now) is Black-76 on Derive's SVI slice with
    ///      F = spot + fwdDiff and the rate clamped at 0; its spot, forward, rate and vol items must be at most
    ///      `MAX_FEED_AGE` old. An expired option is its intrinsic value at Derive's settlement price,
    ///      (currentSpotAggregate − settlementStartAggregate) / 1800, from a forward item stamped at the expiry.
    /// @return credit Σ long value, 12-decimal USD, each option rounded down.
    /// @return debit  Σ short value, 12-decimal USD, each option rounded up.
    function value(bytes calldata feeds, DeriveRecord.Option[] calldata options)
        external
        view
        returns (uint256 credit, uint256 debit);

    /// @notice True if `optionAsset` has a configured market.
    function isMarket(address optionAsset) external view returns (bool);
}
