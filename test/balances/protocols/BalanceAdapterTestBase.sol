// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {IBalances} from "src/balances/IBalances.sol";

/// @title BalanceAdapterTestBase
/// @notice Base test contract for unit/implementation balance adapter tests
/// @dev Provides common setup for unit tests without forks (uses mocks)
abstract contract BalanceAdapterTestBase is Test {
    // Balances contract for unit tests
    BalancesHarness public balances;

    // Common test tokens
    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_ERC20 public weth;

    // Test accounts
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public admin = makeAddr("admin");

    function setUp() public virtual {
        _setupBalances();
        _setupTokens();
    }

    /// @notice Sets up the Balances contract
    function _setupBalances() internal {
        balances = new BalancesHarness();
    }

    /// @notice Sets up common test tokens
    function _setupTokens() internal {
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);

        // Register tokens in Balances
        balances.registerAssetForTest(address(usdc), 6);
        balances.registerAssetForTest(address(dai), 18);
        balances.registerAssetForTest(address(weth), 18);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        balances.setAssetSymbolForTest(address(dai), "DAI");
        balances.setAssetSymbolForTest(address(weth), "WETH");
    }

    /// @notice Creates and registers a new test token
    /// @param name Token name
    /// @param decimals Token decimals
    /// @return token The created token
    function _createAndRegisterToken(string memory name, uint8 decimals) internal returns (Mock_ERC20 token) {
        token = new Mock_ERC20(name, decimals);
        balances.registerAssetForTest(address(token), decimals);
        balances.setAssetSymbolForTest(address(token), name);
        return token;
    }
}
