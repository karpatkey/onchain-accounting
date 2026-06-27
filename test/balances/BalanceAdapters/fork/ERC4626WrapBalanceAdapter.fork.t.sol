// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {ERC4626WrapBalanceAdapter} from "src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ERC4626WrapBalanceAdapter fork tests — Nexus Mutual RWI Vault (RWIV), real holder (pinned)
/// @notice RWIV is a USDC-denominated ERC-4626 vault (decimals 6) held by the Nexus Mutual Safe (~$250k).
///         Pins the real holder at a fixed block and asserts the adapter reports the holder's exact USDC value.
///         Also asserts `previewRedeem(shares) == convertToAssets(shares)` at the block — i.e. no exit
///         fee/cooldown makes `convertToAssets` over-report.
///         Values captured on-chain at block 25_373_262: balanceOf(HOLDER) = 246_340_586_538 RWIV shares;
///         convertToAssets(shares) = previewRedeem(shares) = 250_228_292_317 USDC (6-dec).
contract ERC4626WrapBalanceAdapterForkTest_RWIV_RealHolder is BalanceAdapterTestBase {
    // Nexus Mutual RWI Vault (RWIV) and its underlying asset (USDC)
    IERC4626 public constant RWIV = IERC4626(0xcAFeAA466736ac01e0AC9Ca72644beF348694731);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 public constant FORK_BLOCK = 25_373_262;
    address public constant HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe
    uint256 public constant EXPECTED_SHARES = 246_340_586_538;
    uint256 public constant EXPECTED_USDC = 250_228_292_317;

    ERC4626WrapBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp(); // dispatches to this contract's _setupFork() override
        _setupAdapter();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupAdapter() internal {
        balances = _deployBalancesForAdapter(address(USDC));
        adapter = new ERC4626WrapBalanceAdapter(address(RWIV), address(balances));
    }

    function test_assetIsUsdc() public view {
        assertEq(RWIV.asset(), address(USDC), "RWIV underlying must be USDC");
        assertEq(adapter.ASSET(), address(USDC));
        assertEq(address(adapter.WRAPPER()), address(RWIV));
    }

    /// @notice Confirms the fork is pinned where the holder has the expected share balance.
    function test_realHolder_sharesAtBlock() public view {
        assertEq(RWIV.balanceOf(HOLDER), EXPECTED_SHARES, "holder RWIV shares at pinned block");
    }

    /// @notice convertToAssets and previewRedeem agree exactly at the pin — no exit fee/cooldown skew — and the
    ///         holder's full balance is redeemable (`maxRedeem == balanceOf`), so no exit constraint makes
    ///         `convertToAssets` over-report the realizable value.
    function test_realHolder_convertToAssets_equalsPreviewRedeem() public view {
        assertEq(RWIV.convertToAssets(EXPECTED_SHARES), EXPECTED_USDC, "convertToAssets at pinned block");
        assertEq(RWIV.previewRedeem(EXPECTED_SHARES), EXPECTED_USDC, "previewRedeem must equal convertToAssets");
        assertEq(RWIV.maxRedeem(HOLDER), EXPECTED_SHARES, "maxRedeem == full balance (no exit constraint)");
    }

    /// @notice The adapter must report the holder's position as exactly the convertToAssets USDC value.
    function test_realHolder_adapterReportsExactUsdc() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, address(USDC));
        assertEq(amount, EXPECTED_USDC, "adapter must report the holder's exact USDC value");
        assertFalse(isDebt, "vault supply is always credit");
    }

    function test_realHolder_positions() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(HOLDER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(USDC));
        assertEq(positions[0].amount, EXPECTED_USDC);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ERC4626);
        assertEq(positions[0].positionId, abi.encode(address(RWIV)));
        assertTrue(positions[0].positionKind == PositionKind.Supplied);
    }

    function test_realHolder_balances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(HOLDER);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDC));
        assertEq(amounts[0], EXPECTED_USDC);
        assertFalse(isDebt[0]);
    }
}
