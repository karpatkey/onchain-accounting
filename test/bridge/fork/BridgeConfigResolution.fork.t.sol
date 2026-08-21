// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

/// @title BridgeConfigResolution (Fork)
/// @notice Pre-deploy gate (plan Phase A3): asserts every fixed external protocol address configured for an ENABLED
///         bridge adapter in `contracts-deployment-config/bridge-adapters/<chainId>.json` resolves to a LIVE contract
///         (non-zero code) on that chain, at HEAD. The per-adapter fork suites use hardcoded test constants, so a
///         wrong or stale address in the config JSON (e.g. an L1-standard-bridge typo) is invisible to them — this
///         closes that gap and makes "deploy then discover a bad address" a test failure instead of a mainnet redo.
/// @dev Checks ONLY same-chain, deploy-immutable infra addresses. Deliberately excluded:
///      - `admin` / `bridgeEscrow`: populated at deploy time (05 overrides with the deployer / the fresh proxy).
///      - `l1Messenger` on the Superchain adapter: a cross-layer (L1) address on the L2 configs, so it has no code on
///        an L2 fork; on the L1 config it is "stored but unused on the L1 execution path" per the config comment.
///      - `version` / `cctpDomain`: not addresses.
///      The Superchain L1 arrays (`l1Bridges` / `optimismPortals`) exist only on the L1 (chain-1) config and ARE
///      checked there. One test per chain so a failure names the offending chain; run under FOUNDRY_PROFILE=slow.
contract BridgeConfigResolutionForkTest is TestEnvConfigurator {
    string internal constant CFG_DIR = "/script/config/contracts-deployment-config/bridge-adapters/";

    /// @dev Every OP-stack adapter name that may appear in a bridge-adapters config.
    function _adapterNames() internal pure returns (string[] memory a) {
        a = new string[](6);
        a[0] = "CCIP";
        a[1] = "Across";
        a[2] = "Stargate";
        a[3] = "CCTP";
        a[4] = "Gnosis";
        a[5] = "Superchain";
    }

    /// @dev Same-chain external protocol address params to verify. NOT admin/bridgeEscrow (deploy-populated),
    ///      version/cctpDomain (not addresses), or l1Messenger (cross-layer on L2 configs).
    function _scalarAddressParams() internal pure returns (string[] memory p) {
        p = new string[](11);
        p[0] = "router"; // CCIP
        p[1] = "feeToken"; // CCIP (LINK)
        p[2] = "spokePool"; // Across
        p[3] = "endpoint"; // Stargate (LayerZero)
        p[4] = "tokenMessenger"; // CCTP
        p[5] = "messageTransmitter"; // CCTP
        p[6] = "omnibridge"; // Gnosis
        p[7] = "amb"; // Gnosis
        p[8] = "usdcTransmuter"; // Gnosis (same-chain USDC.e -> native USDC)
        p[9] = "l2Bridge"; // Superchain (L2 predeploy)
        p[10] = "l2Messenger"; // Superchain (L2 predeploy)
    }

    function _configJson(uint256 chainId) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), CFG_DIR, vm.toString(chainId), ".json"));
    }

    /// @notice Forks `slug` at HEAD and asserts every configured, non-placeholder protocol address for each enabled
    ///         adapter has code. Returns the number of addresses checked (a guard against a silently-skipped config).
    function _assertProtocolAddressesLive(uint256 chainId, string memory slug) internal {
        createSelectForkWithCadence(getAlchemyUrl(slug));
        string memory json = _configJson(chainId);
        string[] memory adapters = _adapterNames();
        string[] memory params = _scalarAddressParams();

        uint256 checked;
        for (uint256 i = 0; i < adapters.length; i++) {
            string memory ab = string.concat(".", adapters[i]);
            if (!vm.keyExistsJson(json, ab)) continue;
            if (
                !vm.keyExistsJson(json, string.concat(ab, ".enabled"))
                    || !vm.parseJsonBool(json, string.concat(ab, ".enabled"))
            ) {
                continue;
            }

            for (uint256 j = 0; j < params.length; j++) {
                string memory key = string.concat(ab, ".initialize.", params[j]);
                if (!vm.keyExistsJson(json, key)) continue;
                string memory s = vm.parseJsonString(json, key);
                if (bytes(s).length != 42) continue; // skip "" placeholders (admin/bridgeEscrow are filled at deploy)
                address a = vm.parseAddress(s);
                // An explicit zero address is an intentional "disabled/optional" sentinel — e.g. `usdcTransmuter`
                // is address(0) on the Ethereum-side Gnosis adapter (native USDC, no swap). There is no live
                // contract to assert for those, so skip. Required params are non-zero and DO get the live-contract
                // check below; the `assertGt(checked, 0)` at the end guards against a config that resolved nothing.
                if (a == address(0)) continue;
                assertGt(
                    a.code.length,
                    0,
                    string.concat(
                        "chain ", vm.toString(chainId), " ", adapters[i], ".", params[j], " not a live contract: ", s
                    )
                );
                checked++;
            }

            // Superchain L1 arrays (index-aligned with l2ChainIds) — present only on the L1 config.
            checked += _assertAddressArrayLive(json, string.concat(ab, ".l1Bridges"), chainId, "l1Bridges");
            checked += _assertAddressArrayLive(json, string.concat(ab, ".optimismPortals"), chainId, "optimismPortals");
        }

        assertGt(checked, 0, string.concat("chain ", vm.toString(chainId), ": no protocol addresses were checked"));
    }

    function _assertAddressArrayLive(string memory json, string memory key, uint256 chainId, string memory label)
        internal
        view
        returns (uint256 checked)
    {
        if (!vm.keyExistsJson(json, key)) return 0;
        address[] memory addrs = vm.parseJsonAddressArray(json, key);
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == address(0)) continue;
            require(
                addrs[i].code.length > 0,
                string.concat("chain ", vm.toString(chainId), " ", label, "[", vm.toString(i), "] not a live contract")
            );
            checked++;
        }
    }

    function test_configAddressesResolve_ethereum() public {
        _assertProtocolAddressesLive(1, "eth-mainnet");
    }

    function test_configAddressesResolve_optimism() public {
        _assertProtocolAddressesLive(10, "opt-mainnet");
    }

    function test_configAddressesResolve_gnosis() public {
        _assertProtocolAddressesLive(100, "gnosis-mainnet");
    }

    function test_configAddressesResolve_arbitrum() public {
        _assertProtocolAddressesLive(42161, "arb-mainnet");
    }

    function test_configAddressesResolve_base() public {
        _assertProtocolAddressesLive(8453, "base-mainnet");
    }
}
