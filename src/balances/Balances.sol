// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IBalances} from "./IBalances.sol";
import {IBalanceOracleCustom} from "./IBalanceOracleCustom.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "src/errors.sol";

/// @title Balances
/// @author kpk
/// @notice Manages the balance oracles for different tokens and their latest balances.
abstract contract Balances is IBalances, Initializable {
    //
    // Libraries
    //
    using ERC165Checker for address;
    using SafeCast for uint256;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //
    // Constants
    //

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice The symbol of the chain's native token, used for display purposes
    string internal _nativeTokenSymbol;

    //
    // Storage
    //

    /// @notice Mapping from token address to balance oracles.
    mapping(address token => EnumerableMap.AddressToUintMap oracles) private _balanceOracles;

    /// @notice Total count of balance oracles.
    uint256 public balanceOracleTotalCount;

    //
    // Constructor
    //

    /// @notice Initializer for UUPS proxy
    // solhint-disable-next-line func-name-mixedcase
    function __Balances_init() internal onlyInitializing {
        // This is equal everywhere, so we add it right away. The same does noy apply for the adding of the price
        // oracle. The native token will not be added to the _assetDecimals mapping unless the proper price oracle is
        // set.
        _balanceOracles[NATIVE_ADDRESS].set(NATIVE_ADDRESS, uint256(BalanceType.Native));
        balanceOracleTotalCount = 1;
        _nativeTokenSymbol = "ETH"; // Default value, can be overridden by derived contracts
    }

    //
    // IBalances
    //

    /// @inheritdoc IBalances
    function balanceOf(address underlyingAsset, uint256 idx, address account) public view returns (int256) {
        if (idx >= _balanceOracles[underlyingAsset].length()) {
            revert BalanceOracleNotSet();
        }

        (address oracleAddress, uint256 balanceTypeUInt) = _balanceOracles[underlyingAsset].at(idx);
        BalanceType balanceType = BalanceType(balanceTypeUInt);

        if (oracleAddress == address(0)) {
            revert BalanceOracleNotSet();
        }

        int256 balance;

        if (balanceType == BalanceType.ERC20) {
            balance = ERC20(oracleAddress).balanceOf(account).toInt256();
        } else if (balanceType == BalanceType.Native) {
            balance = address(account).balance.toInt256();
        } else {
            balance = IBalanceOracleCustom(oracleAddress).balanceOf(underlyingAsset, account);
        }

        return balance;
    }

    /// @inheritdoc IBalances
    function balanceOracleCountFor(address underlyingAsset) public view override returns (uint256) {
        return _balanceOracles[underlyingAsset].length();
    }

    /// @inheritdoc IBalances
    function balanceOracleAt(address underlyingAsset, uint256 idx) public view override returns (address, BalanceType) {
        (address oracleAddress, uint256 balanceTypeUInt) = _balanceOracles[underlyingAsset].at(idx);
        return (oracleAddress, BalanceType(balanceTypeUInt));
    }

    /// @inheritdoc IBalances
    function balanceOracles(address underlyingAsset) public view override returns (address[] memory) {
        return _balanceOracles[underlyingAsset].keys();
    }

    /// @inheritdoc IBalances
    function balanceOraclesWithMetadata(address underlyingAsset)
        public
        view
        override
        returns (BalanceOracleWithMetadata[] memory)
    {
        uint256 len = _balanceOracles[underlyingAsset].length();
        BalanceOracleWithMetadata[] memory list = new BalanceOracleWithMetadata[](len);

        for (uint256 idx = 0; idx < len; idx++) {
            list[idx] = _balanceOracleWithMetadata(underlyingAsset, idx);
        }

        return list;
    }

    /// @inheritdoc IBalances
    function checkBalanceOracleSupport(address underlyingAsset, address oracle, BalanceType balanceType) public view {
        if (oracle == address(0) || underlyingAsset == address(0)) revert InvalidArguments();

        if (balanceType == BalanceType.Custom) {
            if (!oracle.supportsInterface(type(IBalanceOracleCustom).interfaceId)) {
                revert InvalidBalanceOracle();
            }
        } else if (balanceType == BalanceType.ERC20) {
            ERC20(oracle).balanceOf(address(this));
        } else if (balanceType == BalanceType.Native) {
            // Native balance oracles are always supported, added in the constructor
            revert DuplicateBalanceOracle();
        } else {
            revert InvalidBalanceOracleType();
        }

        if (_balanceOracles[underlyingAsset].contains(oracle)) {
            revert DuplicateBalanceOracle();
        }
    }

    //
    // Internal API
    //

    /// @notice Sets the oracle for a given underlying asset.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param balanceType The type of the oracle.
    function _addBalanceOracle(address underlyingAsset, address oracle, BalanceType balanceType) internal {
        checkBalanceOracleSupport(underlyingAsset, oracle, balanceType);

        _balanceOracles[underlyingAsset].set(oracle, uint256(balanceType));
        balanceOracleTotalCount++;

        emit BalanceOracleAdd(underlyingAsset, oracle, balanceType);
    }

    /// @notice Removes the oracle for a given underlying asset.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    function _removeBalanceOracle(address underlyingAsset, address oracle) internal {
        if (underlyingAsset == NATIVE_ADDRESS && oracle == NATIVE_ADDRESS) revert InvalidArguments();

        bool removed = _balanceOracles[underlyingAsset].remove(oracle);

        if (!removed) {
            revert InvalidBalanceOracle();
        }

        balanceOracleTotalCount--;

        emit BalanceOracleRemoved(underlyingAsset, oracle);
    }

    /// @notice Fetches metadata for the oracle at a specific index for an asset
    /// @dev Constructs a `BalanceOracleWithMetadata` by:
    /// 1. If `Custom`, calling `positionMetadata()` on the custom oracle
    /// 2. If `Native`, using `_nativeTokenSymbol` and type "Native"
    /// 3. Otherwise (`ERC20`), attempting `symbol()` or falling back to empty string
    /// @param underlyingAsset The asset whose oracle metadata is fetched
    /// @param idx The index of the balance oracle.
    /// @return balanceOracleWithMetadata A struct with `oracle`, `protocol`, `position`, and `positionType` fields
    function _balanceOracleWithMetadata(address underlyingAsset, uint256 idx)
        internal
        view
        returns (BalanceOracleWithMetadata memory balanceOracleWithMetadata)
    {
        (address oracle, uint256 balanceTypeUInt) = _balanceOracles[underlyingAsset].at(idx);
        BalanceType balanceType = BalanceType(balanceTypeUInt);

        IBalanceOracleCustom.PositionMetadata memory metadata;

        if (balanceType == BalanceType.Custom) {
            metadata = IBalanceOracleCustom(oracle).positionMetadata();
        } else if (balanceType == BalanceType.Native) {
            metadata = IBalanceOracleCustom.PositionMetadata({
                protocol: "Portfolio balance", position: _nativeTokenSymbol, positionType: "Native"
            });
        } else {
            string memory symbol;
            try ERC20(oracle).symbol() returns (string memory symbol_) {
                symbol = symbol_;
            } catch {
                symbol = "";
            }
            metadata = IBalanceOracleCustom.PositionMetadata({
                protocol: "Portfolio balance", position: symbol, positionType: "ERC20"
            });
        }

        return BalanceOracleWithMetadata({
            oracle: oracle,
            protocol: metadata.protocol,
            position: metadata.position,
            positionType: metadata.positionType
        });
    }

    /// @notice Gap for upgradeability
    uint256[50] private __gap;
}
