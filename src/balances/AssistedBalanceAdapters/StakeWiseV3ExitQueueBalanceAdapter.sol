// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {StakeWiseV3ExitQueueBase} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBase.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StakeWise V3 Exit-Queue Balance Adapter (wrapper-fed)
/// @author KPK
/// @notice Reports the in-flight assets owed to an account in StakeWise V3's exit queue, valued entirely from live
///         on-chain reads. Identical valuation to the assistant-fed sibling
///         (`StakeWiseV3ExitQueueAssistedBalanceAdapter`, ADR 0014), but the ticket cache is fed **on-chain** by the
///         depositor itself rather than by an off-chain agent: a depositor Safe delegatecalls
///         `StakeWiseV3ExitQueueWrapper`, which — in the same transaction it enters/exits the StakeWise queue —
///         calls {submit}/{remove} here. Because the wrapper runs in the Safe's context, `msg.sender` on these calls
///         is the depositor Safe and the exit position it created is owned on-chain by that same address, so the
///         valuation (keyed on `receiver = account`) requires no receiver bookkeeping.
/// @dev Trust model and mutability rationale: see `docs/decisions/0019-stakewise-v3-exit-queue-wrapper.md` (a
///      StakeWise-specific instance of the wrapper-fed assisted family, ADR 0018). This is a
///      **role-gated self-submit** adapter: `submit`/`remove` require the caller to hold `DEPOSITOR_ROLE` AND to pass
///      `account == msg.sender` — a depositor can only ever track its OWN tickets. It upholds the assisted-family
///      invariant (ADR 0015): the cache stores **only position coordinates, never amounts**; every read values live
///      on-chain against `receiver = account`, so a faulty or compromised depositor can only under-report, never
///      over-report. Writes are incremental (one ticket at a time), matching the wrapper's enter→submit /
///      claim→remove flow — unlike the assistant adapter's replace-the-whole-set semantics. All shared cache +
///      valuation lives in {StakeWiseV3ExitQueueBase}. Mainnet only (every StakeWise V3 vault there settles in ETH).
contract StakeWiseV3ExitQueueBalanceAdapter is AccessControl, StakeWiseV3ExitQueueBase {
    /// @notice Role allowed to track exit-queue tickets. Granted to each approved depositor Safe (the same Safe that
    ///         delegatecalls {StakeWiseV3ExitQueueWrapper}); `DEFAULT_ADMIN_ROLE` administers it.
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @param vaultsRegistry_ StakeWise VaultsRegistry. Must be a contract.
    /// @param underlyingToken_ Payout asset (native-ETH sentinel on mainnet).
    /// @param receiptSymbol_  Display symbol of StakeWise's receipt/LST token for this chain (`"osETH"` mainnet). May
    ///                        be empty.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param exitClaimDelay_  StakeWise's post-checkpoint claim delay in seconds (24h = `86400` on V3 mainnet). Must
    ///                         be non-zero.
    /// @param admin_     Holder of `DEFAULT_ADMIN_ROLE` — administers `DEPOSITOR_ROLE`. Required.
    constructor(
        address vaultsRegistry_,
        address underlyingToken_,
        string memory receiptSymbol_,
        address navCalculator_,
        uint256 exitClaimDelay_,
        address admin_
    ) StakeWiseV3ExitQueueBase(vaultsRegistry_, underlyingToken_, receiptSymbol_, navCalculator_, exitClaimDelay_) {
        if (admin_ == address(0)) revert InvalidArguments();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    //
    // Mutators
    //

    /// @notice Track one exit position for `account`. Idempotent (a duplicate tuple is a no-op). The caller must hold
    ///         `DEPOSITOR_ROLE` and `account` MUST equal `msg.sender` — a depositor can only track its own tickets.
    ///         Fail-loud: reverts `InvalidExitPosition` if the vault is not StakeWise-registered or the tuple does not
    ///         resolve to a live owed amount for `account`, and `PositionCacheFull` past `MAX_POSITIONS`. Not
    ///         load-bearing for correctness — reads re-verify and value only live, account-owned positions.
    /// @dev `account` is a parameter (rather than implicit `msg.sender`) so the wrapper's call site reads naturally
    ///      (`submit(address(this), …)`); the `account == msg.sender` guard keeps it self-scoped.
    function submit(address account, address vault, uint256 positionTicket, uint256 timestamp)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (account != msg.sender) revert NotAuthorized();
        _addPosition(account, ExitPosition(vault, positionTicket, timestamp));
    }

    /// @notice Stop tracking one exit position for `account` (e.g. once claimed). Idempotent. Same caller constraints
    ///         as {submit}: `DEPOSITOR_ROLE` + `account == msg.sender`.
    function remove(address account, address vault, uint256 positionTicket, uint256 timestamp)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (account != msg.sender) revert NotAuthorized();
        _removePositionByCoords(account, vault, positionTicket, timestamp);
    }

    /// @notice Admin escape hatch: drop all cached positions for `account` (GC for a decommissioned depositor). Stale
    ///         tuples already read as 0, so this only trims the read loop.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearPositions(account);
        emit AccountCleared(account);
    }

    //
    // ERC165
    //

    /// @inheritdoc IERC165
    /// @dev Advertises {IBalanceAdapter} + {IPositionDescribable} on top of AccessControl's {IAccessControl}/{IERC165}.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
