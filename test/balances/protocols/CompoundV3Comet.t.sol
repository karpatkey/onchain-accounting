// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Rewards mock that returns no reward config — `_rewardOwed` short-circuits to 0.
contract MockCompoundRewardsMinimal {
    function rewardConfig(address) external pure returns (address token, uint64 rescaleFactor, bool shouldUpscale) {
        return (address(0), 0, false);
    }

    function rewardsClaimed(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Rewards mock with a valid reward config so `_rewardOwed` follows the accrual path.
///         `accrued − claimed` is exposed via `setClaimed`. With `rescaleFactor=1, shouldUpscale=false`
///         and a `baseTrackingIndex == trackingSupplyIndex` configuration in the Comet mock, the
///         accrual formula collapses to `baseTrackingAccrued − claimed`.
contract MockCompoundRewardsConfigurable {
    address public token;
    uint64 public rescaleFactor;
    bool public shouldUpscale;
    mapping(address comet => mapping(address user => uint256)) public claimed;

    constructor(address token_) {
        token = token_;
        rescaleFactor = 1;
        shouldUpscale = false;
    }

    function rewardConfig(address) external view returns (address, uint64, bool) {
        return (token, rescaleFactor, shouldUpscale);
    }

    function rewardsClaimed(address comet, address src) external view returns (uint256) {
        return claimed[comet][src];
    }

    function setClaimed(address comet, address src, uint256 amount) external {
        claimed[comet][src] = amount;
    }
}

/// @notice Comet mock with no collaterals — minimal surface for base-token-only tests.
contract MockCometMinimal {
    address private _baseToken;
    uint64 public constant MOCK_BASE_INDEX = 1e15;

    constructor(address baseToken_) {
        _baseToken = baseToken_;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function numAssets() external pure returns (uint8) {
        return 0;
    }

    function getAssetInfo(uint8)
        external
        pure
        returns (uint8, address, address, uint64, uint64, uint64, uint64, uint128)
    {
        revert("unused in unit test");
    }

    function userBasic(address) external pure returns (int104, uint64, uint64, uint16, uint8) {
        return (0, 0, 0, 0, 0);
    }

    function collateralBalanceOf(address, address) external pure returns (uint256) {
        return 0;
    }

    function totalsBasic() external view returns (uint64, uint64, uint64, uint64, uint104, uint104, uint40, uint8) {
        return (MOCK_BASE_INDEX, MOCK_BASE_INDEX, 1, 1, 0, 0, uint40(block.timestamp), 0);
    }

    function baseScale() external pure returns (uint256) {
        return 1e6;
    }

    function baseMinForRewards() external pure returns (uint256) {
        return 1;
    }

    function baseTrackingSupplySpeed() external pure returns (uint256) {
        return 0;
    }

    function baseTrackingBorrowSpeed() external pure returns (uint256) {
        return 0;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function getBorrowRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function trackingIndexScale() external pure returns (uint256) {
        return 1e15;
    }
}

/// @notice Comet mock with a configurable collateral list. Used for multi-collateral + COMP-overlap tests.
///         Indices are static (no accrual), so reward math reduces to `baseTrackingAccrued`.
contract MockCometRich {
    address private _baseToken;
    address[] private _assets;
    mapping(address user => int104) public principalOf;
    mapping(address user => uint64) public baseTrackingAccruedOf;
    mapping(address user => mapping(address asset => uint256)) public collateralFor;

    uint64 public constant MOCK_BASE_INDEX = 1e15;
    uint64 public constant MOCK_TRACK_INDEX = 1;

    constructor(address baseToken_, address[] memory assets_) {
        _baseToken = baseToken_;
        _assets = assets_;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function numAssets() external view returns (uint8) {
        return uint8(_assets.length);
    }

    function getAssetInfo(uint8 i)
        external
        view
        returns (uint8, address, address, uint64, uint64, uint64, uint64, uint128)
    {
        return (i, _assets[i], address(0), 1e18, 0, 0, 0, 0);
    }

    function userBasic(address user) external view returns (int104, uint64, uint64, uint16, uint8) {
        // baseTrackingIndex == trackingSupplyIndex, so `_updateTrackingAccrued` collapses to baseTrackingAccrued.
        return (principalOf[user], MOCK_TRACK_INDEX, baseTrackingAccruedOf[user], 0, 0);
    }

    function collateralBalanceOf(address user, address asset) external view returns (uint256) {
        return collateralFor[user][asset];
    }

    function totalsBasic() external view returns (uint64, uint64, uint64, uint64, uint104, uint104, uint40, uint8) {
        return (MOCK_BASE_INDEX, MOCK_BASE_INDEX, MOCK_TRACK_INDEX, MOCK_TRACK_INDEX, 0, 0, uint40(block.timestamp), 0);
    }

    function baseScale() external pure returns (uint256) {
        return 1e6;
    }

    function baseMinForRewards() external pure returns (uint256) {
        return 1;
    }

    function baseTrackingSupplySpeed() external pure returns (uint256) {
        return 0;
    }

    function baseTrackingBorrowSpeed() external pure returns (uint256) {
        return 0;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function getBorrowRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function trackingIndexScale() external pure returns (uint256) {
        return 1e15;
    }

    function setPrincipal(address user, int104 amount) external {
        principalOf[user] = amount;
    }

    function setBaseTrackingAccrued(address user, uint64 amount) external {
        baseTrackingAccruedOf[user] = amount;
    }

    function setCollateral(address user, address asset, uint256 amount) external {
        collateralFor[user][asset] = amount;
    }
}

/// @title CompoundV3Comet unit tests
/// @notice Pure unit tests with mocks. Reward math is exercised end-to-end in fork tests.
contract CompoundV3CometTest is BalanceAdapterTestBase {
    CompoundV3Comet public oracle;
    MockCompoundRewardsMinimal public mockRewards;
    MockCometMinimal public mockComet;
    MockContract public mockRewardToken;

    function setUp() public override {
        super.setUp();
        mockRewards = new MockCompoundRewardsMinimal();
        mockComet = new MockCometMinimal(address(usdc));
        mockRewardToken = new MockContract();
        oracle = new CompoundV3Comet(address(mockRewards), address(mockComet), address(mockRewardToken), address(balances));
    }

    // ============ Constructor ============

    function test_constructor_revertsOnZeroCompoundRewards() public {
        vm.expectRevert(InvalidArguments.selector);
        new CompoundV3Comet(address(0), address(mockComet), address(mockRewardToken), address(balances));
    }

    function test_constructor_revertsOnZeroComet() public {
        vm.expectRevert(InvalidArguments.selector);
        new CompoundV3Comet(address(mockRewards), address(0), address(mockRewardToken), address(balances));
    }

    function test_constructor_revertsOnZeroRewardToken() public {
        vm.expectRevert(InvalidArguments.selector);
        new CompoundV3Comet(address(mockRewards), address(mockComet), address(0), address(balances));
    }

    function test_constructor_pinsBaseTokenFromComet() public view {
        assertEq(oracle.BASE_TOKEN(), address(usdc));
        assertEq(oracle.COMET(), address(mockComet));
        assertEq(address(oracle.REWARD_TOKEN()), address(mockRewardToken));
        assertEq(address(oracle.COMPOUND_REWARDS()), address(mockRewards));
    }

    // ============ ERC165 ============

    function test_supportsInterface_yes() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_no() public view {
        assertFalse(oracle.supportsInterface(0xdeadbeef));
    }

    // ============ underlyingAssetsSupported ============

    function test_underlyingAssetsSupported_includesBaseAndReward_noCollaterals() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(mockRewardToken));
    }

    function test_underlyingAssetsSupported_dedupesRewardWhenAlsoCollateral() public {
        // Register a Comet mock where COMP (reward token) is ALSO a collateral.
        address[] memory cols = new address[](2);
        cols[0] = address(weth);
        cols[1] = address(mockRewardToken); // dup with reward token
        MockCometRich rich = new MockCometRich(address(usdc), cols);

        CompoundV3Comet o = new CompoundV3Comet(address(mockRewards), address(rich), address(mockRewardToken), address(balances));

        address[] memory assets = o.underlyingAssetsSupported();
        // Expected: [USDC, WETH, COMP] — COMP appears once even though it's listed as both collateral and reward.
        assertEq(assets.length, 3);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
        assertEq(assets[2], address(mockRewardToken));
    }

    // ============ getOracleBalanceForAsset — base ============

    function test_getOracleBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unsupportedToken() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(0x1234));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_baseSupply_positivePrincipal() public {
        int104 supply = type(int104).max;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, alice),
            abi.encode(supply, 0, 0, 0, 0)
        );
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertGt(amount, 0);
        assertFalse(isDebt, "supply -> credit");
    }

    function test_getOracleBalanceForAsset_baseBorrow_negativePrincipal() public {
        int104 borrow = type(int104).min;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, alice),
            abi.encode(borrow, 0, 0, 0, 0)
        );
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertGt(amount, 0);
        assertTrue(isDebt, "borrow -> debt");
    }

    function test_getOracleBalanceForAsset_baseZero() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    // ============ getOracleBalances ============

    function test_getOracleBalances_zeroAccount() public view {
        (address[] memory a, uint256[] memory b, bool[] memory c) = oracle.getOracleBalances(address(0));
        assertEq(a.length, 0);
        assertEq(b.length, 0);
        assertEq(c.length, 0);
    }

    function test_getOracleBalances_emptyForAccountWithoutPosition() public view {
        (address[] memory a, uint256[] memory b, bool[] memory c) = oracle.getOracleBalances(alice);
        assertEq(a.length, 0);
        assertEq(b.length, 0);
        assertEq(c.length, 0);
    }

    // ============ Multi-collateral + COMP overlap ============

    function _setupRichOracle()
        internal
        returns (CompoundV3Comet o, MockCometRich rich, MockCompoundRewardsConfigurable r)
    {
        // COMP appears as collateral AND as reward token (same shape as Mainnet cUSDCv3).
        address[] memory cols = new address[](2);
        cols[0] = address(weth);
        cols[1] = address(mockRewardToken);
        rich = new MockCometRich(address(usdc), cols);
        r = new MockCompoundRewardsConfigurable(address(mockRewardToken));
        o = new CompoundV3Comet(address(r), address(rich), address(mockRewardToken), address(balances));
    }

    function test_getOracleBalanceForAsset_collateralOnly() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        rich.setCollateral(alice, address(weth), 7 ether);

        (uint256 amount, bool isDebt) = o.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 7 ether);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_compAsCollateralAndReward_sumsBoth() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        // 100 COMP collateral
        rich.setCollateral(alice, address(mockRewardToken), 100);
        // 25 COMP unclaimed rewards (claimed=0, baseTrackingAccrued=25 with the index collapse).
        rich.setBaseTrackingAccrued(alice, 25);

        (uint256 amount, bool isDebt) = o.getOracleBalanceForAsset(alice, address(mockRewardToken));
        assertEq(amount, 125, "expected sum of collateral (100) + reward (25)");
        assertFalse(isDebt);
    }

    function test_getOraclePositions_compAsCollateralAndReward_emitsTwoLegs() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        // Register the reward token so positions for it survive the registry filter.
        balances.addSupportedAssetForTest(address(mockRewardToken));
        rich.setCollateral(alice, address(mockRewardToken), 100);
        rich.setBaseTrackingAccrued(alice, 25);

        INAVCalculator.PositionBalance[] memory positions = o.getOraclePositions(alice, address(0));

        // Expect: 1 collateral leg + 1 reward leg for COMP. No base/USDC leg (alice has no USDC position).
        assertEq(positions.length, 2);

        bool sawCollateral;
        bool sawReward;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(mockRewardToken));
            assertEq(positions[i].balanceOracle, address(o));
            assertFalse(positions[i].isDebt);
            if (positions[i].positionKind == PositionKind.Collateral) {
                assertEq(positions[i].amount, 100);
                sawCollateral = true;
            } else if (positions[i].positionKind == PositionKind.Earned) {
                assertEq(positions[i].amount, 25);
                sawReward = true;
            }
        }
        assertTrue(sawCollateral, "missing collateral leg");
        assertTrue(sawReward, "missing reward leg");
    }

    function test_getOraclePositions_filtersUnregisteredAssets() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        rich.setCollateral(alice, address(weth), 5 ether);
        rich.setCollateral(alice, address(mockRewardToken), 100);

        // mockRewardToken is NOT in `balances` registered list — only usdc/dai/weth (from setUp).
        // Drop reward leg too so the test is unambiguous.
        INAVCalculator.PositionBalance[] memory positions = o.getOraclePositions(alice, address(0));

        // Only WETH collateral remains; mockRewardToken (unregistered) is filtered out.
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertEq(uint256(positions[0].positionKind), uint256(PositionKind.Collateral));
        assertEq(positions[0].amount, 5 ether);
    }

    function test_getOraclePositions_assetFilter() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        rich.setCollateral(alice, address(weth), 5 ether);

        // Filter for USDC only — alice has no USDC position, so result is empty.
        INAVCalculator.PositionBalance[] memory positions = o.getOraclePositions(alice, address(usdc));
        assertEq(positions.length, 0);

        // Filter for WETH — only the WETH collateral leg.
        positions = o.getOraclePositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(weth));
    }

    function test_getOraclePositions_baseSupplyEmitsSupplyDetail() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        rich.setPrincipal(alice, type(int104).max);

        INAVCalculator.PositionBalance[] memory positions = o.getOraclePositions(alice, address(usdc));
        assertEq(positions.length, 1);
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(positions[0].isDebt);
    }

    function test_getOraclePositions_baseBorrowEmitsBorrowDetail() public {
        (CompoundV3Comet o, MockCometRich rich,) = _setupRichOracle();
        rich.setPrincipal(alice, type(int104).min);

        INAVCalculator.PositionBalance[] memory positions = o.getOraclePositions(alice, address(usdc));
        assertEq(positions.length, 1);
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Borrowed));
        assertTrue(positions[0].isDebt);
    }

    function test_getOraclePositions_zeroAccount() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }
}
