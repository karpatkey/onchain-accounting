// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BridgeHeldBalanceAdapter} from "src/balances/BalanceAdapters/BridgeHeldBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal BridgeEscrow stand-in exposing only the destination-custody getters the adapter reads:
///         `getHeldBalanceForAsset`, `getHeldBalancesForAccount`, and `registeredAssets`. Held amounts are
///         set directly per (account, asset); this mock does not model recordDelivery/claim (covered by the
///         escrow's own tests) — it just feeds the adapter canned held balances.
contract MockHeldEscrow {
    mapping(address => mapping(address => uint256)) internal _held; // account => asset => amount
    address[] internal _assets;
    string[] internal _symbols;

    function registerAsset(string memory symbol, address asset) external {
        _symbols.push(symbol);
        _assets.push(asset);
    }

    function setHeld(address account, address asset, uint256 amount) external {
        _held[account][asset] = amount;
    }

    function getHeldBalanceForAsset(address asset, address account) external view returns (uint256) {
        return _held[account][asset];
    }

    function getHeldBalancesForAccount(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = _assets;
        amounts = new uint256[](_assets.length);
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = _held[account][_assets[i]];
        }
    }

    function registeredAssets() external view returns (string[] memory symbols, address[] memory assets) {
        return (_symbols, _assets);
    }
}

/// @title BridgeHeldBalanceAdapterTest
/// @notice Unit tests for the destination hold-then-claim NAV adapter (ADR 0024).
contract BridgeHeldBalanceAdapterTest is Test {
    Mock_NAVCalculator internal nav;
    MockHeldEscrow internal escrow;
    BridgeHeldBalanceAdapter internal adapter;

    Mock_ERC20 internal usdc;
    Mock_ERC20 internal weth;
    Mock_ERC20 internal unregistered;

    address internal account = makeAddr("account");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        escrow = new MockHeldEscrow();

        usdc = new Mock_ERC20("USDC", 6);
        weth = new Mock_ERC20("WETH", 18);
        unregistered = new Mock_ERC20("XYZ", 18);

        // Registered on NAV (priceable) — USDC + WETH. `unregistered` is held by the escrow but not on NAV.
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        // Escrow can hold custody of all three.
        escrow.registerAsset("USDC", address(usdc));
        escrow.registerAsset("WETH", address(weth));
        escrow.registerAsset("XYZ", address(unregistered));

        adapter = new BridgeHeldBalanceAdapter(address(nav), address(escrow));
    }

    // ---- constructor ----

    function test_RevertWhen_navZero() public {
        vm.expectRevert(InvalidArguments.selector);
        new BridgeHeldBalanceAdapter(address(0), address(escrow));
    }

    function test_RevertWhen_escrowZero() public {
        vm.expectRevert(InvalidArguments.selector);
        new BridgeHeldBalanceAdapter(address(nav), address(0));
    }

    function test_immutables() public view {
        assertEq(address(adapter.NAV_CALCULATOR()), address(nav));
        assertEq(address(adapter.BRIDGE_ESCROW()), address(escrow));
    }

    // ---- getAdapterPositions ----

    function test_positions_emitsOneLegPerRegisteredHeldAsset() public {
        escrow.setHeld(account, address(usdc), 1_000e6);
        escrow.setHeld(account, address(weth), 2e18);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(0));
        assertEq(p.length, 2, "two registered held legs");

        // USDC leg
        assertEq(p[0].balanceAsset.asset, address(usdc));
        assertEq(p[0].amount, 1_000e6);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertFalse(p[0].isDebt);
        assertTrue(p[0].isLocked, "held funds are locked until claim");
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied));
        assertEq(p[0].protocolBrand, ProtocolIds.BRIDGE_ESCROW);
        assertEq(p[0].protocolId, ProtocolIds.BRIDGE_ESCROW);
        assertEq(p[0].protocolSubId, ProtocolIds.BRIDGE_ESCROW);
        assertEq(p[0].positionId, abi.encode(address(escrow)));
        assertEq(p[0].positionInstanceId, bytes32(0));

        // WETH leg
        assertEq(p[1].balanceAsset.asset, address(weth));
        assertEq(p[1].amount, 2e18);
    }

    function test_positions_skipsUnregisteredHeldAsset() public {
        escrow.setHeld(account, address(usdc), 5e6);
        escrow.setHeld(account, address(unregistered), 9e18); // held but not on NAV

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(0));
        assertEq(p.length, 1, "unregistered held asset is skipped");
        assertEq(p[0].balanceAsset.asset, address(usdc));
    }

    function test_positions_skipsZeroAmounts() public {
        escrow.setHeld(account, address(usdc), 0);
        escrow.setHeld(account, address(weth), 3e18);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(weth));
    }

    function test_positions_assetFilter() public {
        escrow.setHeld(account, address(usdc), 1e6);
        escrow.setHeld(account, address(weth), 1e18);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(weth));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(weth));
    }

    function test_positions_emptyForZeroAccount() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(address(0), address(0));
        assertEq(p.length, 0);
    }

    function test_positions_emptyWhenNothingHeld() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(0));
        assertEq(p.length, 0);
    }

    // ---- getAdapterBalanceForAsset / getAdapterBalances ----

    function test_getAdapterBalanceForAsset() public {
        escrow.setHeld(account, address(usdc), 42e6);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(account, address(usdc));
        assertEq(amount, 42e6);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroInputs() public view {
        (uint256 a1,) = adapter.getAdapterBalanceForAsset(address(0), address(usdc));
        (uint256 a2,) = adapter.getAdapterBalanceForAsset(account, address(0));
        assertEq(a1, 0);
        assertEq(a2, 0);
    }

    function test_getAdapterBalances() public {
        escrow.setHeld(account, address(usdc), 7e6);
        escrow.setHeld(account, address(weth), 8e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(account);
        assertEq(assets.length, 3, "mirrors escrow registered set");
        assertEq(amounts[0], 7e6);
        assertEq(amounts[1], 8e18);
        for (uint256 i; i < isDebt.length; ++i) {
            assertFalse(isDebt[i]);
        }
    }

    function test_getAdapterBalances_emptyForZeroAccount() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
    }

    // ---- misc surface ----

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 3);
        assertEq(a[0], address(usdc));
        assertEq(a[1], address(weth));
        assertEq(a[2], address(unregistered));
    }

    function test_describable() public view {
        assertEq(adapter.protocolName(), "Bridge Escrow");
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 1);
        assertEq(labels[0], "Held (pending claim)");
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
    }
}
