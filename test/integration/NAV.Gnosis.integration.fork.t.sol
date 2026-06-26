// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";

/// @notice Gnosis integration test. Accounts, fork block, and expected NAVs come from
///         test/integration/accounts.json — refresh them via
///         script/test/refresh-integration-snapshot.sh
///         (see docs/howto/refresh-integration-test-blocks.md).
contract GnosisIntegrationFromConfig is IntegrationFromConfigBase {
    function setUp() public {
        _chainId = 100;
        _forkNetwork = "gnosis-mainnet";
        _setupAndDeploy();
    }

    function test_accountNavs() public view {
        _assertNavsForCurrentChain();
    }
}
