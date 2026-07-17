// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {BridgeTestBase} from "./BridgeTestBase.fork.sol";
import {MockBridgeAdapter} from "../mocks/MockBridgeAdapter.sol";

/// @title BridgeEscrowConfigRehearsal (Fork)
/// @notice Phase-1 fork rehearsal for the bridge deploy plan: proves the config-driven post-deploy step that
///         `06_Configure.s.sol` runs — authorize accounts + register assets from
///         `contracts-deployment-config/bridge-escrow/<chainId>.json` — turns a freshly-deployed, prod-like EMPTY
///         escrow (as `02_DeployProxies.s.sol` leaves it: no accounts, no assets) into a working deposit path.
/// @dev The existing per-adapter fork tests deploy an escrow that is already seeded with an authorized account +
///      registered assets in `setUp`, so they never exercise the empty→config-applied transition. This test closes
///      that gap: it deploys an empty escrow, then applies config through the SAME `ConfigReader` readers + escrow
///      calls (`authorizeAccount`/`registerAsset`) that `06_Configure` makes, and drives a `depositAndBridge` (through
///      a no-op `MockBridgeAdapter`) to prove the escrow-side preconditions are satisfied end-to-end. It does NOT
///      re-run `06`'s script harness or its role bootstrapping (it grants MANAGER to `admin` itself, mirroring the
///      `_ensureManager` step `06` performs), and it does NOT reproduce the cross-chain transport — that is covered by
///      the per-protocol fork tests against the real protocol contracts.
contract BridgeEscrowConfigRehearsalForkTest is BridgeTestBase {
    using ConfigReader for *;

    /// @dev Throwaway chain-id whose bridge-escrow config file is written/removed within a single test, so the
    ///      rehearsal of the accounts path is independent of how the committed per-chain configs happen to be authored
    ///      (the committed files ship with `accounts: []`, filled per deployment).
    uint256 internal constant FIXTURE_CHAIN_ID = 987654;

    function _fixturePath() internal view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/bridge-escrow/",
                vm.toString(FIXTURE_CHAIN_ID),
                ".json"
            )
        );
    }

    /// @notice Deploys a fresh BridgeEscrow proxy pinned to mainnet with NO authorized accounts and NO registered
    ///         assets — exactly the state `02_DeployProxies.s.sol` leaves in production. Grants MANAGER to `admin` so
    ///         the config step (registerAsset is MANAGER-gated; authorizeAccount is admin-gated) can run as `admin`.
    function _deployEmptyEscrow() internal returns (BridgeEscrow escrow) {
        address impl = address(new BridgeEscrow());
        address[] memory noSafes = new address[](0);
        address[] memory noAdapters = new address[](0);
        address payable proxy = payable(UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(BridgeEscrow.initialize, (admin, MAINNET_CHAIN_ID, noSafes, noAdapters))
            ));
        escrow = BridgeEscrow(proxy);
        vm.prank(admin);
        escrow.grantRole(MANAGER, admin);
    }

    /// @notice Applies the bridge-escrow config for `cfgChainId` to `escrow` using the same `ConfigReader` reads and
    ///         the same escrow mutators (`authorizeAccount` per `.accounts` entry, `registerAsset` per `.assets` entry)
    ///         that `06_Configure` drives. This is a deliberately straight single-pass apply — it does NOT replicate
    ///         `06`'s idempotency/placeholder guards (skip `address(0)`, skip already-authorized accounts, skip a
    ///         symbol already mapped to the same address). Those guards exist in `06` for re-runnability; here the
    ///         escrow is freshly deployed and the config is applied exactly once, so they are unnecessary. The fixtures
    ///         used by the tests carry only real addresses and a single account, so no skip path is exercised.
    function _applyBridgeEscrowConfig(BridgeEscrow escrow, uint256 cfgChainId) internal {
        address[] memory accounts = ConfigReader.readBridgeEscrowAccounts(vm, cfgChainId);
        string[] memory symbols = ConfigReader.readBridgeEscrowAssetSymbols(vm, cfgChainId);
        vm.startPrank(admin);
        for (uint256 i = 0; i < accounts.length; i++) {
            escrow.authorizeAccount(accounts[i]);
        }
        for (uint256 i = 0; i < symbols.length; i++) {
            escrow.registerAsset(symbols[i], ConfigReader.readBridgeEscrowAssetAddress(vm, cfgChainId, symbols[i]));
        }
        vm.stopPrank();
    }

    /// @notice The committed mainnet bridge-escrow config (chain 1) registers assets that resolve to REAL on-chain
    ///         ERC20s, and — since it ships with `accounts: []` — authorizes no account.
    function test_committedMainnetAssetConfig_registersRealTokens() public {
        BridgeEscrow escrow = _deployEmptyEscrow();
        _applyBridgeEscrowConfig(escrow, 1);

        assertEq(escrow.assetRegistry(USDC_SYMBOL), MAINNET_USDC, "committed USDC must map to mainnet USDC");
        assertEq(escrow.assetRegistry(WETH_SYMBOL), MAINNET_WETH, "committed WETH must map to mainnet WETH");
        // The mapped addresses are live ERC20s on the fork (a non-zero supply is a cheap liveness proxy).
        assertGt(IERC20(MAINNET_USDC).totalSupply(), 0, "USDC should be a live ERC20 on the fork");
        assertGt(IERC20(MAINNET_WETH).totalSupply(), 0, "WETH should be a live ERC20 on the fork");
        // Committed accounts list is empty → no account is authorized by config alone.
        assertFalse(escrow.isAuthorizedAccount(account), "committed config authorizes no account");
    }

    /// @notice Full gap-step rehearsal: an empty escrow + a config carrying an account and assets yields a working
    ///         deposit path. Uses a throwaway fixture config (accounts filled) since the committed files ship empty.
    function test_gapStep_fixtureConfig_enablesDeposit() public {
        // Fixture: one authorized account + the real mainnet USDC/WETH assets.
        string memory fixture = string(
            abi.encodePacked(
                '{"accounts":["',
                vm.toString(account),
                '"],"assets":{"USDC":"',
                vm.toString(MAINNET_USDC),
                '","WETH":"',
                vm.toString(MAINNET_WETH),
                '"}}'
            )
        );
        vm.writeFile(_fixturePath(), fixture);

        BridgeEscrow escrow = _deployEmptyEscrow();
        // Sanity: prod-like empty before the config step.
        assertFalse(escrow.isAuthorizedAccount(account), "escrow starts with no authorized account");
        assertEq(escrow.assetRegistry(USDC_SYMBOL), address(0), "escrow starts with no registered USDC");

        _applyBridgeEscrowConfig(escrow, FIXTURE_CHAIN_ID);
        vm.removeFile(_fixturePath()); // remove before assertions so a failure never leaves the fixture behind

        // Config applied: account authorized, assets registered.
        assertTrue(escrow.isAuthorizedAccount(account), "config should authorize the account");
        assertEq(escrow.assetRegistry(USDC_SYMBOL), MAINNET_USDC, "config should register USDC");
        assertEq(escrow.assetRegistry(WETH_SYMBOL), MAINNET_WETH, "config should register WETH");

        // A no-op adapter is enough to prove the escrow-side deposit preconditions pass (real transport is covered by
        // the per-protocol fork tests). Deploy + authorize it, then bridge.
        address mockImpl = address(new MockBridgeAdapter());
        address mockAdapter = UnsafeUpgrades.deployUUPSProxy(
            mockImpl, abi.encodeCall(MockBridgeAdapter.initialize, (admin, address(escrow), "Mock", "1.0.0"))
        );
        vm.prank(admin);
        escrow.authorizeAdapter(mockAdapter);

        uint256 amount = TEST_AMOUNT_USDC;
        deal(MAINNET_USDC, account, amount);
        vm.startPrank(account);
        IERC20(MAINNET_USDC).approve(address(escrow), amount);
        bytes32 invoiceHash = escrow.depositAndBridge(OPTIMISM_CHAIN_ID, USDC_SYMBOL, amount, mockAdapter);
        vm.stopPrank();

        // Deposit succeeded through the escrow: invoice created + funds moved into the escrow + in-transit tracked.
        assertTrue(invoiceHash != bytes32(0), "depositAndBridge should return an invoice hash");
        assertEq(
            uint256(escrow.getInvoice(invoiceHash).status),
            uint256(IBridgeEscrow.InvoiceStatus.BRIDGING),
            "invoice BRIDGING"
        );
        assertEq(IERC20(MAINNET_USDC).balanceOf(account), 0, "account USDC fully pulled");
        assertEq(IERC20(MAINNET_USDC).balanceOf(address(escrow)), amount, "escrow holds the deposited USDC");
        assertEq(
            escrow.getInTransitBalanceForAsset(MAINNET_USDC, account), amount, "in-transit balance tracks the deposit"
        );
    }
}
