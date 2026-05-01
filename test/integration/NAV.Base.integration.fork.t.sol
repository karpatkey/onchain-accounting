// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";

/// @notice Base integration test. Accounts, fork block, and expected NAVs come from
///         test/integration/accounts.json — refresh them via
///         script/test/refresh-integration-snapshot.sh
///         (see docs/howto/refresh-integration-test-blocks.md).
contract BaseIntegrationFromConfig is IntegrationFromConfigBase {
    function setUp() public {
        _chainId = 8453;
        _forkNetwork = "base-mainnet";
        _setupAndDeploy();
    }

    function test_accountNavs() public view {
        _assertNavsForCurrentChain();
    }
}
