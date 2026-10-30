// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

interface IAssetKindRegistryRemoval {
    function unregisterAsset(address asset) external;
    function getAssetLabels(address asset) external view returns (string[] memory);
    function isClassified(address asset) external view returns (bool);
    function NAV() external view returns (address);
}

/// @title AssetRemovalForkTest
/// @notice The ezETH (mainnet + Arbitrum) and EIGEN (mainnet) removal in the ADR 0029 rollout batch (issue #357), run
///         on the LIVE NAV with the LIVE implementation, as the Council Safe, in the batch's order:
///         `removeBalanceAdapters([RenzoRestakedEthWalletMeta])` → `AssetKindRegistry.unregisterAsset(ezETH)` →
///         `AssetKindRegistry.unregisterAsset(EIGEN)`.
/// @dev Pins that the calls succeed for the Council (it holds MANAGER; the registry forwards to the NAV and holds
///      MANAGER itself), that they leave no feed, monitor, label, adapter or claim behind, and that a production
///      account's NAV does not move while the staging Safe that held dust ezETH loses only that leg. The Renzo
///      adapter must go first: it is the claimant of the ezETH coordinate, and removing it releases the claim.
contract AssetRemovalForkTest is TestEnvConfigurator {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant COUNCIL = 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537;
    address constant AKR = 0xf60467a88C2b4d0f46C0c41C3Ba0C74da3d3CCD0;
    address constant RENZO_ADAPTER = 0x9145A559108426e1eA429A2A6441e2A875f069ec;

    address constant EZETH_1 = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
    address constant EIGEN = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;
    address constant EZETH_42161 = 0x2416092f143378750bb29b79eD961ab195CcEea5;

    /// @dev USD Alpha fund Safe: a production account with a non-zero NAV and no ezETH or EIGEN.
    address constant PRODUCTION_1 = 0x38F6a1B46144fAEe6a6D9F79D8dE264C18e23848;
    /// @dev ETH Alpha staging Safe: holds 0.005 ezETH as Aave V3 collateral (integration ACCOUNT_3).
    address constant STAGING_1 = 0x408ea1bC71ec2562ABCB27520cf7077718403496;

    uint256 constant BLOCK_1 = 26_240_000;
    uint256 constant BLOCK_42161 = 517_500_000;

    function test_mainnet_removesEzEthAndEigen_cleanly() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), BLOCK_1);
        _premises(EZETH_1);
        assertTrue(INAVCalculator(NAV).isAssetRegistered(EIGEN), "premise: EIGEN registered");

        int256 prodBefore = INAVCalculator(NAV).getAccountNav(PRODUCTION_1, address(0)).value;
        int256 stagingBefore = INAVCalculator(NAV).getAccountNav(STAGING_1, address(0)).value;
        assertGt(prodBefore, 0, "premise: the production account has a NAV");

        vm.startPrank(COUNCIL);
        _removeRenzo();
        IAssetKindRegistryRemoval(AKR).unregisterAsset(EZETH_1);
        IAssetKindRegistryRemoval(AKR).unregisterAsset(EIGEN);
        vm.stopPrank();

        _assertGone(EZETH_1);
        _assertGone(EIGEN);
        assertEq(
            INAVCalculator(NAV).getAccountNav(PRODUCTION_1, address(0)).value, prodBefore, "production NAV unchanged"
        );
        int256 stagingAfter = INAVCalculator(NAV).getAccountNav(STAGING_1, address(0)).value;
        assertLt(stagingAfter, stagingBefore, "the staging Safe loses its ezETH leg");
        assertLt(stagingBefore - stagingAfter, 20e8, "and only that dust leg (< $20)");
    }

    function test_arbitrum_removesEzEth_cleanly() public {
        createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), BLOCK_42161);
        _premises(EZETH_42161);

        vm.startPrank(COUNCIL);
        _removeRenzo();
        IAssetKindRegistryRemoval(AKR).unregisterAsset(EZETH_42161);
        vm.stopPrank();

        _assertGone(EZETH_42161);
    }

    /// @dev Renzo must go before ezETH: unregistering ezETH alone would leave the adapter claiming a coordinate for
    ///      an asset that no longer exists (it reads empty, but the claim lingers and blocks a later re-arm).
    function test_mainnet_unregisterAloneLeavesTheRenzoClaim() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), BLOCK_1);
        vm.prank(COUNCIL);
        IAssetKindRegistryRemoval(AKR).unregisterAsset(EZETH_1);
        assertTrue(IBalances(NAV).isAdapterRegistered(RENZO_ADAPTER), "the adapter is still registered");
        assertEq(IBalances(NAV).getMetaInstances(RENZO_ADAPTER).length, 1, "and still holds the ezETH instance");
    }

    function _premises(address ezEth) internal view {
        assertTrue(IAccessControl(NAV).hasRole(MANAGER, COUNCIL), "premise: the Council holds MANAGER");
        assertTrue(IAccessControl(NAV).hasRole(MANAGER, AKR), "premise: the registry holds MANAGER");
        assertEq(IAssetKindRegistryRemoval(AKR).NAV(), NAV, "premise: the registry points at the proxy");
        assertTrue(INAVCalculator(NAV).isAssetRegistered(ezEth), "premise: ezETH registered");
        assertTrue(IBalances(NAV).isAdapterRegistered(RENZO_ADAPTER), "premise: Renzo adapter registered");
        bytes32[] memory inst = IBalances(NAV).getMetaInstances(RENZO_ADAPTER);
        assertEq(inst.length, 1, "premise: Renzo has one instance");
        assertEq(address(uint160(uint256(inst[0]))), ezEth, "premise: and it is ezETH");
    }

    function _removeRenzo() internal {
        address[] memory ads = new address[](1);
        ads[0] = RENZO_ADAPTER;
        INAVCalculator(NAV).removeBalanceAdapters(ads);
    }

    function _assertGone(address asset) internal view {
        assertFalse(INAVCalculator(NAV).isAssetRegistered(asset), "asset unregistered");
        assertEq(IPrices(NAV).getPriceFeeds(asset).length, 0, "no price feed left");
        assertEq(IPrices(NAV).getMonitorFeeds(asset).length, 0, "no monitor left");
        assertEq(IAssetKindRegistryRemoval(AKR).getAssetLabels(asset).length, 0, "labels cleared");
        assertFalse(IAssetKindRegistryRemoval(AKR).isClassified(asset), "kind cleared");
        assertFalse(IBalances(NAV).isAdapterRegistered(RENZO_ADAPTER), "Renzo adapter deregistered");
        INAVCalculator.Asset[] memory all = INAVCalculator(NAV).getRegisteredAssets();
        for (uint256 i; i < all.length; ++i) {
            assertTrue(all[i].asset != asset, "absent from getRegisteredAssets");
        }
    }
}
