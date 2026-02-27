// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title BridgedAssetsOracle
/// @notice Temporary balance adapter where bridged positions are manually opened/closed by whitelisted operators
/// @dev Positions are credit-only (isDebt=false) and consumed by NAVCalculator like any other adapter.
contract BridgedAssetsOracle is IBalanceOracleAdapter {
    using SafeCast for uint256;

    struct BridgePosition {
        address account;
        address asset;
        uint256 amount;
        uint64 destinationChainId;
        bool active;
    }

    struct AggregatedAssetBalance {
        address asset;
        uint256 amount;
    }

    struct AggregatedChainBalance {
        address asset;
        uint64 destinationChainId;
        uint256 amount;
    }

    INAVCalculator public immutable NAV_CALCULATOR;
    address public immutable ADMIN;

    string private _protocol;

    uint256 private _nextBridgeId = 1;
    mapping(uint256 bridgeId => BridgePosition position) private _positions;
    mapping(address account => uint256[] bridgeIds) private _positionsByAccount;
    mapping(address operator => bool allowed) private _operators;

    event OperatorUpdated(address indexed operator, bool allowed);
    event BridgePositionOpened(
        uint256 indexed bridgeId,
        address indexed operator,
        address indexed account,
        address asset,
        uint256 amount,
        uint64 sourceChainId,
        uint64 destinationChainId
    );
    event BridgePositionClosed(uint256 indexed bridgeId);

    constructor(address navCalculator_, string memory protocol_) {
        if (navCalculator_ == address(0)) revert InvalidArguments();
        if (bytes(protocol_).length == 0) revert InvalidArguments();
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        ADMIN = msg.sender;
        _protocol = protocol_;
    }

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAuthorized();
        _;
    }

    modifier onlyOperator() {
        if (!_operators[msg.sender]) revert NotAuthorized();
        _;
    }

    function setOperator(address operator, bool allowed) external onlyAdmin {
        if (operator == address(0)) revert InvalidArguments();
        _operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function isOperator(address operator) external view returns (bool) {
        return _operators[operator];
    }

    function openBridgePosition(address account, address asset, uint256 amount, uint64 destinationChainId)
        external
        onlyOperator
        returns (uint256 bridgeId)
    {
        if (account == address(0) || asset == address(0) || amount == 0 || destinationChainId == 0) {
            revert InvalidArguments();
        }
        if (!NAV_CALCULATOR.isAssetRegistered(asset)) revert AssetNotFound();

        bridgeId = _nextBridgeId++;
        _positions[bridgeId] = BridgePosition({
            account: account, asset: asset, amount: amount, destinationChainId: destinationChainId, active: true
        });
        _positionsByAccount[account].push(bridgeId);

        emit BridgePositionOpened(
            bridgeId, msg.sender, account, asset, amount, block.chainid.toUint64(), destinationChainId
        );
    }

    function closeBridgePosition(uint256 bridgeId) external onlyOperator {
        BridgePosition storage position = _positions[bridgeId];
        if (!position.active) revert InvalidArguments();
        position.active = false;
        emit BridgePositionClosed(bridgeId);
    }

    function getBridgePosition(uint256 bridgeId) external view returns (BridgePosition memory) {
        return _positions[bridgeId];
    }

    function getAccountActiveBridgePositions(address account) external view returns (BridgePosition[] memory) {
        if (account == address(0)) return new BridgePosition[](0);
        uint256[] storage ids = _positionsByAccount[account];
        BridgePosition[] memory temp = new BridgePosition[](ids.length);
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            BridgePosition memory position = _positions[ids[i]];
            if (!position.active) continue;
            temp[count++] = position;
        }

        BridgePosition[] memory positions = new BridgePosition[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    function getActiveBridgePositionsByDestinationChain(uint64 destinationChainId)
        external
        view
        returns (BridgePosition[] memory positions)
    {
        if (destinationChainId == 0) return new BridgePosition[](0);

        BridgePosition[] memory temp = new BridgePosition[](_nextBridgeId - 1);
        uint256 count = 0;
        for (uint256 bridgeId = 1; bridgeId < _nextBridgeId; bridgeId++) {
            BridgePosition memory position = _positions[bridgeId];
            if (!position.active || position.destinationChainId != destinationChainId) continue;
            temp[count++] = position;
        }

        positions = new BridgePosition[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
    }

    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);
        if (assetFilter != address(0) && !NAV_CALCULATOR.isAssetRegistered(assetFilter)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        (, AggregatedChainBalance[] memory chainBalances) = _collectAccountBalances(account, assetFilter);
        if (chainBalances.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registeredAssets = NAV_CALCULATOR.getRegisteredAssets();
        positions = new INAVCalculator.PositionBalance[](chainBalances.length);
        for (uint256 i = 0; i < chainBalances.length; i++) {
            INAVCalculator.Asset memory assetInfo = _findRegisteredAsset(registeredAssets, chainBalances[i].asset);
            positions[i] = INAVCalculator.PositionBalance({
                underlyingAsset: assetInfo,
                balanceOracle: address(this),
                amount: chainBalances[i].amount,
                isDebt: false,
                protocol: _protocol,
                positionDetail: string.concat("Bridging to ", Strings.toString(chainBalances[i].destinationChainId))
            });
        }
    }

    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        (AggregatedAssetBalance[] memory balances,) = _collectAccountBalances(account, address(0));
        uint256 count = balances.length;
        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = balances[i].asset;
            amounts[i] = balances[i].amount;
            isDebt[i] = false;
        }
    }

    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0) || !NAV_CALCULATOR.isAssetRegistered(asset)) {
            return (0, false);
        }
        (AggregatedAssetBalance[] memory balances,) = _collectAccountBalances(account, asset);
        if (balances.length == 0) return (0, false);
        return (balances[0].amount, false);
    }

    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets) {
        INAVCalculator.Asset[] memory registeredAssets = NAV_CALCULATOR.getRegisteredAssets();
        underlyingAssets = new address[](registeredAssets.length);
        for (uint256 i = 0; i < registeredAssets.length; i++) {
            underlyingAssets[i] = registeredAssets[i].asset;
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _collectAccountBalances(address account, address assetFilter)
        internal
        view
        returns (AggregatedAssetBalance[] memory assetBalances, AggregatedChainBalance[] memory chainBalances)
    {
        uint256[] storage ids = _positionsByAccount[account];
        if (ids.length == 0) return (new AggregatedAssetBalance[](0), new AggregatedChainBalance[](0));

        AggregatedAssetBalance[] memory tempAssets = new AggregatedAssetBalance[](ids.length);
        AggregatedChainBalance[] memory tempChains = new AggregatedChainBalance[](ids.length);
        uint256 assetCount = 0;
        uint256 chainCount = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            BridgePosition memory position = _positions[ids[i]];
            if (!position.active) continue;
            if (assetFilter != address(0) && position.asset != assetFilter) continue;
            if (!NAV_CALCULATOR.isAssetRegistered(position.asset)) continue;

            bool foundAsset = false;
            for (uint256 j = 0; j < assetCount; j++) {
                if (tempAssets[j].asset == position.asset) {
                    tempAssets[j].amount += position.amount;
                    foundAsset = true;
                    break;
                }
            }
            if (!foundAsset) {
                tempAssets[assetCount++] = AggregatedAssetBalance({asset: position.asset, amount: position.amount});
            }

            bool foundChain = false;
            for (uint256 j = 0; j < chainCount; j++) {
                if (
                    tempChains[j].asset == position.asset
                        && tempChains[j].destinationChainId == position.destinationChainId
                ) {
                    tempChains[j].amount += position.amount;
                    foundChain = true;
                    break;
                }
            }
            if (!foundChain) {
                tempChains[chainCount++] = AggregatedChainBalance({
                    asset: position.asset, destinationChainId: position.destinationChainId, amount: position.amount
                });
            }
        }

        assetBalances = new AggregatedAssetBalance[](assetCount);
        for (uint256 i = 0; i < assetCount; i++) {
            assetBalances[i] = tempAssets[i];
        }

        chainBalances = new AggregatedChainBalance[](chainCount);
        for (uint256 i = 0; i < chainCount; i++) {
            chainBalances[i] = tempChains[i];
        }
    }

    function _findRegisteredAsset(INAVCalculator.Asset[] memory registeredAssets, address asset)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        for (uint256 i = 0; i < registeredAssets.length; i++) {
            if (registeredAssets[i].asset == asset) return registeredAssets[i];
        }
        revert AssetNotFound();
    }
}
