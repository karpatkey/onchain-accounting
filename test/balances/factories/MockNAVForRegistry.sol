// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @notice Stateful mock that satisfies the registry's NAV interface (`addBalanceOracle`,
///         `removeBalanceOracle`, `isOracleRegistered`). Other methods revert if called.
/// @dev Used only by the factory/registry unit tests. The shared `Mock_NAVCalculator`
///      uses `pure` for these methods, which prevents the stateful behavior we need here.
contract MockNAVForRegistry is INAVCalculator {
    mapping(address => bool) private _isReg;

    address[] public addedHistory;
    address[] public removedHistory;

    function setOracleRegistered(address oracle, bool reg) external {
        _isReg[oracle] = reg;
    }

    function addBalanceOracle(address oracle) external override {
        _isReg[oracle] = true;
        addedHistory.push(oracle);
    }

    function removeBalanceOracle(address oracle) external override {
        _isReg[oracle] = false;
        removedHistory.push(oracle);
    }

    function isOracleRegistered(address oracle) external view override returns (bool) {
        return _isReg[oracle];
    }

    function addedCount() external view returns (uint256) {
        return addedHistory.length;
    }

    function removedCount() external view returns (uint256) {
        return removedHistory.length;
    }

    // ── Unused INAVCalculator surface — revert if touched ─────────────────────

    function getRegisteredAssets() external pure override returns (Asset[] memory) {
        revert("not implemented");
    }

    function assetCount() external pure override returns (uint256) {
        revert("not implemented");
    }

    function isAssetRegistered(address) external pure override returns (bool) {
        revert("not implemented");
    }

    function getAssetCount() external pure override returns (uint256) {
        revert("not implemented");
    }

    function checkBalanceOracleSupport(address) external pure override {}

    function getAllOracles() external pure override returns (address[] memory) {
        revert("not implemented");
    }

    function getOracleCount() external pure override returns (uint256) {
        revert("not implemented");
    }

    function getOracleType(address) external pure override returns (OracleType) {
        revert("not implemented");
    }

    function getOraclesForAsset(address) external pure override returns (address[] memory) {
        revert("not implemented");
    }

    function getAccountNav(address, address) external pure override returns (NAV memory) {
        revert("not implemented");
    }

    function getAccountPositions(address, address) external pure override returns (Position[] memory) {
        revert("not implemented");
    }

    function getAccountPositionsForAsset(address, address, address) external pure override returns (Position[] memory) {
        revert("not implemented");
    }

    function calculateValue(address[] memory, uint256[] memory, address) external pure override returns (int256) {
        revert("not implemented");
    }

    function registerAsset(address, address, IPrices.PriceType, uint256) external pure override {
        revert("not implemented");
    }

    function setPriceFeed(address, address, IPrices.PriceType, uint256) external pure override {
        revert("not implemented");
    }

    function unsetPriceFeed(address) external pure override {
        revert("not implemented");
    }

    function unregisterAsset(address) external pure override {
        revert("not implemented");
    }

    function excludeAssetFromDefaultOracle(address) external pure override {
        revert("not implemented");
    }

    function includeAssetInDefaultOracle(address) external pure override {
        revert("not implemented");
    }

    function healthCheck() external pure override returns (bool, address[] memory) {
        revert("not implemented");
    }

    function hasPositions(address) external pure override returns (bool) {
        revert("not implemented");
    }

    function getAssetsWithPositions(address) external pure override returns (address[] memory) {
        revert("not implemented");
    }

    function version() external pure override returns (uint64) {
        return 0;
    }

    function usdDecimals() external pure override returns (uint8) {
        return 8;
    }

    function getPriceData(address) external pure override returns (PriceFeedData memory) {
        revert("not implemented");
    }

    function setChainlinkL2SequencerUptimeFeed(address) external pure override {
        revert("not implemented");
    }

    function setChainlinkL2SequencerGracePeriod(uint256) external pure override {
        revert("not implemented");
    }

    function addBalanceOracleHelper(address oracle) external {
        _isReg[oracle] = true;
        addedHistory.push(oracle);
    }
}
