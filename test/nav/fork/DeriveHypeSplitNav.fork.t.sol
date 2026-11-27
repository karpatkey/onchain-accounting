// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {MANAGER} from "src/constants.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {DeriveForkFixture} from "test/balances/AttestedBalanceAdapters/derive/DeriveForkFixture.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @title DeriveHypeSplitNavForkTest
/// @notice Proof of concept: the hype-split test fund's Derive account (Portfolio Safe 0x8C79…7476, subaccounts
///         122118 and 122119; kpk-labs/OIV-harness#131) enters an Ethereum `NAVCalculator` through
///         `DeriveCelestiaAttestedBalanceAdapter`, proven against the real VAPP on a mainnet fork.
/// @dev Fixture `test/integration/derive-celestia/fork-hype-split.json`, built with
///      `script/test/derive-celestia-proof.py --subaccount 122118 --subaccount 122119 --block 26450225`: the batch
///      that applied the fund's first deposit (Derive action 8651), so both records are in the blob VAPP commits to
///      at that block.
///
///      HYPE is priced by a FIXED mock feed. Chainlink publishes no HYPE/USD feed on Ethereum (its mainnet feed
///      directory, checked 2026-11-27, lists none), and the fund's real NAV runs on HyperEVM where the shares live.
///      The price is Derive's HYPE mark from the PR #131 snapshot (67.677 USD, 2026-11-19 16:34 UTC). It is the only
///      mock here: VAPP, the proof, the adapter, NAVCalculator and the ETH/USD feed are real.
contract DeriveHypeSplitNavForkTest is TestEnvConfigurator {
    address internal constant VAPP = 0xd330145C17fB6EF2a21ACf1275Ce683A305F58BB;
    bytes32 internal constant VKEY = 0x00bc954fe627a8c36173e608608795425e22b4134914c7da5bd233b4718c855b;
    address internal constant VERIFIER = 0x3B6041173B80E77f038f3F2C0f9744f04837185e;

    address internal constant PORTFOLIO_SAFE = 0x8C79753AAD88183f5747C91684d6C0CBfCB27476;
    address internal constant DERIVE_HYPE = 0x2dd469DB6ee0dBF0277F0f3021fd8a6486A751ce;
    /// @dev The LayerZero HYPE OFT: the token `WithdrawalOutbox.resolveAsset(DERIVE_HYPE)` pays out.
    address internal constant HYPE_OFT = 0x0762365e088Fb8D285b295d782BB7b23690713e2;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 internal constant HYPE_USD_8 = 67.677e8;

    address internal admin = makeAddr("admin");
    NAVCalculator internal nav;
    DeriveCelestiaAttestedBalanceAdapter internal adapter;
    string internal json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/fork-hype-split.json"));
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), vm.parseJsonUint(json, ".forkBlock"));
        // NAVCalculator delegatecalls these at pinned CREATE2 addresses; put this tree's code there.
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        vm.startPrank(admin);
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                address(new NAVCalculator()), abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
            )
        );
        nav.grantRole(MANAGER, admin);
        nav.addOrModifyPriceFeed(nav.NATIVE_ADDRESS(), CHAINLINK_ETH_USD, IPrices.PriceType.Chainlink, 3600);
        Mock_CustomPriceFeed hypeUsd = new Mock_CustomPriceFeed("HYPE", HYPE_OFT, HYPE_USD_8, 8);
        nav.registerAsset(HYPE_OFT, address(hypeUsd), IPrices.PriceType.Custom, type(uint256).max);

        address[] memory ids = new address[](1);
        address[] memory toks = new address[](1);
        (ids[0], toks[0]) = (DERIVE_HYPE, HYPE_OFT);
        adapter = new DeriveCelestiaAttestedBalanceAdapter(
            VAPP, address(nav), admin, VKEY, VERIFIER, ids, toks, address(0), address(0)
        );
        adapter.grantRole(adapter.SUBMITTER_ROLE(), admin);
        nav.addBalanceAdapters(aa(address(adapter)));
        vm.stopPrank();
    }

    function _navUsd() internal view returns (int256) {
        return nav.getAccountNav(PORTFOLIO_SAFE, address(0)).value;
    }

    /// @notice Before a submit the Derive leg reads 0; after it, NAV rises by exactly 0.12 HYPE at the HYPE price.
    function test_submit_addsDeriveLegToNav() public {
        int256 before = _navUsd();
        assertEq(adapter.getAdapterPositions(PORTFOLIO_SAFE, address(0)).length, 0, "no Derive leg before submit");

        vm.prank(admin);
        adapter.submit(PORTFOLIO_SAFE, DeriveForkFixture.payload(json));

        (uint256 hype,) = adapter.getAdapterBalanceForAsset(PORTFOLIO_SAFE, HYPE_OFT);
        assertEq(hype, vm.parseJsonUint(json, ".expected[0].amount"), "attested HYPE");
        assertEq(hype, 0.12 ether, "0.12 HYPE deposited by Derive action 8651");
        assertEq(_navUsd() - before, int256(hype * HYPE_USD_8 / 1 ether), "NAV gains the Derive leg in USD");
    }

    /// @notice Once VAPP's newest batch is older than MAX_ATTESTATION_AGE the leg reads 0 again: NAV
    ///         under-reports instead of carrying a stale Derive value.
    function test_staleBatch_dropsDeriveLegFromNav() public {
        int256 before = _navUsd();
        vm.prank(admin);
        adapter.submit(PORTFOLIO_SAFE, DeriveForkFixture.payload(json));
        assertGt(_navUsd(), before, "precondition: the leg counts while fresh");

        vm.warp(block.timestamp + adapter.MAX_ATTESTATION_AGE() + 1);
        assertFalse(adapter.isAttestationLive(PORTFOLIO_SAFE, HYPE_OFT));
        assertEq(_navUsd(), before, "stale Derive leg is not in NAV");
    }
}
