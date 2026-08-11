// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BridgeHeldBalanceAdapter} from "src/balances/BalanceAdapters/BridgeHeldBalanceAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title BridgeHeldBalanceAdapter fork tests
/// @notice Drives a real-USDC delivery through a fresh hold-then-claim BridgeEscrow on a mainnet fork and asserts
///         BridgeHeldBalanceAdapter reports the held custody with REAL asset metadata (decimals/symbol resolved
///         from the on-chain USDC + the Balances registry), then that a MANAGER claim clears it. The escrow is our
///         own contract (there is no third-party "holder" to fork against), so this test deploys it and records a
///         genuine delivery; the value over the mock unit suite is the real registered-asset metadata path.
contract BridgeHeldBalanceAdapterForkTest is BalanceAdapterTestBase {
    uint64 internal constant SRC_CHAIN_ID = 42161;
    uint64 internal constant DEST_CHAIN_ID = 1;
    bytes6 internal constant USDC_SYMBOL6 = "USDC  ";
    uint256 internal constant HELD_AMOUNT = 1_000e6;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal safe = makeAddr("safe");

    BridgeEscrow internal escrow;
    MockBridgeAdapter internal mockAdapter;
    BridgeHeldBalanceAdapter internal adapter;

    function setUp() public override {
        super.setUp(); // forks eth-mainnet at DEFAULT_FORK_BLOCK
        balances = _deployBalancesForAdapter(MAINNET_USDC); // real USDC registered in the Balances registry

        // Fresh hold-then-claim escrow with stored chainId == DEST_CHAIN_ID (recordDelivery validates the stored
        // chainId, not block.chainid), the safe authorized, and MANAGER granted.
        address[] memory safes = new address[](1);
        safes[0] = safe;
        address[] memory noAdapters = new address[](0);
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            address(new BridgeEscrow()),
            abi.encodeCall(BridgeEscrow.initialize, (admin, DEST_CHAIN_ID, safes, noAdapters))
        );
        escrow = BridgeEscrow(payable(proxy));

        vm.startPrank(admin);
        escrow.grantRole(MANAGER, admin); // registerAsset is MANAGER-gated
        escrow.grantRole(MANAGER, manager);
        escrow.registerAsset("USDC", MAINNET_USDC);
        mockAdapter = _deployMockAdapter(address(escrow));
        escrow.authorizeAdapter(address(mockAdapter));
        vm.stopPrank();

        adapter = new BridgeHeldBalanceAdapter(address(balances), address(escrow));
    }

    function test_fork_reportsHeldCustodyWithRealMetadata() public {
        bytes memory payload = _recordDelivery(HELD_AMOUNT);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(safe, address(0));
        assertEq(p.length, 1, "one held leg");
        assertEq(p[0].balanceAsset.asset, MAINNET_USDC, "USDC asset");
        assertEq(p[0].balanceAsset.decimals, 6, "real USDC decimals");
        assertEq(p[0].balanceAsset.symbol, "USDC", "real USDC symbol");
        assertEq(p[0].amount, HELD_AMOUNT, "held amount");
        assertFalse(p[0].isDebt, "credit");
        assertTrue(p[0].isLocked, "locked until claim");
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied));
        assertEq(p[0].protocolBrand, ProtocolIds.BRIDGE_ESCROW);
        assertEq(p[0].positionId, abi.encode(address(escrow)));

        // Getter surface agrees.
        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(safe, MAINNET_USDC);
        assertEq(amt, HELD_AMOUNT);
        assertFalse(isDebt);

        // Payload is consumed via recordDelivery; silence unused-var lints.
        assertGt(payload.length, 0);
    }

    function test_fork_claimClearsHeldReporting() public {
        bytes memory payload = _recordDelivery(HELD_AMOUNT);
        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24)));

        uint256 safeBefore = IERC20(MAINNET_USDC).balanceOf(safe);
        vm.prank(manager);
        escrow.claim(invoiceHash);

        assertEq(IERC20(MAINNET_USDC).balanceOf(safe) - safeBefore, HELD_AMOUNT, "safe credited exactly once");
        assertEq(adapter.getAdapterPositions(safe, address(0)).length, 0, "no held leg after claim");
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(safe, MAINNET_USDC);
        assertEq(amt, 0, "held cleared");
    }

    // ---- helpers ----

    function _deployMockAdapter(address escrow_) internal returns (MockBridgeAdapter) {
        address impl = address(new MockBridgeAdapter(address(0)));
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            impl, abi.encodeCall(MockBridgeAdapter.initialize, (admin, escrow_, "Mock", "1.0.0"))
        );
        return MockBridgeAdapter(payable(proxy));
    }

    /// @dev Builds a valid payload for `safe`, funds the mock adapter with real USDC, and records the delivery.
    function _recordDelivery(uint256 amount) internal returns (bytes memory payload) {
        bytes32 invoiceId = bytes32(
            (uint256(uint24(SRC_CHAIN_ID)) << 232) | (uint256(uint24(DEST_CHAIN_ID)) << 208)
                | (uint256(uint160(safe)) << 48) | uint256(uint48(USDC_SYMBOL6))
        );
        uint64 ts = uint64(block.timestamp);
        uint256 nonce = 0;
        bytes24 checksum = InvoiceDataLib.calculateChecksum(invoiceId, amount, ts, nonce);
        payload = InvoiceDataLib.encode(
            InvoiceDataLib.InvoiceData({
                invoiceId: invoiceId,
                sourceChainId: uint24(SRC_CHAIN_ID),
                destinationChainId: uint24(DEST_CHAIN_ID),
                account: safe,
                assetSymbol: USDC_SYMBOL6,
                amount: amount,
                nonce: nonce,
                timestamp: ts,
                checksum24: checksum
            })
        );

        deal(MAINNET_USDC, address(mockAdapter), amount);
        vm.prank(address(mockAdapter));
        IERC20(MAINNET_USDC).approve(address(escrow), amount);
        vm.prank(address(mockAdapter));
        escrow.recordDelivery(payload);
    }
}
