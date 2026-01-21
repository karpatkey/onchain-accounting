// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultOracle} from "src/balances/ERC20DefaultOracle.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

// Wrapper to make ERC20DefaultOracle work as IBalanceOracleCustom
contract ERC20DefaultOracleWrapper is IBalanceOracleCustom {
    ERC20DefaultOracle public immutable defaultOracle;
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    constructor(ERC20DefaultOracle oracle) {
        defaultOracle = oracle;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        return defaultOracle.getOracleBalanceForAsset(account, underlyingAsset);
    }

    function underlyingAssetsSupported() external view returns (address[] memory) {
        // Return empty array - the oracle supports all registered assets
        return new address[](0);
    }
}

contract BalancesHarness is Balances {
    ERC20DefaultOracle public defaultOracle;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultOracle for native address support
        defaultOracle = new ERC20DefaultOracle(address(this));
        _setErc20DefaultOracle(address(defaultOracle));
    }

    // Expose internal functions for testing
    function registerAssetForTest(address asset, uint8 decimals) public {
        _registerAsset(asset, decimals);
    }

    function setAssetSymbolForTest(address asset, string memory symbol) public {
        _setAssetSymbol(asset, symbol);
    }

    function addBalanceOracleDirect(address underlyingAsset, address oracle, IBalances.OracleType oracleType) public {
        _addBalanceOracle(underlyingAsset, oracle, oracleType);
    }

    function setBalanceOracle(address underlyingAsset, address oracle, IBalances.OracleType oracleType) public {
        _addBalanceOracle(underlyingAsset, oracle, oracleType);
    }

    function unsetBalanceOracle(address underlyingAsset, address oracle) public {
        _removeBalanceOracle(underlyingAsset, oracle);
    }
}

contract BalancesTest is Test {
    BalancesHarness public balances;
    Mock_ERC20 public usdc;
    Mock_CustomBalanceOracle public customOracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public ops = makeAddr("ops");
    address public admin = makeAddr("admin");

    function setUp() public {
        vm.startPrank(admin);
        balances = new BalancesHarness();
        // Set up native address balance oracle using a wrapper
        balances.registerAssetForTest(balances.NATIVE_ADDRESS(), 18);
        balances.setAssetSymbolForTest(balances.NATIVE_ADDRESS(), "ETH");
        ERC20DefaultOracleWrapper wrapper = new ERC20DefaultOracleWrapper(balances.defaultOracle());
        balances.addBalanceOracleDirect(balances.NATIVE_ADDRESS(), address(wrapper), IBalances.OracleType.Custom);
        usdc = new Mock_ERC20("USDC", 6);
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalance(address(usdc), alice, 123_456_789);
        customOracle.setBalance(address(usdc), bob, -987_654_321);
        address[] memory underlyingAssets = new address[](1);
        underlyingAssets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(underlyingAssets);
        customOracle.setPositionMetadata(
            IBalanceOracleCustom.PositionMetadata({
                protocol: "Mock Protocol", position: "Mock Position", positionType: "Mock Type"
            })
        );
        vm.stopPrank();
    }

    function test_setup() public view {
        uint256 count = balances.balanceOracleCountFor(balances.NATIVE_ADDRESS());
        assertEq(count, 1, "Native address should have one balance oracle");

        (address oracle,) = balances.balanceOracleAt(balances.NATIVE_ADDRESS(), 0);
        // The oracle should be the wrapper, which wraps the ERC20DefaultOracle
        assertTrue(oracle != address(0), "Native address should have a balance oracle");
    }

    function test_setAndGetERC20BalanceOracle() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);

        usdc.mint(alice, 1000);

        int256 balance = balances.balanceOf(address(usdc), 0, alice);
        assertEq(balance, 1000);
    }

    function test_setAndGetCustomBalanceOracle() public {
        balances.setBalanceOracle(address(customOracle), address(customOracle), IBalances.OracleType.Custom);

        customOracle.setBalance(address(customOracle), alice, 2000);

        int256 balance = balances.balanceOf(address(customOracle), 0, alice);
        assertEq(balance, 2000);
    }

    function test_setAndGetCustomBalanceOracleNegativeBalance() public {
        balances.setBalanceOracle(address(customOracle), address(customOracle), IBalances.OracleType.Custom);

        customOracle.setBalance(address(customOracle), alice, -2000);

        int256 balance = balances.balanceOf(address(customOracle), 0, alice);
        assertEq(balance, -2000);
    }

    function test_setBalanceOracle_nativeAddress() public {
        address nativeAddress = address(balances.NATIVE_ADDRESS());

        vm.expectRevert(IBalances.DuplicateBalanceOracle.selector);
        balances.setBalanceOracle(nativeAddress, nativeAddress, IBalances.OracleType.Native);
    }

    function test_getNativeBalance() public {
        deal(alice, 1337);
        int256 balance = balances.balanceOf(address(balances.NATIVE_ADDRESS()), 0, alice);
        assertEq(balance, 1337);
    }

    function test_unsetBalanceOracle() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
        balances.unsetBalanceOracle(address(usdc), address(usdc));

        vm.expectRevert();
        balances.balanceOf(address(usdc), 0, alice);
    }

    function test_unsetBalanceOracle_cantRemoveNativeTokenNativeBalanceOracle() public {
        address nativeAddress = balances.NATIVE_ADDRESS();
        vm.expectRevert(InvalidArguments.selector);
        balances.unsetBalanceOracle(nativeAddress, nativeAddress);
    }

    function test_checkOracleSupport_ERC20() public view {
        balances.checkBalanceOracleSupport(address(usdc), address(usdc), IBalances.OracleType.ERC20);
    }

    function test_checkOracleSupport_Custom() public view {
        balances.checkBalanceOracleSupport(address(usdc), address(customOracle), IBalances.OracleType.Custom);
    }

    function test_RevertIf_InvalidOracleZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.checkBalanceOracleSupport(address(0), address(0), IBalances.OracleType.ERC20);
    }

    function test_RevertIf_InvalidOracleERC20() public {
        vm.expectRevert();
        balances.checkBalanceOracleSupport(address(usdc), address(customOracle), IBalances.OracleType.ERC20);
    }

    function test_RevertIf_InvalidOracleCustom() public {
        vm.expectRevert();
        balances.checkBalanceOracleSupport(address(usdc), address(usdc), IBalances.OracleType.Custom);
    }

    function test_setBalanceOracle_duplicate() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);

        vm.expectRevert();
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
    }

    // Legacy metadata-based tests removed as metadata API was refactored away.
}
