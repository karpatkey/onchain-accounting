// OracleChecks.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Custom Oracle Argument Checks
/// @notice Library for checking common custom oracle constructor arguments
/// @author kpk
library OracleArgumentChecks {
    /// @notice Ensures a numeric argument is non-zero.
    /// @param number The number to validate (must be > 0).
    /// @return number The same number if valid.
    /// @dev Reverts with {InvalidArguments} if `number == 0`.
    function assertNotZeroNumber(uint256 number) internal pure returns (uint256) {
        if (number == 0) revert InvalidArguments();
        return number;
    }

    /// @notice Ensures an address argument is not the zero address.
    /// @param addr The address to validate.
    /// @return addr The same address if valid.
    /// @dev Reverts with {InvalidArguments} if `addr == address(0)`.
    function assertNonZeroAddress(address addr) internal pure returns (address) {
        if (addr == address(0)) revert InvalidArguments();
        return addr;
    }

    /// @notice Ensures an address points to a contract that behaves like an ERC-20.
    /// @param addr The token contract address to validate.
    /// @return token The same address if the contract implements `totalSupply()`.
    /// @dev Probes `IERC20.totalSupply()` via `try/catch`.
    ///      Reverts with {InvalidArguments} if `addr` is zero or the probe fails.
    function assertERC20Address(address addr) internal view returns (address token) {
        token = assertNonZeroAddress(addr);

        // Probe totalSupply()
        try IERC20(token).totalSupply() returns (uint256) {}
        catch {
            revert InvalidArguments();
        }
    }

    /// @notice Ensures an address points to a Chainlink AggregatorV3 oracle.
    /// @param addr The oracle contract address to validate.
    /// @return chainlinkOracle The typed AggregatorV3Interface at `addr`.
    /// @dev Probes `latestRoundData()` via `try/catch`.
    ///      Reverts with {InvalidArguments} if `addr` is zero,
    ///      or {NotChainlinkOracle} if the probe fails.
    function assertChainlinkOracle(address addr) internal view returns (AggregatorV3Interface chainlinkOracle) {
        chainlinkOracle = AggregatorV3Interface(assertNonZeroAddress(addr));

        // Probe latestRoundData()
        try chainlinkOracle.latestRoundData() returns (uint80, int256, uint256, uint256, uint80) {}
        catch {
            revert NotChainlinkOracle();
        }
    }
}
