// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {IBalances, Balances} from "src/balances/Balances.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {BridgeAware} from "./BridgeAware.sol";
import {RecoverFunds} from "../RecoverFunds.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "src/errors.sol";
import "src/constants.sol";

/// @title NAV Calculator
/// @notice Calculates NAV based on on-chain balances and price oracles.
/// @author kpk
contract NAVCalculator is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    INAVCalculator,
    Prices,
    Balances,
    BridgeAware,
    RecoverFunds
{
    //
    // Libraries
    //
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //
    // State
    //

    /// @notice Set of known assets to track
    EnumerableMap.AddressToUintMap private _assetDecimals;

    /// @notice Asset recoverer. useful solely for recovery of wrongly sent funds to this contract.
    /// @dev This is the recipient address that will receive the assets recovered by a call to the `recoverAssets`
    /// function.
    address public assetRecoverer;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for UUPS proxy
    /// @param admin_ The initial admin
    /// @param assetRecoverer_ Asset recoverer. useful solely for recovery of wrongly sent funds
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the chainlink feed for the sequencer uptime
    function initialize(address admin_, address assetRecoverer_, address chainlinkL2SequencerUptimeFeed_)
        public
        initializer
    {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Prices_init(chainlinkL2SequencerUptimeFeed_);
        __Balances_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        assetRecoverer = assetRecoverer_;
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function addPrice(address underlyingAsset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        // TODO: are all native _assets 18 decimals?
        uint8 decimals = underlyingAsset == NATIVE_ADDRESS ? 18 : IERC20Metadata(underlyingAsset).decimals();
        _assetDecimals.set(underlyingAsset, decimals);

        _setPriceOracle(underlyingAsset, oracle, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addBalance(address underlyingAsset, address oracle, IBalances.BalanceType balanceType) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        if (!_assetDecimals.contains(underlyingAsset)) {
            revert AssetNotFound();
        }

        _addBalanceOracle(underlyingAsset, oracle, balanceType);
    }

    /// @inheritdoc INAVCalculator
    function removePrice(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        if (balanceOracleCountFor(underlyingAsset) > 0) {
            revert InvalidArguments();
        }

        bool success = _assetDecimals.remove(underlyingAsset);

        if (!success) {
            revert AssetNotFound();
        }
        _removePriceOracle(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function removeBalance(address underlyingAsset, address oracle) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        if (!_assetDecimals.contains(underlyingAsset)) {
            revert AssetNotFound();
        }

        _removeBalanceOracle(underlyingAsset, oracle);
    }

    /// @inheritdoc INAVCalculator
    function setNativeTokenSymbol(string memory nativeTokenSymbol) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        _nativeTokenSymbol = nativeTokenSymbol;
    }

    /// @inheritdoc INAVCalculator
    function setAssetRecoverer(address newAssetRecoverer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAssetRecoverer = assetRecoverer;
        assetRecoverer = newAssetRecoverer;
        emit AssetRecovererUpdated(oldAssetRecoverer, newAssetRecoverer);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2SequencerUptimeFeed) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        address oldChainlinkL2SequencerUptimeFeed = address(chainlinkL2SequencerUptimeFeed);
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(newChainlinkL2SequencerUptimeFeed);
        emit ChainlinkUptimeFeedUpdated(oldChainlinkL2SequencerUptimeFeed, newChainlinkL2SequencerUptimeFeed);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (address(chainlinkL2SequencerUptimeFeed) == address(0)) {
            revert UptimeFeedNotSet();
        }
        if (newSequencerGracePeriod == 0) {
            revert InvalidArguments();
        }
        uint256 oldSequencerGracePeriod = chainlinkL2SequencerGracePeriod;
        chainlinkL2SequencerGracePeriod = newSequencerGracePeriod;
        emit L2SequencerGracePeriodUpdated(oldSequencerGracePeriod, newSequencerGracePeriod);
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view returns (uint256) {
        return _assetDecimals.length();
    }

    /// @inheritdoc INAVCalculator
    function read(address account) external view returns (INAVCalculator.NAV memory nav) {
        nav.block = uint64(block.number);
        nav.timestamp = uint64(block.timestamp);

        uint256 length = _assetDecimals.length();

        if (length != 0) {
            // read all of the account's positions
            // NOTE: this can exceed gas limit
            (nav.usd, nav.issues) = readPositionsRange(account, 0, length - 1);
        }
    }

    /// @inheritdoc INAVCalculator
    function readPositionsRange(address account, uint256 from, uint256 to)
        public
        view
        returns (int256 usd, uint16 issues)
    {
        if (from > to || to >= _assetDecimals.length()) {
            revert InvalidArguments();
        }

        if (checkL2SequencerUptime()) {
            issues++;
        }

        // iterate over every known asset
        for (uint256 i = from; i <= to; i++) {
            (address assetAddr,) = _assetDecimals.at(i);

            if (priceOracles[assetAddr].oracle == address(0)) {
                revert PriceOracleNotSet();
            }

            bool bridging = isAssetBridging(assetAddr);
            if (bridging) {
                issues++;
            }

            // fetches the current price for this asset
            (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(assetAddr);

            if (stale) {
                issues++;
            }

            // for each asset, iterate over its known balance oracles
            uint256 balanceOracleCount = balanceOracleCountFor(assetAddr);
            for (uint256 balanceIdx = 0; balanceIdx < balanceOracleCount; ++balanceIdx) {
                usd += _calculatePositionUsdValue(account, assetAddr, balanceIdx, usdRate, usdRateDecimals);
            }
        }
    }

    /// @inheritdoc INAVCalculator
    function readPosition(address account, address underlyingAsset, uint256 idxBalanceOracle)
        external
        view
        returns (INAVCalculator.Position memory p)
    {
        if (!_assetDecimals.contains(underlyingAsset)) {
            revert AssetNotFound();
        }

        if (priceOracles[underlyingAsset].oracle == address(0)) {
            revert PriceOracleNotSet();
        }

        bool bridging = isAssetBridging(underlyingAsset);

        (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(underlyingAsset);

        if (checkL2SequencerUptime()) {
            stale = true;
        }

        return _readPositionWithPrice(
            account, underlyingAsset, idxBalanceOracle, usdRate, usdRateDecimals, bridging, stale
        );
    }

    /// @inheritdoc INAVCalculator
    function readPositionWithMetadata(address account, address underlyingAsset, uint256 idx)
        external
        view
        returns (INAVCalculator.PositionWithMetadata memory p)
    {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(underlyingAsset);

        if (!contains) {
            revert AssetNotFound();
        }

        BalanceOracleWithMetadata memory oracleWithMetadata = _balanceOracleWithMetadata(underlyingAsset, idx);

        (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(underlyingAsset);

        string memory symbol;
        if (underlyingAsset == NATIVE_ADDRESS) {
            symbol = _nativeTokenSymbol;
        } else {
            try IERC20Metadata(underlyingAsset).symbol() returns (string memory symbol_) {
                symbol = symbol_;
            } catch {
                symbol = "";
            }
        }

        p.protocol = oracleWithMetadata.protocol;
        p.position = oracleWithMetadata.position;
        p.positionType = oracleWithMetadata.positionType;
        p.underlyingAsset = underlyingAsset;
        p.underlyingAssetSymbol = symbol;
        p.underlyingAssetDecimals = uint8(decimals);
        p.usdRate = usdRate;
        p.usdRateDecimals = usdRateDecimals;
        p.stale = stale;
        p.balance = balanceOf(underlyingAsset, idx, account);
        p.usd = _toUsd(p.balance, uint8(decimals), usdRate, usdRateDecimals);
        p.bridging = isAssetBridging(underlyingAsset);

        return p;
    }

    /// @inheritdoc INAVCalculator
    function usdDecimals() external pure returns (uint8) {
        return NAV_DECIMALS;
    }

    /// @inheritdoc INAVCalculator
    function assetAt(uint256 idx) external view returns (INAVCalculator.Asset memory a) {
        (address asset, uint256 decimals) = _assetDecimals.at(idx);
        a.addr = asset;
        a.decimals = uint8(decimals);
    }

    /// @inheritdoc INAVCalculator
    function assets() external view returns (address[] memory) {
        return _assetDecimals.keys();
    }

    //
    // BridgeAware
    //

    /// @inheritdoc BridgeAware
    //solhint-disable-next-line func-name-mixedcase, no-empty-blocks
    function _bridgeAware_ensureCanCall(bytes4 /* selector */ ) internal view override(BridgeAware) {
        //  TODO: test this
        if (!hasRole(OPERATOR, msg.sender)) revert NotAuthorized();
    }

    //
    // RecoverFunds
    //

    /// @inheritdoc RecoverFunds
    function _assetRecoverer() internal view override(RecoverFunds) returns (address) {
        return assetRecoverer;
    }

    //
    // UUPSUpgradeable
    //

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address /* newImpl */ ) internal view override(UUPSUpgradeable) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
    }

    //
    // Internal API
    //

    /// @notice Computes the full position data, along with the USD vale based on the already-provided exchange rate
    /// info
    /// @param account The address of the account
    /// @param underlyingAsset The address of the asset
    /// @param idxBalanceOracle The index of the balance oracle
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @param bridging If the asset is bridging
    /// @param stale If the price is stale
    /// @return p The computed position
    function _readPositionWithPrice(
        address account,
        address underlyingAsset,
        uint256 idxBalanceOracle,
        uint256 usdRate,
        uint256 usdRateDecimals,
        bool bridging,
        bool stale
    ) internal view returns (INAVCalculator.Position memory p) {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(underlyingAsset);

        if (!contains) {
            revert AssetNotFound();
        }

        p.underlyingAsset = underlyingAsset;
        p.balance = balanceOf(underlyingAsset, idxBalanceOracle, account);
        p.stale = stale;
        p.usdRate = usdRate;
        p.usdRateDecimals = usdRateDecimals;
        p.bridging = bridging;
        p.usd = _toUsd(p.balance, uint8(decimals), usdRate, usdRateDecimals);
    }

    /// @notice Calculates the USD value of a given position
    /// @param account The address of the account
    /// @param underlyingAsset The address of the asset
    /// @param idxBalanceOracle The index of the balance oracle
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @return usd The computed USD value of the position
    function _calculatePositionUsdValue(
        address account,
        address underlyingAsset,
        uint256 idxBalanceOracle,
        uint256 usdRate,
        uint256 usdRateDecimals
    ) internal view returns (int256 usd) {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(underlyingAsset);

        if (!contains) {
            revert AssetNotFound();
        }
        int256 balance = balanceOf(underlyingAsset, idxBalanceOracle, account);
        return _toUsd(balance, uint8(decimals), usdRate, usdRateDecimals);
    }

    /// @notice Converts an asset's balance to USD
    /// @param balance The balance of the asset
    /// @param decimals The number of decimals of the asset
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @return usd The computed balance in USD
    function _toUsd(int256 balance, uint16 decimals, uint256 usdRate, uint256 usdRateDecimals)
        internal
        pure
        returns (int256 usd)
    {
        usd = (balance * int256(usdRate)) / int256(10 ** (decimals + usdRateDecimals - NAV_DECIMALS));
    }
}
