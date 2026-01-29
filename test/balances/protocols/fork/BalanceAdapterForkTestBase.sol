// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title BalanceAdapterForkTestBase
/// @notice Base test contract for fork-based balance adapter tests
/// @dev Provides fork setup, real contract addresses, and helper functions for testing with real protocol contracts
abstract contract BalanceAdapterForkTestBase is TestEnvConfigurator, TestSetupHelpers {
    // Fork ID
    uint256 public fork;

    // Balances contract for fork tests
    BalancesHarnessForFork public balances;

    // Common mainnet token addresses
    address public constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant MAINNET_AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    // Fork block number (can be overridden by child contracts)
    // Default block is recent and stable for most tests
    uint256 public constant DEFAULT_FORK_BLOCK = 20_576_908;

    function setUp() public virtual {
        _setupFork();
    }

    /// @notice Sets up the fork
    /// @dev Can be overridden by child contracts to customize fork block
    function _setupFork() internal virtual {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), DEFAULT_FORK_BLOCK);
    }

    /// @notice Deploys and configures Balances contract for fork tests
    /// @param assets Array of asset addresses to register
    /// @return balancesInstance The deployed Balances contract with assets registered
    function _deployBalancesForOracle(address[] memory assets) internal returns (BalancesHarnessForFork) {
        return deployBalancesInFork(assets);
    }

    /// @notice Deploys and configures Balances contract for a single asset
    /// @param asset The asset address to register
    /// @return balancesInstance The deployed Balances contract with the asset registered
    function _deployBalancesForOracle(address asset) internal returns (BalancesHarnessForFork) {
        return deployBalancesInFork(asset);
    }

    /// @notice Gets asset decimals, with fallback to 18
    /// @param asset The asset address
    /// @return decimals The asset decimals
    function _getAssetDecimals(address asset) internal view returns (uint8 decimals) {
        try IERC20Metadata(asset).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18; // Default fallback
        }
    }

    /// @notice Gets asset symbol, with fallback to empty string
    /// @param asset The asset address
    /// @return symbol The asset symbol (handles bytes32 and string-returning symbol(), e.g. MKR)
    function _getAssetSymbol(address asset) internal view returns (string memory symbol) {
        return _safeTokenSymbol(asset);
    }
}
