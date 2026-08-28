// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IPrices} from "src/prices/IPrices.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Read-only pass-through to an existing AggregatorV3 feed.
/// @dev Exists solely to be the transient second feed during a heartbeat realignment. It forwards the
///      SAME round data as the feed being realigned, so during the step where it is the asset's only
///      registered feed the asset is priced from exactly the source it was already priced from.
///
///      Two properties are load-bearing and neither is incidental:
///      - It must NOT answer `supportsInterface(ICustomPriceFeed)`. Registration rejects a Chainlink-typed
///        feed that does, so implementing ERC-165 here would break the procedure.
///      - It must forward `decimals()`. `addFeed` rejects a second feed whose decimals differ from the
///        incumbent's, so a hardcoded value would break every asset whose feed is not that many decimals.
contract AggregatorMirror {
    AggregatorV3Interface public immutable SOURCE;

    constructor(address source) {
        SOURCE = AggregatorV3Interface(source);
    }

    function decimals() external view returns (uint8) {
        return SOURCE.decimals();
    }

    function description() external view returns (string memory) {
        return SOURCE.description();
    }

    function version() external view returns (uint256) {
        return SOURCE.version();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return SOURCE.latestRoundData();
    }
}

interface INav {
    function getPriceFeedCount(address asset) external view returns (uint256);
    function getPriceFeedAt(address asset, uint256 index) external view returns (IPrices.PriceFeedConfig memory);
    function getMonitorFeeds(address asset) external view returns (IPrices.PriceFeedConfig[] memory);
    function addPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 heartbeat) external;
    function removePriceFeed(address asset, address priceFeed) external;
    function addMonitorFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 heartbeat) external;
    function removeMonitorFeed(address asset, address priceFeed) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title HeartbeatRealigner
