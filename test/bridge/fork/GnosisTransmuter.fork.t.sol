// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSDCTransmuter} from "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";

/// @title GnosisTransmuterForkTest
/// @notice Validates the REAL Gnosis USDCTransmuter against IUSDCTransmuter, so the mock used in the
///         GnosisBridgeAdapter unit tests faithfully mirrors on-chain behaviour: both swap directions are 1:1
///         with no fee, and the token identities are exactly the legacy `USD//C on xDai` and Circle's USDC.e.
/// @dev Fork test (test/**/fork). Run with FOUNDRY_PROFILE=slow. Skips gracefully if ALCHEMY_API_KEY is unset.
contract GnosisTransmuterForkTest is Test {
    IUSDCTransmuter internal constant TRANSMUTER = IUSDCTransmuter(0x0392A2F5Ac47388945D8c84212469F545fAE52B2);
    address internal constant LEGACY = 0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83; // USD//C on xDai
    address internal constant USDCE = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0; // Bridged USDC.e (Gnosis)
    uint256 internal constant FORK_BLOCK = 47_300_000;

    bool internal forked;

    function setUp() public {
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length == 0) return;
        vm.createSelectFork(string.concat("https://gnosis-mainnet.g.alchemy.com/v2/", key), FORK_BLOCK);
        forked = true;
    }

    /// @notice The transmuter's token identities match what the adapter/config assume.
    function testFork_transmuter_tokenIdentities() public view {
        if (!forked) return;
        assertEq(TRANSMUTER.USDC_ON_XDAI(), LEGACY, "legacy token identity");
        assertEq(TRANSMUTER.USDC_E(), USDCE, "USDC.e token identity");
        assertTrue(TRANSMUTER.isEnabled(), "transmuter enabled at fork block");
    }

    /// @notice deposit(): legacy -> USDC.e is 1:1 (mints), and withdraw(): USDC.e -> legacy is 1:1 (from reserve).
    function testFork_transmuter_roundTrip_isOneToOne() public {
        if (!forked) return;
        uint256 amount = 1000e6;

        deal(LEGACY, address(this), amount);
        uint256 usdceBefore = IERC20(USDCE).balanceOf(address(this));

        // legacy -> USDC.e
        IERC20(LEGACY).approve(address(TRANSMUTER), amount);
        TRANSMUTER.deposit(amount);
        assertEq(IERC20(USDCE).balanceOf(address(this)) - usdceBefore, amount, "deposit mints USDC.e 1:1");
        assertEq(IERC20(LEGACY).balanceOf(address(this)), 0, "deposit consumed the legacy input");

        // USDC.e -> legacy (from the transmuter's reserve)
        IERC20(USDCE).approve(address(TRANSMUTER), amount);
        TRANSMUTER.withdraw(amount);
        assertEq(IERC20(LEGACY).balanceOf(address(this)), amount, "withdraw returns legacy 1:1");
        assertEq(IERC20(USDCE).balanceOf(address(this)), usdceBefore, "withdraw consumed the USDC.e input");
    }
}
