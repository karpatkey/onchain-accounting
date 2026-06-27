// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWise V3 Exit-Queue Balance Adapter (ticket-cached)
/// @author KPK
/// @notice Reports the in-flight assets owed to an account in StakeWise V3's exit queue. Calling
///         `enterExitQueue(shares, receiver)` moves vault shares into the queue and returns a `positionTicket`;
///         the queued value is then invisible to NAV (a position is identified only by that ticket — emitted in
///         the `ExitQueueEntered` event — and there is no per-account enumeration, so a pure-view adapter cannot
///         discover the positions). An off-chain agent submits each `(vault, positionTicket, timestamp)` tuple via
///         `submitPositions`; this adapter then values them entirely from live on-chain reads. The cache stores
///         **only the position coordinates, never amounts** — a holder of `ASSISTANT_ROLE` cannot fabricate value;
///         at worst it omits a position (NAV under-counts), never over-counts.
/// @dev Trust model and mutability rationale: see `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`
///      (generalises the Merkl precedent, ADR 0007; sibling of `EtherFiWithdrawalQueue`). One aggregated leg per
///      account, denominated in the chain's staking asset (native ETH on mainnet). Mainnet only — every StakeWise
///      V3 vault there settles in ETH; do not deploy on a chain with a non-ETH staking asset against this
///      `underlyingToken`.
///
///      The exit-request key is `keccak256(abi.encode(receiver, timestamp, positionTicket))`, where `timestamp` is
///      the entry block's `block.timestamp` (the agent reads it from the `ExitQueueEntered` event's block). Because
///      the valuation call passes `receiver = account`, a tuple that does not belong to `account` resolves to a
///      zero exit request and is dropped — this is the on-chain verification (no `ownerOf` exists for exit
///      positions). The `vaultsRegistry` membership check at submit time is light hygiene only; correctness does
///      not depend on it.
contract StakeWiseV3ExitQueueBalanceAdapter is AssistedBalanceAdapter, IPositionDescribable {
    //
    // Types
    //

    /// @param vault          StakeWise V3 vault the exit position lives in.
    /// @param positionTicket Ticket returned by `enterExitQueue` / emitted in `ExitQueueEntered`.
    /// @param timestamp      Entry block's `block.timestamp` — part of the exit-request key.
    struct ExitPosition {
        address vault;
        uint256 positionTicket;
        uint256 timestamp;
    }

    //
    // State
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.STAKEWISE_EXIT;

    /// @notice Hard cap on cached exit positions per account. `_assetsOwed` iterates the whole array on every NAV
    ///         read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the agent must GC
    ///         claimed positions (`clearPosition`) to stay under it. A real account never approaches 256 open exits.
    uint256 public constant MAX_POSITIONS = 256;

    /// @notice StakeWise VaultsRegistry — `vaults(address)` gates which vaults the cache accepts (write-time
    ///         hygiene; the immutable anchor, analogous to ether.fi pinning its WithdrawRequestNFT).
    address public immutable VAULTS_REGISTRY;

    /// @notice Underlying staking asset the queue pays out (native-ETH sentinel on mainnet). Must be a registered
    ///         NAV asset. All accepted vaults must settle in this asset.
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered staking-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Cached exit positions per account (the only thing the assistant supplies).
    mapping(address account => ExitPosition[] positions) private _positions;

    /// @dev `idxPlus1` = index of the position in `_positions[account]` plus 1, keyed by the tuple hash. Zero ⇒ not
    ///      present (dedup + O(1) removal).
    mapping(address account => mapping(bytes32 key => uint256)) private _positionIdxPlus1;

    //
    // Events
    //

    event PositionSubmitted(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    event PositionCleared(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    event AccountCleared(address indexed account);

    //
    // Constructor
    //

    /// @param vaultsRegistry_ StakeWise VaultsRegistry. Must be a contract.
    /// @param underlyingToken_ Payout asset (native-ETH sentinel on mainnet).
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param admin_     Holder of `DEFAULT_ADMIN_ROLE` — administers `ASSISTANT_ROLE`. Required.
    /// @param assistant_ Initial holder of `ASSISTANT_ROLE`, authorized to submit/clear positions (the agent role).
    ///                   Optional (pass `address(0)` to grant later via `admin_`).
    constructor(
        address vaultsRegistry_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address assistant_
    ) AssistedBalanceAdapter(admin_, assistant_) {
        if (vaultsRegistry_ == address(0) || underlyingToken_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        require(vaultsRegistry_.code.length > 0, "VaultsRegistry must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        VAULTS_REGISTRY = vaultsRegistry_;
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Mutators (onlyRole(ASSISTANT_ROLE))
    //

    /// @notice Add candidate exit positions for `account`. Idempotent (dedup by tuple hash). Positions whose vault
    ///         is not in the VaultsRegistry, or that do not currently resolve to a non-zero owed amount for
    ///         `account`, are skipped at write time as light hygiene; correctness does not depend on it — reads
    ///         re-verify and value only live, account-owned positions.
    function submitPositions(address account, ExitPosition[] calldata positions) external onlyRole(ASSISTANT_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        for (uint256 i; i < positions.length; ++i) {
            _addPosition(account, positions[i]);
        }
    }

    /// @notice Batch variant across accounts. `accounts` and `positions` must have the same length.
    function submitPositionsBatch(address[] calldata accounts, ExitPosition[][] calldata positions)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        if (accounts.length != positions.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert InvalidArguments();
            for (uint256 j; j < positions[i].length; ++j) {
                _addPosition(accounts[i], positions[i][j]);
            }
        }
    }

    /// @notice Drop a cached position. Idempotent. GC for claimed positions (stale tuples already read as 0).
    function clearPosition(address account, address vault, uint256 positionTicket, uint256 timestamp)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        bytes32 key = _key(vault, positionTicket, timestamp);
        if (_positionIdxPlus1[account][key] == 0) return;
        _removePosition(account, key);
        emit PositionCleared(account, vault, positionTicket, timestamp);
    }

    /// @notice Drop all cached positions for `account`.
    function clearAccount(address account) external onlyRole(ASSISTANT_ROLE) {
        ExitPosition[] storage list = _positions[account];
        for (uint256 i; i < list.length; ++i) {
            delete _positionIdxPlus1[account][_key(list[i].vault, list[i].positionTicket, list[i].timestamp)];
        }
        delete _positions[account];
        emit AccountCleared(account);
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Candidate exit positions currently cached for `account` (display/debug; not staleness-filtered).
    function positionsOf(address account) external view returns (ExitPosition[] memory) {
        return _positions[account];
    }

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the family's base advertisement
    ///      ({IAssistedBalanceAdapter}/{IBalanceAdapter}/{IAccessControl}/{IERC165}).
    function supportsInterface(bytes4 interfaceId) public view override(AssistedBalanceAdapter) returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    function protocolName() external pure returns (string memory) {
        return "StakeWise V3";
    }

    function _legLabels() private pure returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "Exit Queue";
        return out;
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        return (_assetsOwed(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 owed = account == address(0) ? 0 : _assetsOwed(account);
        if (owed == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = owed;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice One aggregated staking-asset `Supplied` leg = total assets owed across the account's live,
    ///         account-owned exit positions. `positionId = abi.encode(VAULTS_REGISTRY)` (account-global,
    ///         keyed on the immutable anchor, like the other WQ adapters).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        // Cheap path first: bail before fetching/scanning getRegisteredAssets when there is nothing owed
        // (the common case — no cached positions, or all stale/claimed).
        uint256 total = _assetsOwed(account);
        if (total == 0) return new INAVCalculator.PositionBalance[](0);

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.Asset memory underlying;
        bool registered;
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == UNDERLYING_TOKEN) {
                underlying = reg[i];
                registered = true;
                break;
            }
        }
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: total,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            // Anchored on the VaultsRegistry (the immutable anchor); the owed asset lives in
            // `balanceAsset`, so the registry address is the non-redundant coordinate.
            positionId: abi.encode(VAULTS_REGISTRY),
            positionKind: PositionKind.Supplied,
            labels: _legLabels()
        });
    }

    //
    // Internal — write
    //

    function _addPosition(address account, ExitPosition calldata position) internal {
        bytes32 key = _key(position.vault, position.positionTicket, position.timestamp);
        if (_positionIdxPlus1[account][key] != 0) return; // already cached
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The assistant
        // must GC claimed positions to make room; a real account never approaches MAX_POSITIONS open exits.
        if (_positions[account].length >= MAX_POSITIONS) return;
        // Light hygiene: only store vaults the registry knows and tuples that resolve to a live owed amount for
        // `account`. Not load-bearing — reads re-verify. Both reads try/catch to a skip.
        try IStakeWiseVaultsRegistry(VAULTS_REGISTRY).vaults(position.vault) returns (bool ok) {
            if (!ok) return;
        } catch {
            return;
        }
        if (_owedForPosition(account, position.vault, position.positionTicket, position.timestamp) == 0) return;

        _positions[account].push(position);
        _positionIdxPlus1[account][key] = _positions[account].length;
        emit PositionSubmitted(account, position.vault, position.positionTicket, position.timestamp);
    }

    function _removePosition(address account, bytes32 key) internal {
        uint256 idxPlus1 = _positionIdxPlus1[account][key];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        ExitPosition[] storage list = _positions[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            ExitPosition memory last = list[lastIdx];
            list[idx] = last;
            _positionIdxPlus1[account][_key(last.vault, last.positionTicket, last.timestamp)] = idx + 1;
        }
        list.pop();
        delete _positionIdxPlus1[account][key];
    }

    //
    // Internal — valuation
    //

    /// @dev Total assets owed across the account's cached positions, valued from live on-chain reads. Never reverts.
    function _assetsOwed(address account) internal view returns (uint256 total) {
        ExitPosition[] memory list = _positions[account];
        for (uint256 i; i < list.length; ++i) {
            total += _owedForPosition(account, list[i].vault, list[i].positionTicket, list[i].timestamp);
        }
    }

    /// @dev Assets owed for a single exit position, or 0 if it does not belong to `account` / is claimed / invalid.
    ///      Mirrors StakeWise's own queue math:
    ///        - `idx = getExitQueueIndex(ticket)`; `idx == -1` ⇒ not yet checkpointed (fully pending). Passing an
    ///          out-of-range index to `calculateExitedAssets` makes it return `(left = full queued shares, 0, 0)`
    ///          without reverting (see ExitQueue.calculateExitedAssets early-return), so the still-queued portion
    ///          is valued via `convertToAssets`.
    ///        - otherwise the checkpointed `exitedAssets` are claimable as-is and `leftShares` is the still-queued
    ///          remainder, valued at the vault's current rate.
    ///      `calculateExitedAssets(receiver = account, …)` returns zero for a tuple that is not the account's exit
    ///      request, which is the on-chain ownership verification. All external reads try/catch to 0.
    function _owedForPosition(address account, address vault, uint256 positionTicket, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        IStakeWiseExitVault v = IStakeWiseExitVault(vault);

        int256 idx;
        try v.getExitQueueIndex(positionTicket) returns (int256 i) {
            idx = i;
        } catch {
            return 0;
        }
        // idx < 0 ⇒ fully pending; an out-of-range index yields (leftShares = full, exited = 0) with no revert.
        uint256 queryIdx = idx < 0 ? type(uint256).max : uint256(idx);

        // StakeWise's exit queue is share-denominated, so the returned `leftTickets` (still-queued remainder) is in
        // vault shares — hence valued via `convertToAssets` below. `exitedAssets` is already in the underlying asset.
        uint256 leftShares;
        uint256 exitedAssets;
        try v.calculateExitedAssets(account, positionTicket, timestamp, queryIdx) returns (
            uint256 leftTickets, uint256, uint256 exited
        ) {
            leftShares = leftTickets;
            exitedAssets = exited;
        } catch {
            return 0;
        }

        uint256 queued;
        if (leftShares > 0) {
            try v.convertToAssets(leftShares) returns (uint256 a) {
                queued = a;
            } catch {
                return 0;
            }
        }
        return exitedAssets + queued;
    }

    function _key(address vault, uint256 positionTicket, uint256 timestamp) private pure returns (bytes32) {
        return keccak256(abi.encode(vault, positionTicket, timestamp));
    }
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue reads.
interface IStakeWiseExitVault {
    /// @notice Checkpoint index for a position ticket, or -1 if not yet checkpointed (fully pending).
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);

    /// @notice For the exit request keyed by `(receiver, timestamp, positionTicket)`: shares still queued,
    ///         tickets that exited, and the assets those exited tickets are worth. Returns all zero for a tuple
    ///         that is not a live exit request for `receiver`.
    function calculateExitedAssets(address receiver, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets);

    /// @notice Current asset value of `shares` vault shares.
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Minimal interface for the StakeWise VaultsRegistry.
interface IStakeWiseVaultsRegistry {
    /// @notice Whether `vault` is a StakeWise-registered vault.
    function vaults(address vault) external view returns (bool);
}
