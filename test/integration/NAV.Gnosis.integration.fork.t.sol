// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

contract GnosisIntegrationFromConfig is IntegrationFromConfigBase {
    address internal constant ACCOUNT_1 = 0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6;
    address internal constant ACCOUNT_2 = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b;
    address internal constant ACCOUNT_3 = 0x408ea1bC71ec2562ABCB27520cf7077718403496;

    function setUp() public {
        _chainId = 100;
        _forkBlock = 45922000;
        _forkNetwork = "gnosis-mainnet";
        _setupAndDeploy();
    }

    /// @notice NAV captured at block 45922000. Compare value/1e8 against Debank's USD total for each account.
    function test_account1_nav() public view {
        INAVCalculator.NAV memory n = _readUsdNav(ACCOUNT_1);
        _logNav("ACCOUNT_1", ACCOUNT_1);
        assertEq(n.value, int256(500474218), "ACCOUNT_1 NAV mismatch (8dp USD)");
        assertEq(n.stalePriceAssets.length, 0, "stale prices");
        assertEq(n.sequencerDown, false, "sequencer down");
    }

    function test_account2_nav() public view {
        INAVCalculator.NAV memory n = _readUsdNav(ACCOUNT_2);
        _logNav("ACCOUNT_2", ACCOUNT_2);
        assertEq(n.value, int256(0), "ACCOUNT_2 NAV mismatch (8dp USD)");
        assertEq(n.stalePriceAssets.length, 0, "stale prices");
        assertEq(n.sequencerDown, false, "sequencer down");
    }

    function test_account3_nav() public view {
        INAVCalculator.NAV memory n = _readUsdNav(ACCOUNT_3);
        _logNav("ACCOUNT_3", ACCOUNT_3);
        assertEq(n.value, int256(0), "ACCOUNT_3 NAV mismatch (8dp USD)");
        assertEq(n.stalePriceAssets.length, 0, "stale prices");
        assertEq(n.sequencerDown, false, "sequencer down");
    }
}
