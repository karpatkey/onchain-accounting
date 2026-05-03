// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {FluidVaultBalanceOracle, IFluidVaultT1, IFluidVaultResolver} from "src/balances/protocols/FluidVault.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Programmable mock of a Fluid T1 vault contract. Returns a configurable `ConstantViews`
///         from `constantsView()` so tests can stage T1 / zero-token configurations. Smart vaults
///         have a different vault contract and ConstantViews layout, so we don't model them here.
contract MockFluidVaultT1 {
    IFluidVaultT1.ConstantViews private _cv;

    function setTokens(address supplyToken_, address borrowToken_) external {
        _cv.supplyToken = supplyToken_;
        _cv.borrowToken = borrowToken_;
    }

    function constantsView() external view returns (IFluidVaultT1.ConstantViews memory) {
        return _cv;
    }
}

/// @notice Programmable mock of the Fluid VaultResolver. Stores per-user NFT lists and per-NFT
///         (vault, supply, borrow, isLiquidated) tuples. `positionByNftId` returns just the
///         `UserPosition` struct — the adapter only reads the static UserPosition prefix from the
///         staticcall return, so omitting the trailing VaultEntireData payload is sufficient
///         (the adapter's `ret.length >= 384` guard is satisfied by the 12 × 32 = 384 bytes).
contract MockFluidVaultResolver {
    struct PosData {
        address vault;
        uint256 supply;
        uint256 borrow;
        bool isLiquidated;
    }

    mapping(address => uint256[]) private _userNftIds;
    mapping(uint256 => PosData) private _posByNftId;

    function pushNft(address user, uint256 nftId, address vault, uint256 supply, uint256 borrow, bool isLiquidated)
        external
    {
        _userNftIds[user].push(nftId);
        _posByNftId[nftId] = PosData({vault: vault, supply: supply, borrow: borrow, isLiquidated: isLiquidated});
    }

    function positionsNftIdOfUser(address user) external view returns (uint256[] memory) {
        return _userNftIds[user];
    }

    function vaultByNftId(uint256 nftId) external view returns (address) {
        return _posByNftId[nftId].vault;
    }

    /// @dev Returns a UserPosition struct only. The adapter's runtime path uses staticcall +
    ///      manual decode of the first 12 words, so returning a single struct is sufficient.
    function positionByNftId(uint256 nftId) external view returns (IFluidVaultResolver.UserPosition memory pos) {
        PosData memory pd = _posByNftId[nftId];
        pos.nftId = nftId;
        pos.owner = address(0); // unused
        pos.isLiquidated = pd.isLiquidated;
        pos.supply = pd.supply;
        pos.borrow = pd.borrow;
    }
}

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title FluidVaultBalanceOracle unit tests (no fork)
contract FluidVaultBalanceOracleTest is Test {
    MockBalances mockBalances;
    MockFluidVaultResolver resolver;
    MockFluidVaultT1 vault;
    MockFluidVaultT1 otherVault;
    MockToken collateral;
    MockToken debt;
    FluidVaultBalanceOracle oracle;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        resolver = new MockFluidVaultResolver();
        vault = new MockFluidVaultT1();
        otherVault = new MockFluidVaultT1();
        collateral = new MockToken("wstETH", 18);
        debt = new MockToken("USDC", 6);

        // Configure both vaults as T1 with our mock collateral and debt tokens
        vault.setTokens(address(collateral), address(debt));
        otherVault.setTokens(address(collateral), address(debt));

        oracle = new FluidVaultBalanceOracle(
            address(vault), address(resolver), "Fluid Vault", "wstETH/USDC", address(mockBalances)
        );
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroVault() public {
        vm.expectRevert(InvalidArguments.selector);
        new FluidVaultBalanceOracle(address(0), address(resolver), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_invalidArgs_zeroResolver() public {
        vm.expectRevert(InvalidArguments.selector);
        new FluidVaultBalanceOracle(address(vault), address(0), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractVault() public {
        vm.expectRevert("Vault must be a contract");
        new FluidVaultBalanceOracle(address(0xdead), address(resolver), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractResolver() public {
        vm.expectRevert("VaultResolver must be a contract");
        new FluidVaultBalanceOracle(address(vault), address(0xdead), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new FluidVaultBalanceOracle(address(vault), address(resolver), "Fluid Vault", "x/y", address(0xdead));
    }

    function test_constructor_revertsOnZeroCollateral() public {
        MockFluidVaultT1 badVault = new MockFluidVaultT1();
        badVault.setTokens(address(0), address(debt));
        vm.expectRevert("Vault tokens must be non-zero");
        new FluidVaultBalanceOracle(address(badVault), address(resolver), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_revertsOnZeroDebt() public {
        MockFluidVaultT1 badVault = new MockFluidVaultT1();
        badVault.setTokens(address(collateral), address(0));
        vm.expectRevert("Vault tokens must be non-zero");
        new FluidVaultBalanceOracle(address(badVault), address(resolver), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_revertsOnNonContractToken() public {
        MockFluidVaultT1 badVault = new MockFluidVaultT1();
        badVault.setTokens(address(0xCAFE), address(debt));
        vm.expectRevert("supplyToken not a contract");
        new FluidVaultBalanceOracle(address(badVault), address(resolver), "Fluid Vault", "x/y", address(mockBalances));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(oracle.VAULT(), address(vault));
        assertEq(oracle.VAULT_RESOLVER(), address(resolver));
        assertEq(oracle.COLLATERAL_TOKEN(), address(collateral));
        assertEq(oracle.DEBT_TOKEN(), address(debt));
        assertEq(address(oracle.NAV_CALCULATOR()), address(mockBalances));
    }

    // ============================================
    // Interface Compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(collateral));
        assertEq(assets[1], address(debt));
    }

    // ============================================
    // getOracleBalanceForAsset
    // ============================================

    function test_getOracleBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), address(collateral));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_singlePosition_collateralAndDebt() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 12_000e6, false);

        (uint256 col, bool colIsDebt) = oracle.getOracleBalanceForAsset(alice, address(collateral));
        assertEq(col, 5e18);
        assertFalse(colIsDebt);

        (uint256 dbt, bool dbtIsDebt) = oracle.getOracleBalanceForAsset(alice, address(debt));
        assertEq(dbt, 12_000e6);
        assertTrue(dbtIsDebt);
    }

    function test_getOracleBalanceForAsset_aggregatesMultipleNftsInSameVault() public {
        resolver.pushNft(alice, 1, address(vault), 1e18, 1_000e6, false);
        resolver.pushNft(alice, 2, address(vault), 4e18, 11_000e6, false);

        (uint256 col,) = oracle.getOracleBalanceForAsset(alice, address(collateral));
        (uint256 dbt,) = oracle.getOracleBalanceForAsset(alice, address(debt));
        assertEq(col, 5e18);
        assertEq(dbt, 12_000e6);
    }

    function test_getOracleBalanceForAsset_filtersForeignVaults() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 12_000e6, false);
        resolver.pushNft(alice, 2, address(otherVault), 99e18, 999_000e6, false);

        (uint256 col,) = oracle.getOracleBalanceForAsset(alice, address(collateral));
        (uint256 dbt,) = oracle.getOracleBalanceForAsset(alice, address(debt));
        // Only positions in `vault` count
        assertEq(col, 5e18);
        assertEq(dbt, 12_000e6);
    }

    function test_getOracleBalanceForAsset_skipsLiquidatedPositions() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 12_000e6, true);

        (uint256 col,) = oracle.getOracleBalanceForAsset(alice, address(collateral));
        (uint256 dbt,) = oracle.getOracleBalanceForAsset(alice, address(debt));
        assertEq(col, 0);
        assertEq(dbt, 0);
    }

    // ============================================
    // getOracleBalances
    // ============================================

    function test_getOracleBalances_zeroAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
    }

    function test_getOracleBalances_collateralOnly() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 0, false);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(collateral));
        assertEq(amounts[0], 5e18);
        assertFalse(isDebt[0]);
    }

    function test_getOracleBalances_collateralAndDebt() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 12_000e6, false);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 2);
        // Order is dictated by underlyingAssetsSupported(): collateral, then debt
        assertEq(assets[0], address(collateral));
        assertEq(amounts[0], 5e18);
        assertFalse(isDebt[0]);
        assertEq(assets[1], address(debt));
        assertEq(amounts[1], 12_000e6);
        assertTrue(isDebt[1]);
    }

    // ============================================
    // getOraclePositions (registry-filtered)
    // ============================================

    function test_getOraclePositions_emptyWhenNoAssetsRegistered() public {
        resolver.pushNft(alice, 1, address(vault), 5e18, 12_000e6, false);
        // MockBalances default getRegisteredAssets() returns [], so intersection is empty
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
