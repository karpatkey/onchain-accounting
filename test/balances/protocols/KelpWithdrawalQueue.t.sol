// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "src/balances/protocols/KelpWithdrawalQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Kelp's LRTConfig — only exposes the supported-asset registry.
contract MockLRTConfig {
    address[] private _assets;

    function setSupportedAssetList(address[] memory assets) external {
        _assets = assets;
    }

    function getSupportedAssetList() external view returns (address[] memory) {
        return _assets;
    }
}

/// @notice Minimal mock of Kelp's LRTWithdrawalManager.
/// @dev Models the per-(asset, user) deque of open requests as an array plus a `begin` cursor, so
///      `userAssociatedNonces` returns `(begin, length)` and `getUserWithdrawalRequest(.., i)` reads
///      the i-th *live* request (`data[begin + i]`) — exactly like the real `DoubleEndedQueue.at(i)`.
contract MockLRTWithdrawalManager {
    address public lrtConfig;

    mapping(address => mapping(address => uint256[])) private _expected; // asset => user => expectedAssetAmounts
    mapping(address => mapping(address => uint128)) private _begin; // asset => user => front cursor

    constructor(address lrtConfig_) {
        lrtConfig = lrtConfig_;
    }

    function pushRequest(address asset, address user, uint256 expectedAssetAmount) external {
        _expected[asset][user].push(expectedAssetAmount);
    }

    /// @notice Simulate claiming the front-most open request (deque pop-front).
    function claimFront(address asset, address user) external {
        _begin[asset][user] += 1;
    }

    function userAssociatedNonces(address asset, address user) external view returns (uint128 begin, uint128 end) {
        begin = _begin[asset][user];
        end = uint128(_expected[asset][user].length);
    }

    function getUserWithdrawalRequest(address asset, address user, uint256 userIndex)
        external
        view
        returns (uint256 rsETHAmount, uint256 expectedAssetAmount, uint256 withdrawalStartBlock, uint256 userNonce)
    {
        uint256 absolute = _begin[asset][user] + userIndex;
        return (0, _expected[asset][user][absolute], 0, absolute);
    }
}

/// @title KelpWithdrawalQueueBalanceAdapter unit tests
contract KelpWithdrawalQueueBalanceAdapterTest is BalanceAdapterTestBase {
    string internal constant POSITION_DETAIL_BASE =
        "{\"protocol\":\"Kelp\",\"product\":\"Staking\",\"name\":\"rsETH Withdrawal Queue\"";
    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Kelp\",\"product\":\"Staking\",\"name\":\"rsETH Withdrawal Queue\",\"type\":\"Staking\"}";

    KelpWithdrawalQueueBalanceAdapter public adapter;
    MockLRTWithdrawalManager public manager;
    MockLRTConfig public config;

    // A second registered LST asset (stand-in for stETH) plus an unregistered queue asset.
    Mock_ERC20 public steth;
    Mock_ERC20 public unregistered;

    function setUp() public override {
        super.setUp();

        steth = _createAndRegisterToken("stETH", 18);
        // `unregistered` is supported by the Kelp queue but NOT registered in NAV.
        unregistered = new Mock_ERC20("ETHx", 18);

        config = new MockLRTConfig();
        address[] memory supported = new address[](3);
        supported[0] = address(weth);
        supported[1] = address(steth);
        supported[2] = address(unregistered);
        config.setSupportedAssetList(supported);

        manager = new MockLRTWithdrawalManager(address(config));
        adapter = new KelpWithdrawalQueueBalanceAdapter(address(manager), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new KelpWithdrawalQueueBalanceAdapter(address(0), address(balances));
    }

    function test_constructor_revertsWhenManagerNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("WithdrawalManager must be a contract"));
        new KelpWithdrawalQueueBalanceAdapter(eoa, address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("NAVCalculator must be a contract"));
        new KelpWithdrawalQueueBalanceAdapter(address(manager), eoa);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(steth));
        assertEq(assets[2], address(unregistered));
    }

    // ---- getAdapterBalanceForAsset ----

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_singleOpenRequest() public {
        manager.pushRequest(address(steth), alice, 1.05e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(steth));
        assertEq(amount, 1.05e18);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_multipleRequestsSummed() public {
        manager.pushRequest(address(steth), alice, 1.05e18);
        manager.pushRequest(address(steth), alice, 2.1e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(steth));
        assertEq(amount, 3.15e18);
    }

    function test_getAdapterBalanceForAsset_capsAtMaxRequestsProbed() public {
        // A pathological account with more open requests than the cap must not iterate unbounded:
        // the adapter sums only the first MAX_REQUESTS_PROBED and never reverts/OOGs.
        uint256 cap = adapter.MAX_REQUESTS_PROBED();
        for (uint256 i = 0; i < cap + 5; i++) {
            manager.pushRequest(address(steth), alice, 1e18);
        }
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(steth));
        assertEq(amount, cap * 1e18, "Should sum exactly MAX_REQUESTS_PROBED requests");
    }

    function test_getAdapterBalanceForAsset_skipsClaimedFront() public {
        manager.pushRequest(address(steth), alice, 1e18);
        manager.pushRequest(address(steth), alice, 2e18);
        manager.claimFront(address(steth), alice); // first request claimed

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(steth));
        assertEq(amount, 2e18, "Claimed front request must be excluded");
    }

    // ---- getAdapterBalances ----

    function test_getAdapterBalances_zeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterBalances_emptyForAccountWithNoRequests() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_multipleAssets() public {
        manager.pushRequest(address(weth), alice, 4e18);
        manager.pushRequest(address(steth), alice, 5e18);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 4e18);
        assertEq(assets[1], address(steth));
        assertEq(amounts[1], 5e18);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    // ---- getAdapterPositions ----

    function test_getAdapterPositions_zeroAccount() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_multipleAssets() public {
        manager.pushRequest(address(weth), alice, 4e18);
        manager.pushRequest(address(steth), alice, 5e18);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 2);

        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertEq(positions[0].amount, 4e18);
        assertEq(positions[1].balanceAsset.asset, address(steth));
        assertEq(positions[1].amount, 5e18);

        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAdapter, address(adapter));
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].positionId, "");
        }
    }

    function test_getAdapterPositions_dropsUnregisteredAsset() public {
        // A request exists on an asset Kelp supports but NAV does not register → excluded from positions,
        // even though the raw owed amount is still readable via getAdapterBalanceForAsset.
        manager.pushRequest(address(unregistered), alice, 9e18);

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(unregistered));
        assertEq(amount, 9e18, "raw owed is still reported per-asset");

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying must not produce a position");
    }

    function test_getAdapterPositions_filtersByAsset() public {
        manager.pushRequest(address(weth), alice, 4e18);
        manager.pushRequest(address(steth), alice, 5e18);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter on a non-queue asset yields empty");

        positions = adapter.getAdapterPositions(alice, address(steth));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(steth));
        assertEq(positions[0].amount, 5e18);
    }
}
