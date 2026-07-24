// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

/// @title BridgeDeployedState (Fork)
/// @notice Pre-canary gate: exercises `depositAndBridge` on the ACTUAL deployed + wired BridgeEscrow and adapters
///         (not a fresh test deploy) for one representative lane per enabled adapter on each of the 5 chains, forking
///         at HEAD. A success means the live wiring `06` produced — asset registered, adapter authorized, trusted
///         remote set — plus the adapter's real `_bridge` call into the genuine protocol contract all line up. It is
///         the free "is anything mis-wired before we spend real money" check that sits between the read-only wiring
///         verification and the real cent-sized canaries. It does NOT (and cannot) exercise the off-chain relay
///         (Circle / LayerZero / CCIP / Across / AMB) — that is what the real canary proves.
/// @dev The deployed escrow is dormant (no authorized accounts), so each lane pranks the live admin (0xd8A2…, which
///      still holds DEFAULT_ADMIN on the fork) to authorize a throwaway account, deals it the registered token, and
///      deposits. Fee-bearing adapters (Stargate/CCIP) are pre-funded with native (they pay LZ/CCIP fees from their
///      own balance; mirrors the per-adapter fork suites). Each lane runs inside try/catch so one mis-wired lane
///      surfaces the whole matrix instead of aborting. Run: FOUNDRY_PROFILE=slow, single-thread.
contract BridgeDeployedStateForkTest is TestEnvConfigurator {
    // Same-address deployment (all 5 chains).
    address internal constant ESCROW = 0x4B0fbca357cdE8FABc3f6c7fD7718B9F61b54c6f;
    address internal constant ADMIN = 0xd8A2FEc270d6D68B9fA5DBFe5CbEDDE7CefCd7D4;
    address internal constant CCIP = 0x51088cCDA8E3Caf9e14CC8bb9475a0FF9f65338f; // salt-2 (receive() fix)
    address internal constant ACROSS = 0x6FDa302B3ccDf249E5Eda37e3F80B512bf1dC5d2; // salt-2 (output-token fix)
    address internal constant STARGATE = 0x2016E3040fba19033d78dfdB9B67Fd6230f4960a;
    address internal constant GNOSIS = 0xC0974552fAf6522f61a9DC7532f6703745F53d86; // salt-3 (delivered-token guard)
    address internal constant CCTP = 0xCfA923f5f0a8A3c17F8793CF8C1207293D781b5c; // salt-2 (burnToken fix)
    address internal constant SUPERCHAIN = 0x30C47706eF3602cDDdD4fad9B708368C5baA1708; // salt-3 (prove chainId guard)

    address internal acct = makeAddr("deployedStateAcct");

    uint256 internal passes;
    uint256 internal fails;

    /// @notice Drives one lane on the deployed escrow. External so the caller can try/catch it.
    function runLane(address adapter, string calldata symbol, uint64 dest, bool feePrefund) external {
        BridgeEscrow escrow = BridgeEscrow(payable(ESCROW));

        // Authorize a throwaway account (live admin holds DEFAULT_ADMIN on the fork).
        vm.prank(ADMIN);
        escrow.authorizeAccount(acct);

        // Native ETH path (symbol "ETH", asset address(0)): the Superchain adapter moves native ETH — NOT native
        // USDC / WETH9 (not OptimismMintable). Register ETH in-fork (admin holds MANAGER) so we can exercise the
        // Superchain lane with a protocol-SUPPORTED asset, then deposit with msg.value. Free — fork only.
        if (keccak256(bytes(symbol)) == keccak256("ETH")) {
            vm.prank(ADMIN);
            escrow.registerAsset("ETH", address(0)); // idempotent (re-register to same address is a no-op)
            uint256 ethAmt = 5e14; // 0.0005 ETH
            vm.deal(acct, ethAmt + 1 ether);
            if (feePrefund) vm.deal(adapter, 1 ether);
            vm.prank(acct);
            bytes32 nh = escrow.depositAndBridge{value: ethAmt}(dest, symbol, ethAmt, adapter);
            require(nh != bytes32(0), "no invoice hash");
            require(escrow.getInvoice(nh).status == IBridgeEscrow.InvoiceStatus.BRIDGING, "invoice not BRIDGING");
            return;
        }

        address token = escrow.assetRegistry(symbol);
        require(token != address(0), string.concat("asset not registered: ", symbol));

        // WETH is 18-decimals (use 0.01); USDC/USDCe are 6-decimals (use 100).
        uint256 amount = keccak256(bytes(symbol)) == keccak256("WETH") ? 1e16 : 100e6;
        deal(token, acct, amount);

        // Stargate/CCIP pay the messaging fee from the adapter's own native balance.
        if (feePrefund) vm.deal(adapter, 1 ether);

        // Single-shot pranks (never startPrank): a revert inside depositAndBridge must not leave a prank active
        // for the next try/catch lane. Each vm.prank is consumed by exactly one external call.
        vm.prank(acct);
        IERC20(token).approve(ESCROW, amount);
        vm.prank(acct);
        bytes32 invoiceHash = escrow.depositAndBridge(dest, symbol, amount, adapter);

        require(invoiceHash != bytes32(0), "no invoice hash");
        require(escrow.getInvoice(invoiceHash).status == IBridgeEscrow.InvoiceStatus.BRIDGING, "invoice not BRIDGING");
    }

    function _lane(string memory label, address adapter, string memory symbol, uint64 dest, bool feePrefund) internal {
        try this.runLane(adapter, symbol, dest, feePrefund) {
            passes++;
            emit log_named_string("  PASS", label);
        } catch Error(string memory reason) {
            fails++;
            emit log_named_string("  FAIL", string.concat(label, " -> ", reason));
        } catch (bytes memory lowlevel) {
            fails++;
            emit log_named_string("  FAIL", string.concat(label, " -> ", vm.toString(lowlevel)));
        }
    }

    function _fork(string memory slug) internal {
        createSelectForkWithCadence(getAlchemyUrl(slug));
    }

    function _finish() internal view {
        require(fails == 0, "one or more deployed-state lanes failed (see logs)");
    }

    // One representative lane per enabled adapter per chain. Destinations are valid trusted remotes; USDC unless the
    // adapter is WETH-oriented (Gnosis). Stargate/CCIP flagged for native fee pre-fund.

    function test_deployedState_ethereum() public {
        _fork("eth-mainnet");
        _lane("ETH CCIP->OP", CCIP, "USDC", 10, true);
        _lane("ETH Across->OP", ACROSS, "USDC", 10, false);
        _lane("ETH Stargate->OP", STARGATE, "USDC", 10, true);
        _lane("ETH CCTP->OP", CCTP, "USDC", 10, false);
        _lane("ETH Gnosis->GC", GNOSIS, "WETH", 100, false);
        _lane("ETH Superchain->OP (native ETH)", SUPERCHAIN, "ETH", 10, false);
        _finish();
    }

    function test_deployedState_optimism() public {
        _fork("opt-mainnet");
        _lane("OP CCIP->ETH", CCIP, "USDC", 1, true);
        _lane("OP Across->ETH", ACROSS, "USDC", 1, false);
        _lane("OP Stargate->ETH", STARGATE, "USDC", 1, true);
        _lane("OP CCTP->ETH", CCTP, "USDC", 1, false);
        _lane("OP Superchain->ETH (native ETH, L2->L1 initiate)", SUPERCHAIN, "ETH", 1, false);
        _finish();
    }

    function test_deployedState_gnosis() public {
        _fork("gnosis-mainnet");
        // CCIP is disabled on Gnosis (no CCIP token pool for the registered assets → router UnsupportedToken).
        // NOTE: this gate tracks the CURRENT live deployment, which registered the Gnosis USD symbol as "USDCe".
        // The bridge-escrow config has since been corrected to the logical symbol "USDC" (mapped to the same USDC.e
        // token 0x2a22f9c3 that Stargate delivers) — update this lane's symbol to "USDC" at the post-merge redeploy.
        _lane("GC Stargate->ETH", STARGATE, "USDCe", 1, true);
        _lane("GC Gnosis->ETH", GNOSIS, "WETH", 1, false);
        _finish();
    }

    function test_deployedState_arbitrum() public {
        _fork("arb-mainnet");
        _lane("ARB CCIP->ETH", CCIP, "USDC", 1, true);
        _lane("ARB Across->ETH", ACROSS, "USDC", 1, false);
        _lane("ARB Stargate->ETH", STARGATE, "USDC", 1, true);
        _lane("ARB CCTP->ETH", CCTP, "USDC", 1, false);
        _finish();
    }

    function test_deployedState_base() public {
        _fork("base-mainnet");
        _lane("BASE CCIP->ETH", CCIP, "USDC", 1, true);
        _lane("BASE Across->ETH", ACROSS, "USDC", 1, false);
        _lane("BASE Stargate->ETH", STARGATE, "USDC", 1, true);
        _lane("BASE CCTP->ETH", CCTP, "USDC", 1, false);
        _lane("BASE Superchain->ETH (native ETH, L2->L1 initiate)", SUPERCHAIN, "ETH", 1, false);
        _finish();
    }
}
