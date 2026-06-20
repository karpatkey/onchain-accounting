// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {INAVCalculator} from "./INAVCalculator.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";

/// @title NavLens
/// @notice Read-only helper that enriches NAVCalculator positions with human-readable labels.
/// @dev NAVCalculator is kept under EIP-170 by keeping the verbose read path here rather than inline.
///      Deploy alongside NAVCalculator; reference this address in off-chain tooling / dashboards.
///      NavLens has no state and no admin functions — it is fully stateless.
/// @author kpk
contract NavLens {
    /// @notice The NAVCalculator this lens reads from.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @param navCalculator_ The NAVCalculator proxy address.
    constructor(address navCalculator_) {
        require(navCalculator_.code.length > 0, "NavLens: not a contract");
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Returns all positions for `account` with human-readable labels.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    function getAccountPositionsVerbose(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory)
    {
        return _toVerbose(NAV_CALCULATOR.getAccountPositions(account, quoteAsset));
    }

    /// @notice Returns positions filtered by a single asset, with human-readable labels.
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    function getAccountPositionsForAssetVerbose(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory)
    {
        return _toVerbose(NAV_CALCULATOR.getAccountPositionsForAsset(account, asset, quoteAsset));
    }

    /// @notice Returns the aggregate NAV and full verbose position breakdown in one call.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    function getAccountNavVerbose(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerboseNAV memory verboseNav)
    {
        verboseNav.nav = NAV_CALCULATOR.getAccountNav(account, quoteAsset);
        verboseNav.positions = _toVerbose(NAV_CALCULATOR.getAccountPositions(account, quoteAsset));
    }

    /// @notice Enriches a Position[] with human-readable labels from IPositionDescribable on each adapter.
    function _toVerbose(INAVCalculator.Position[] memory pos)
        internal
        view
        returns (INAVCalculator.VerbosePosition[] memory verbose)
    {
        uint256 len = pos.length;
        verbose = new INAVCalculator.VerbosePosition[](len);
        for (uint256 i = 0; i < len; i++) {
            address adapter = pos[i].balanceAdapter;
            string memory name = _safeString(adapter, abi.encodeCall(IPositionDescribable.protocolName, ()));
            string memory label =
                _safeString(adapter, abi.encodeCall(IPositionDescribable.describePosition, (pos[i].positionId)));
            verbose[i] = INAVCalculator.VerbosePosition({position: pos[i], protocolName: name, positionLabel: label});
        }
    }

    /// @notice Fully fail-open string read: staticcalls `target` and returns the decoded string only when the
    ///         returndata is a well-formed ABI string, otherwise "".
    /// @dev A plain `try/catch` only catches a reverting call — it does NOT catch a *successful* call whose
    ///      returndata cannot be decoded into `string` (e.g. a non-contract returning empty data, or a contract
    ///      returning a malformed/short blob), which would revert the whole verbose read. This validates the
    ///      ABI envelope (canonical 0x20 offset + length within bounds) before decoding so it can never revert.
    function _safeString(address target, bytes memory callData) private view returns (string memory) {
        (bool ok, bytes memory ret) = target.staticcall(callData);
        if (!ok || ret.length < 64) return ""; // need at least offset(32) + length(32)
        uint256 offset;
        uint256 strLen;
        assembly {
            offset := mload(add(ret, 0x20))
            strLen := mload(add(ret, 0x40))
        }
        // canonical ABI-encoded string has offset == 0x20 and the declared length must fit the returned bytes
        if (offset != 0x20 || ret.length < 64 + strLen) return "";
        return abi.decode(ret, (string));
    }
}
