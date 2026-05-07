// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PancakeSwapV2BalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV2.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal V2 pair stub — exposes only the four views the parent constructor reads.
contract MockV2Pair {
    address public token0;
    address public token1;
    address public factory;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
    }
}

/// @notice ERC20-ish stub so `address.code.length > 0` checks pass.
contract MockToken {}

/// @notice Wrapper-level tests for `PancakeSwapV2BalanceOracle`.
/// @dev `UniswapV2BalanceOracle` already has full unit coverage on main. The wrapper inherits
///      every behaviour unchanged (no overrides), so this suite only validates that the wrapper
///      constructs the parent correctly and exposes the same ERC165 interface support — mirroring
///      the existing pattern for `SparkLendBalanceOracle` (which is the same kind of pure-rename
///      subclass over `AaveV3InstanceBalanceOracle`).
contract PancakeSwapV2BalanceOracleTest is Test {
    MockBalances mockBalances;
    MockV2Pair mockPair;
    PancakeSwapV2BalanceOracle oracle;

    function setUp() public {
        mockBalances = new MockBalances();
        address factory = address(new MockToken()); // any contract address works
        mockPair = new MockV2Pair(address(new MockToken()), address(new MockToken()), factory);
        oracle = new PancakeSwapV2BalanceOracle(
            address(mockPair),
            "PancakeSwap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_constructor_storesImmutables() public view {
        assertEq(oracle.PAIR(), address(mockPair));
        assertEq(oracle.TOKEN0(), mockPair.token0());
        assertEq(oracle.TOKEN1(), mockPair.token1());
        assertEq(oracle.FACTORY(), mockPair.factory());
        assertEq(address(oracle.NAV_CALCULATOR()), address(mockBalances));
    }

    function test_constructor_invalidArgs_zeroPair() public {
        vm.expectRevert(InvalidArguments.selector);
        new PancakeSwapV2BalanceOracle(
            address(0),
            "PancakeSwap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}
