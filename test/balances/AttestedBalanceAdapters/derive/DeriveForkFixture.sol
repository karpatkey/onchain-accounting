// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Vm} from "forge-std/Vm.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {DeriveBlobBuilder} from "test/balances/AttestedBalanceAdapters/derive/DeriveBlobBuilder.sol";

/// @notice Turns a fork fixture written by `script/test/derive-celestia-proof.py` (`forkBlock`, `account`,
///         `firstShare`, `proofs[]`, `expected[]`) into `DeriveCelestiaAttestedBalanceAdapter.submit` arguments.
library DeriveForkFixture {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice A collateral-only submit payload: first share, every record proof, no option feeds.
    function payload(string memory json) internal view returns (bytes memory) {
        return abi.encode(share(json, ".firstShare"), proofs(json), abi.encode(DeriveBlobBuilder.noFeeds()));
    }

    function proofs(string memory json)
        internal
        view
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps)
    {
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".proofs[", vm.toString(n), "]"))) ++n;
        ps = new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".proofs[", vm.toString(i), "]");
            ps[i].subaccountId = vm.parseJsonUint(json, string.concat(k, ".subaccountId"));
            ps[i].recordOffset = vm.parseJsonUint(json, string.concat(k, ".recordOffset"));
            ps[i].usePrevious = vm.parseJsonBool(json, string.concat(k, ".usePrevious"));
            ps[i].prevOffset = vm.parseJsonUint(json, string.concat(k, ".prevOffset"));
            uint256 m;
            while (vm.keyExistsJson(json, string.concat(k, ".shares[", vm.toString(m), "]"))) ++m;
            ps[i].shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](m);
            for (uint256 j; j < m; ++j) {
                ps[i].shares[j] = share(json, string.concat(k, ".shares[", vm.toString(j), "]"));
            }
        }
    }

    function share(string memory json, string memory k)
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
