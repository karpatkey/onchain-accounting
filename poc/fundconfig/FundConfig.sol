// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions, IModuleProxyFactory, IRolesV2} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {ModuleRegistry} from "poc/fundconfig/ModuleRegistry.sol";
import {PermissionMerge} from "poc/fundconfig/PermissionMerge.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Per-fund configuration from which Zodiac Roles v2 permissions and fund NAV are both derived.
/// @dev The fund's Safe (`AVATAR`) enables the Roles clone this contract deploys and owns it. The curator declares
///      positions by `(moduleId, instance)`; each declaration recomputes the Roles permission set for every
///      `(target, selector)` it touches, from the full set of declared positions. The manager is an EOA holding
///      `ROLE_KEY` and calls the Roles clone directly. FundConfig exposes no passthrough to the Safe.
contract FundConfig {
    error NotCurator();
    error UnknownPosition(bytes32 moduleId, bytes32 instance);
    error PositionExists(bytes32 moduleId, bytes32 instance);
    error PositionNotEmpty(bytes32 moduleId, bytes32 instance);
    error OptionsMismatch(address target, bytes4 selector);

    /// @notice A declared position: the module that describes it and its coordinate.
    struct Declared {
        IPositionModule module;
        bytes32 moduleId;
        bytes32 instance;
    }

    event PositionAdded(bytes32 indexed moduleId, bytes32 instance);
    event PositionRemoved(bytes32 indexed moduleId, bytes32 instance);
    event ManagerAssigned(address indexed manager);
    event ManagerRevoked(address indexed manager);

    /// @dev Native ETH pseudo-address used by the repo's NAV and adapters.
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Module registry consulted when declaring positions.
    ModuleRegistry public immutable REGISTRY;

    /// @notice NAV calculator used to price adapter positions and wallet balances.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Zodiac Roles v2 clone that this contract owns and that the Safe enables.
    IRolesV2 public immutable ROLES;

    /// @notice The fund Safe: Roles avatar, adapter `account`, and wallet balance holder.
    address public immutable AVATAR;

    /// @notice Address allowed to declare and remove positions.
    address public immutable CURATOR;

    /// @notice Roles v2 role key that managers are assigned to.
    bytes32 public immutable ROLE_KEY;

    Declared[] private _positions;

    /// @dev `keccak256(moduleId, instance)` -> index + 1 into `_positions` (0 = absent).
    mapping(bytes32 => uint256) private _indexPlusOne;

    /// @dev `keccak256(target, selector)` -> whether the key is currently granted on the Roles clone.
    mapping(bytes32 => bool) private _keyActive;

    /// @dev Target -> number of active keys on it. Target clearance is set on the first key and cleared on the last.
    mapping(address => uint256) private _keysOnTarget;

    modifier onlyCurator() {
        if (msg.sender != CURATOR) revert NotCurator();
        _;
    }

    /// @param registry_ Module registry.
    /// @param nav_ NAV calculator.
    /// @param factory_ Zodiac ModuleProxyFactory.
    /// @param rolesMastercopy_ Zodiac Roles v2 mastercopy.
    /// @param avatar_ The fund Safe. Must `enableModule` the Roles clone after construction.
    /// @param curator_ Address allowed to declare positions.
    /// @param roleKey_ Roles v2 role key for managers.
    /// @param saltNonce_ CREATE2 salt nonce for the Roles clone.
    constructor(
        ModuleRegistry registry_,
        INAVCalculator nav_,
        IModuleProxyFactory factory_,
        address rolesMastercopy_,
        address avatar_,
        address curator_,
        bytes32 roleKey_,
        uint256 saltNonce_
    ) {
        REGISTRY = registry_;
        NAV_CALCULATOR = nav_;
        AVATAR = avatar_;
        CURATOR = curator_;
        ROLE_KEY = roleKey_;

        ROLES = IRolesV2(
            factory_.deployModule(
                rolesMastercopy_,
                abi.encodeCall(IRolesV2.setUp, (abi.encode(address(this), avatar_, avatar_))),
                saltNonce_
            )
        );
    }

    /// @notice Declares a position and grants its Roles permissions.
    /// @param moduleId Registered module id.
    /// @param instance Module-specific coordinate.
    function addPosition(bytes32 moduleId, bytes32 instance) external onlyCurator {
        IPositionModule module = REGISTRY.moduleOf(moduleId);
        module.validate(instance);

        bytes32 id = keccak256(abi.encode(moduleId, instance));
        if (_indexPlusOne[id] != 0) revert PositionExists(moduleId, instance);

        _positions.push(Declared({module: module, moduleId: moduleId, instance: instance}));
        _indexPlusOne[id] = _positions.length;
        emit PositionAdded(moduleId, instance);

        PermissionLeaf[] memory leaves = module.permissions(instance);
        for (uint256 i; i < leaves.length; ++i) {
            _syncKey(leaves[i].target, leaves[i].selector);
        }
    }

    /// @notice Removes a declared position and revokes permissions it alone required.
    /// @dev Reverts while the position has any non-zero adapter balance, so a position with value cannot be dropped.
    /// @param moduleId Registered module id.
    /// @param instance Module-specific coordinate.
    function removePosition(bytes32 moduleId, bytes32 instance) external onlyCurator {
        bytes32 id = keccak256(abi.encode(moduleId, instance));
        uint256 idx = _indexPlusOne[id];
        if (idx == 0) revert UnknownPosition(moduleId, instance);

        Declared memory d = _positions[idx - 1];
        INAVCalculator.PositionBalance[] memory balances = _balances(d);
        for (uint256 i; i < balances.length; ++i) {
            if (balances[i].amount != 0) revert PositionNotEmpty(moduleId, instance);
        }

        PermissionLeaf[] memory leaves = d.module.permissions(instance);

        uint256 last = _positions.length - 1;
        if (idx - 1 != last) {
            Declared memory moved = _positions[last];
            _positions[idx - 1] = moved;
            _indexPlusOne[keccak256(abi.encode(moved.moduleId, moved.instance))] = idx;
        }
        _positions.pop();
        delete _indexPlusOne[id];
        emit PositionRemoved(moduleId, instance);

        for (uint256 i; i < leaves.length; ++i) {
            _syncKey(leaves[i].target, leaves[i].selector);
        }
    }

    /// @notice Grants (`member` true) or revokes (`member` false) `manager`'s fund role on the Roles clone.
    function assignManager(address manager, bool member) external onlyCurator {
        _setManager(manager, member);
        if (member) emit ManagerAssigned(manager);
        else emit ManagerRevoked(manager);
    }

    /// @notice Declared positions in storage order.
    function positions() external view returns (Declared[] memory out) {
        out = _positions;
    }

    /// @notice Every Roles permission leaf declared by the current positions, before merging.
    function permissionSet() external view returns (PermissionLeaf[] memory out) {
        uint256 total;
        PermissionLeaf[][] memory perPosition = new PermissionLeaf[][](_positions.length);
        for (uint256 i; i < _positions.length; ++i) {
            perPosition[i] = _positions[i].module.permissions(_positions[i].instance);
            total += perPosition[i].length;
        }

        out = new PermissionLeaf[](total);
        uint256 k;
        for (uint256 i; i < perPosition.length; ++i) {
            for (uint256 j; j < perPosition[i].length; ++j) {
                out[k++] = perPosition[i][j];
            }
        }
    }

    /// @notice Fund NAV in `quoteAsset`: signed sum of declared positions plus the Safe's wallet balances of their assets.
    /// @dev Adapter positions are priced via `NAV_CALCULATOR.calculateValue` and signed by `isDebt`. Wallet balances are
    ///      counted for the deduplicated union of `assets()` across declared positions. Tokens the Safe holds that are
    ///      not declared by any position are excluded.
    /// @return value Signed NAV in `quoteAsset` units.
    /// @return stale True if any price used is stale.
    function fundNav(address quoteAsset) external view returns (int256 value, bool stale) {
        address[] memory tokens = _walletTokens();
        for (uint256 t; t < tokens.length; ++t) {
            uint256 bal = tokens[t] == NATIVE_ETH ? AVATAR.balance : IERC20Min(tokens[t]).balanceOf(AVATAR);
            if (bal == 0) continue;
            (int256 v, bool s) = _price(tokens[t], bal, quoteAsset);
            value += v;
            stale = stale || s;
        }

        for (uint256 i; i < _positions.length; ++i) {
            INAVCalculator.PositionBalance[] memory balances = _balances(_positions[i]);
            for (uint256 j; j < balances.length; ++j) {
                if (balances[j].amount == 0) continue;
                (int256 v, bool s) = _price(balances[j].balanceAsset.asset, balances[j].amount, quoteAsset);
                value += balances[j].isDebt ? -v : v;
                stale = stale || s;
            }
        }
    }

    /// @dev Setting a manager's membership on the Roles clone.
    function _setManager(address manager, bool member) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = ROLE_KEY;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = member;
        ROLES.assignRoles(manager, keys, memberOf);
    }

    /// @dev Recomputes the Roles permission for `(target, selector)` from every declared position.
    ///      Unconditional leaf -> `allowFunction`; conditional leaves -> `scopeFunction` with their OR; none -> revoke.
    ///      All contributing leaves must share one `ExecutionOptions` value, so no option is granted by accident.
    function _syncKey(address target, bytes4 selector) internal {
        bytes32 key = keccak256(abi.encodePacked(target, selector));

        PermissionLeaf[][] memory leaves = new PermissionLeaf[][](_positions.length);
        uint256 total;
        for (uint256 i; i < _positions.length; ++i) {
            leaves[i] = _positions[i].module.permissions(_positions[i].instance);
            total += leaves[i].length;
        }

        ConditionFlat[][] memory conditional = new ConditionFlat[][](total);
        uint256 conditionalCount;
        bool unconditional;
        bool hasOptions;
        ExecutionOptions opts;
        for (uint256 i; i < leaves.length; ++i) {
            for (uint256 j; j < leaves[i].length; ++j) {
                PermissionLeaf memory leaf = leaves[i][j];
                if (leaf.target != target || leaf.selector != selector) continue;

                if (!hasOptions) {
                    opts = leaf.options;
                    hasOptions = true;
                } else if (leaf.options != opts) {
                    revert OptionsMismatch(target, selector);
                }

                if (leaf.conditions.length == 0) {
                    unconditional = true;
                } else {
                    conditional[conditionalCount++] = leaf.conditions;
                }
            }
        }

        bool wasActive = _keyActive[key];
        if (!unconditional && conditionalCount == 0) {
            if (wasActive) {
                ROLES.revokeFunction(ROLE_KEY, target, selector);
                _keyActive[key] = false;
                if (--_keysOnTarget[target] == 0) ROLES.revokeTarget(ROLE_KEY, target);
            }
            return;
        }

        if (!wasActive) {
            if (_keysOnTarget[target]++ == 0) ROLES.scopeTarget(ROLE_KEY, target);
            _keyActive[key] = true;
        }

        if (unconditional) {
            ROLES.allowFunction(ROLE_KEY, target, selector, opts);
            return;
        }

        ConditionFlat[][] memory trees = new ConditionFlat[][](conditionalCount);
        for (uint256 t; t < conditionalCount; ++t) {
            trees[t] = conditional[t];
        }
        ConditionFlat[] memory merged = conditionalCount == 1 ? trees[0] : PermissionMerge.orOf(trees);
        ROLES.scopeFunction(ROLE_KEY, target, selector, merged, opts);
    }

    /// @dev Adapter positions for one declared position, valued through its accounting route.
    function _balances(Declared memory d) internal view returns (INAVCalculator.PositionBalance[] memory) {
        Accounting memory a = d.module.accounting(d.instance);
        if (a.isMeta) {
            bytes32[] memory instances = new bytes32[](1);
            instances[0] = a.coordinate;
            return IMetaBalanceAdapter(a.adapter).getAdapterPositionsForInstances(AVATAR, instances, a.assetFilter);
        }
        return IBalanceAdapter(a.adapter).getAdapterPositions(AVATAR, a.assetFilter);
    }

    /// @dev Deduplicated union of `assets()` across declared positions.
    function _walletTokens() internal view returns (address[] memory tokens) {
        uint256 cap;
        address[][] memory perPosition = new address[][](_positions.length);
        for (uint256 i; i < _positions.length; ++i) {
            perPosition[i] = _positions[i].module.assets(_positions[i].instance);
            cap += perPosition[i].length;
        }

        address[] memory buf = new address[](cap);
        uint256 n;
        for (uint256 i; i < perPosition.length; ++i) {
            for (uint256 j; j < perPosition[i].length; ++j) {
                address token = perPosition[i][j];
                bool seen;
                for (uint256 k; k < n; ++k) {
                    if (buf[k] == token) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) buf[n++] = token;
            }
        }

        tokens = new address[](n);
        for (uint256 k; k < n; ++k) {
            tokens[k] = buf[k];
        }
    }

    /// @dev Prices `amount` of `asset` in `quoteAsset`.
    function _price(address asset, uint256 amount, address quoteAsset) internal view returns (int256, bool) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        return NAV_CALCULATOR.calculateValue(assets, amounts, quoteAsset);
    }
}