/// @author KPK
/// @notice One-shot operational contract that rewrites registered price-feed heartbeats to the values
///         ADR 0025 requires, without unregistering assets and without upgrading NAVCalculator.
/// @dev **Why this contract exists.** A registered heartbeat cannot be changed through the NAVCalculator
///      API. `removePriceFeed` refuses to remove an asset's last price feed and `addPriceFeed` refuses a
///      feed address the asset already carries, so for a single-feed asset — which is every registered
///      asset — both orderings are closed. NAVCalculator has ~101 bytes of EIP-170 margin, so adding a
///      setter is not available either.
///
///      The way through is to stop the asset being single-feed for the duration of the swap, by
///      registering a mirror of its own feed:
///
///        add mirror -> remove original -> re-add original at the new heartbeat -> remove mirror
///
///      **All four steps run in one transaction, and that is the point.** Run as separate transactions
///      from an EOA, an interruption leaves the asset priced by the mirror indefinitely. Atomically,
///      either the heartbeat moves or nothing does: no staleness gap, no window where an unaudited
///      contract sits in the pricing path, and no window where the asset is missing from the registry.
///
///      **Requires MANAGER_ROLE for the duration and no longer.** Grant, `realign`, revoke — the grant
///      and revoke can sit either side of the call in the same operator session. The contract holds no
///      funds, has no owner, and cannot do anything after the role is revoked.
///
///      The mirror is pinned to the incumbent feed rather than being any healthy aggregator because
///      registration validates that a Chainlink feed is LIVE, never that it prices the asset it is
///      registered for. A mirror of the wrong feed is accepted and the asset is then mispriced and
///      reported fresh — measured at $1.00 for AAVE against a true $125.20 — which is exactly the failure
///      ADR 0025 exists to prevent. `_realignOne` therefore reads the incumbent feed itself and never
///      accepts a feed address from the caller.
contract HeartbeatRealigner {
    /// @notice The only address permitted to drive this contract.
    /// @dev Pinned at construction. Without it, `realign` is a permissionless function on a contract that
    ///      holds MANAGER_ROLE — anyone could rewrite the chain's pricing configuration, setting a
    ///      heartbeat to decades (a dead feed reads fresh forever) or to seconds (every asset prices 0).
    ///      That is not hypothetical: on the Polygon rollout the trailing `revokeRole` transaction ran out
    ///      of gas, and this contract sat holding MANAGER_ROLE, ungated, for 107 blocks.
    address public immutable OPERATOR;

    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER");

    INav public immutable NAV;

    error NotOperator(address caller);
    error LengthMismatch(uint256 assets, uint256 heartbeats);
    error NothingToRealign(address asset);
    error ZeroHeartbeat(address asset);
    error PostconditionFeedCount(address asset, uint256 count);
    error PostconditionFeedAddress(address asset, address got, address want);
    error PostconditionHeartbeat(address asset, uint256 got, uint256 want);
    error MonitorFeedNotFound(address asset);

    event Realigned(address indexed asset, address indexed priceFeed, uint256 oldHeartbeat, uint256 newHeartbeat);
    event MonitorRealigned(
        address indexed asset, address indexed priceFeed, uint256 oldHeartbeat, uint256 newHeartbeat
    );

    constructor(address nav, address operator) {
        NAV = INav(nav);
        OPERATOR = operator;
    }

    /// @dev Gates every state-changing entry point. The grant of MANAGER_ROLE happens in a SEPARATE
    ///      transaction from the call that uses it, so the role can be live on this contract before and
    ///      after — this is what makes that window harmless rather than exploitable.
    modifier onlyOperator() {
        if (msg.sender != OPERATOR) revert NotOperator(msg.sender);
        _;
    }

    /// @notice Hands MANAGER_ROLE back at the end of the work, in the same transaction that used it.
    /// @dev `renounceRole` is callable by the role holder itself, so this needs no admin. It means the
    ///      privilege cannot outlive the transaction that needed it, and removes the trailing revoke
    ///      transaction that failed on Polygon. Guarded on `hasRole` so a second call is not a revert.
    function _renounce() private {
        if (NAV.hasRole(MANAGER_ROLE, address(this))) NAV.renounceRole(MANAGER_ROLE, address(this));
    }

    /// @notice Realigns the primary price-feed heartbeat for each asset. Atomic across the whole batch.
    /// @dev Reverts the entire batch if any single asset fails its postconditions, so a partial rollout is
    ///      not representable. Callers batch per chain.
    function realign(address[] calldata assets, uint256[] calldata heartbeats) external onlyOperator {
        if (assets.length != heartbeats.length) revert LengthMismatch(assets.length, heartbeats.length);
        for (uint256 i; i < assets.length; ++i) {
            _realignOne(assets[i], heartbeats[i]);
        }
        _renounce();
    }

    /// @notice Realigns monitor-feed heartbeats. Separate because monitor feeds have no last-feed guard,
    ///         so they need no mirror — a plain remove/add suffices.
    function realignMonitors(address[] calldata assets, address[] calldata feeds, uint256[] calldata heartbeats)
        external
        onlyOperator
    {
        if (assets.length != heartbeats.length) revert LengthMismatch(assets.length, heartbeats.length);
        if (assets.length != feeds.length) revert LengthMismatch(assets.length, feeds.length);
        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig[] memory mons = NAV.getMonitorFeeds(assets[i]);
            bool matched;
            for (uint256 j; j < mons.length; ++j) {
                if (mons[j].priceFeed != feeds[i]) continue;
                matched = true;
                if (mons[j].chainlinkHeartbeat == heartbeats[i]) revert NothingToRealign(assets[i]);
                NAV.removeMonitorFeed(assets[i], feeds[i]);
                NAV.addMonitorFeed(assets[i], feeds[i], mons[j].priceType, heartbeats[i]);
                emit MonitorRealigned(assets[i], feeds[i], mons[j].chainlinkHeartbeat, heartbeats[i]);
                break;
            }
            // Keyed on whether the REQUESTED feed was found, not on the list being non-empty. A non-empty
            // list that simply does not contain feeds[i] used to fall straight through, so the batch
            // reported success while leaving that heartbeat untouched.
            if (!matched) revert MonitorFeedNotFound(assets[i]);
        }
        _renounce();
    }

    function _realignOne(address asset, uint256 heartbeat) private {
        if (heartbeat == 0) revert ZeroHeartbeat(asset);

        IPrices.PriceFeedConfig memory f = NAV.getPriceFeedAt(asset, 0);
        if (f.chainlinkHeartbeat == heartbeat) revert NothingToRealign(asset);
        uint256 countBefore = NAV.getPriceFeedCount(asset);

        // A mirror is only needed to escape the last-feed guard. An asset already carrying a second feed
        // can be realigned by a plain remove/add, and minting a mirror for it would be pure risk.
        if (countBefore == 1) {
            address mirror = address(new AggregatorMirror(f.priceFeed));
            NAV.addPriceFeed(asset, mirror, f.priceType, heartbeat);
            NAV.removePriceFeed(asset, f.priceFeed);
            NAV.addPriceFeed(asset, f.priceFeed, f.priceType, heartbeat);
            NAV.removePriceFeed(asset, mirror);
        } else {
            NAV.removePriceFeed(asset, f.priceFeed);
            NAV.addPriceFeed(asset, f.priceFeed, f.priceType, heartbeat);
        }

        // Assert the end state on-chain rather than trusting the sequence. `removePriceFeed` is
        // swap-with-last + pop, so the final ordering is a consequence of the step order; if that ever
        // changes the batch must revert, not silently leave the mirror registered as the primary feed.
        // Assert against the ORIGINAL count, and locate the incumbent BY ADDRESS. `removeFeed` is
        // swap-with-last + pop, so the incumbent does not reliably land back at index 0 once an asset
        // carries more than one feed. Hardcoding `count == 1` and `index 0` made the multi-feed branch
        // unable to satisfy its own postcondition — remove+add preserves the original count, so a
        // two-feed asset always reverted. No registered asset carries a second feed today, so it never
        // fired: latent, not benign.
        uint256 count = NAV.getPriceFeedCount(asset);
        if (count != countBefore) revert PostconditionFeedCount(asset, count);

        bool found;
        for (uint256 i; i < count; ++i) {
            IPrices.PriceFeedConfig memory end = NAV.getPriceFeedAt(asset, i);
            if (end.priceFeed != f.priceFeed) continue;
            found = true;
            if (end.chainlinkHeartbeat != heartbeat) {
                revert PostconditionHeartbeat(asset, end.chainlinkHeartbeat, heartbeat);
            }
            break;
        }
        if (!found) revert PostconditionFeedAddress(asset, address(0), f.priceFeed);

        emit Realigned(asset, f.priceFeed, f.chainlinkHeartbeat, heartbeat);
    }
}
