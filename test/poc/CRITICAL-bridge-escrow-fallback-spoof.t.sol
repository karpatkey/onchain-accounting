// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test, console} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @notice REGRESSION (ADR 0012, C1 — UNAUTHENTICATED drain vector closed in this PR): the escrow no longer
///         has a `fallback()` dispatcher, and `releaseByInvoiceId` is callable only by an authorized adapter
///         (never reachable through a public fallback). The original exploit fabricated a valid messagePayload
///         (the checksum is keccak256 of public data — no signing key) and pushed it through
///         escrow.fallback -> adapter.lzReceive -> escrow.releaseByInvoiceId to drain the escrow with no real
///         bridge delivery. This test asserts that exact unauthenticated attack now FAILS: the raw call does
///         not drain the escrow, balances are unchanged, and the forged invoice is NOT marked completed.
/// @dev    SCOPE: this closes the *permissionless* drain. It does NOT yet make release fully provable — in
///         this PR release still pays from the escrow's standing balance, and a MANAGER can drive
///         adapter.completeBridge (no provenance check yet) with a forged payload to release from that
///         balance. Full closure — per-adapter provenance + per-invoice funded pass-through (H9/D4) so release
///         draws only the funds the genuine delivery brought in — is the follow-up adapter-provenance PR.
contract Poc_BridgeEscrowFallbackSpoof is Test {
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public account = makeAddr("account");
    address public attacker = makeAddr("attacker");

    BridgeEscrow public destEscrow;
    StargateBridgeAdapter public destAdapter;
    Mock_ERC20 public usdc;

    uint64 public constant SOURCE_CHAIN_ID = 1;
    uint64 public constant DEST_CHAIN_ID = 10;
    string public constant USDC_SYMBOL = "USDC";
    bytes6 public constant USDC_SYMBOL_BYTES6 = "USDC  ";

    function setUp() public {
        vm.chainId(uint256(DEST_CHAIN_ID));
        usdc = new Mock_ERC20("USDC", 6);

        // Deploy escrow on destination chain
        address impl = address(new BridgeEscrow());
        address[] memory initialAccounts = new address[](1);
        initialAccounts[0] = account;
        address[] memory initialAdapters = new address[](0);
        address payable proxy = payable(UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(BridgeEscrow.initialize, (admin, DEST_CHAIN_ID, initialAccounts, initialAdapters))
            ));
        destEscrow = BridgeEscrow(proxy);

        // Grant MANAGER to admin (registerAsset is MANAGER-gated)
        vm.startPrank(admin);
        destEscrow.grantRole(MANAGER, admin);
        destEscrow.registerAsset(USDC_SYMBOL, address(usdc));
        vm.stopPrank();

        // Deploy Stargate adapter and register lzReceive callback
        address adapterImpl = address(new StargateBridgeAdapter(address(0)));
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(StargateBridgeAdapter.initialize, (admin, address(destEscrow), address(0xBEEF), "1.0.0"))
        );
        destAdapter = StargateBridgeAdapter(payable(adapterProxy));

        // ADR 0012: adapters are authorized only via authorizeAdapter (no callback registration exists).
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(adapterProxy);
        vm.stopPrank();

        // Seed the escrow with USDC the attacker wants to drain
        usdc.mint(address(destEscrow), 1_000_000e6);
    }

    /// @notice REGRESSION: the original drain attack now fails. With the fallback dispatcher removed, the
    ///         attacker's raw call to the escrow reaches no release path: the escrow balance is unchanged,
    ///         the account receives nothing, and the forged invoice is NOT marked completed.
    function test_regression_fallbackSpoofNoLongerDrains() public {
        uint256 stolen = 750_000e6;
        uint256 escrowBefore = usdc.balanceOf(address(destEscrow));
        uint256 accountBefore = usdc.balanceOf(account);

        // 1. Attacker fabricates a valid-looking invoice payload — no key required (checksum is public data).
        bytes32 invoiceId = _packInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6);
        uint64 ts = uint64(block.timestamp);
        uint256 nonce = 0;
        bytes24 checksum24 = InvoiceDataLib.calculateChecksum(invoiceId, stolen, ts, nonce);
        InvoiceDataLib.InvoiceData memory fake = InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: SafeCast.toUint24(SOURCE_CHAIN_ID),
            destinationChainId: SafeCast.toUint24(DEST_CHAIN_ID),
            account: account,
            assetSymbol: USDC_SYMBOL_BYTES6,
            amount: stolen,
            nonce: nonce,
            timestamp: ts,
            checksum24: checksum24
        });
        bytes memory payload = InvoiceDataLib.encode(fake);

        // 2. Encode the old lzReceive dispatch attempt (historical Stargate V1 callback selector 0x001d3567).
        //    Previously the escrow.fallback() would have looked up a registered adapter for this selector and
        //    forwarded via .call. There is no fallback anymore, so any such selector hits no code path.
        bytes memory lzReceiveCalldata = abi.encodeWithSelector(
            bytes4(0x001d3567), // lzReceive(uint16,bytes,uint64,bytes)
            uint16(101), // _srcChainId
            bytes(""), // _srcAddress
            uint64(0), // _nonce
            payload // _payload
        );

        // 3. Anyone (the attacker) calls the escrow with this data. With no fallback dispatcher, the call
        //    cannot be coaxed into reaching releaseByInvoiceId.
        vm.prank(attacker);
        (bool success,) = address(destEscrow).call(lzReceiveCalldata);
        assertFalse(success, "no fallback dispatcher: the spoof call must not succeed");

        // 4. Nothing left the escrow; the account received nothing.
        uint256 escrowAfter = usdc.balanceOf(address(destEscrow));
        uint256 accountAfter = usdc.balanceOf(account);
        console.log("escrow USDC before:", escrowBefore);
        console.log("escrow USDC after :", escrowAfter);
        console.log("account USDC before:", accountBefore);
        console.log("account USDC after :", accountAfter);

        assertEq(escrowAfter, escrowBefore, "escrow balance unchanged (no drain)");
        assertEq(accountAfter, accountBefore, "account balance unchanged (no payout)");

        // 5. The forged invoice was never marked completed on the destination.
        bytes32 invoiceHash = bytes32(uint256(uint192(checksum24)));
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "forged invoice must NOT be marked completed");
    }

    function _packInvoiceId(uint64 srcId, uint64 dstId, address acct, bytes6 sym) internal pure returns (bytes32) {
        return bytes32(
            (uint256(SafeCast.toUint24(srcId)) << 232) | (uint256(SafeCast.toUint24(dstId)) << 208)
                | (uint256(uint160(acct)) << 48) | uint256(uint48(sym))
        );
    }
}
