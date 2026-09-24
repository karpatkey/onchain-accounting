// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A default adapter whose `addSupportedAsset` consumes everything forwarded to it.
/// @dev Models a STARVED re-include, not a misbehaving adapter: the real `addSupportedAsset` is a full
///      external call that calls back into the proxy (`isAssetRegistered`), so on a long release loop a late
///      coordinate can legitimately be handed too little of a dwindling frame. An infinite loop is the
///      cheapest way to make "the call consumed its whole stipend and failed" reproducible.
contract GasBurningDefaultAdapter {
    function addSupportedAsset(address) external pure {
        // Burn whatever was forwarded. `while (true) {}` alone is optimised away, so keep a side effect.
        uint256 x = 1;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
    }

    function removeSupportedAsset(address) external {}

    function isSupportedByDefault(address) external pure returns (bool) {
        return false;
    }
}

contract MinimalMetaAdapter is IMetaBalanceAdapter {
    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IBalanceAdapter).interfaceId || id == type(IMetaBalanceAdapter).interfaceId
            || id == type(IERC165).interfaceId;
    }

    function getAdapterPositionsForInstances(address, bytes32[] calldata, address)
        external
        pure
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function underlyingAssetsSupportedForInstances(bytes32[] calldata) external pure returns (address[] memory a) {
        a = new address[](0);
    }

    function getAdapterPositions(address, address) external pure returns (INAVCalculator.PositionBalance[] memory) {
        return new INAVCalculator.PositionBalance[](0);
    }

    function underlyingAssetsSupported() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterBalanceForAsset(address, address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function getAdapterBalances(address) external pure returns (address[] memory, uint256[] memory, bool[] memory) {
        return (new address[](0), new uint256[](0), new bool[](0));
    }
}

/// @dev A `Balances` whose default adapter is injected, which the ordinary test harness cannot do —
///      `_setErc20DefaultBalanceAdapter` is set-once and the harness spends it on a real adapter.
contract InjectedDefaultHarness is Balances {
    constructor(address dflt) initializer {
        __Balances_init();
        _setErc20DefaultBalanceAdapter(dflt);
    }

    function addMetaDirect(address adapter, bytes32[] memory instances) public {
        _addMetaBalanceAdapter(adapter, instances);
    }

    function removeMetaInstancesDirect(address adapter, bytes32[] memory instances) public {
        _removeMetaInstances(adapter, instances);
    }

    function getRegisteredAssets() external pure returns (INAVCalculator.Asset[] memory a) {
        a = new INAVCalculator.Asset[](0);
    }
}

/// @title `_reincludeIfAsset` is metered
/// @author KPK
/// @notice A starved re-include must RAISE, not be swallowed as "the coordinate is not a registered asset".
/// @dev The fail-open in `NAVRegistryLib._reincludeIfAsset` exists to absorb one expected outcome:
///      `addSupportedAsset` reverting `AssetNotFound` for a coordinate that is not a registered asset. A bare
///      `catch {}` could not tell that from an out-of-gas, so on `removeBalanceAdapters` over a large set a
///      late coordinate could be released from the meta adapter AND not re-armed on the default one —
///      governed by nobody, with no health flag, which is the outcome the function exists to prevent. The
///      direction being an under-report is not a reason to leave it undetectable.
contract ReincludeGasMeteringTest is Test {
    InjectedDefaultHarness internal balances;
    MinimalMetaAdapter internal meta;
    address internal constant TOKEN = address(0xBEEF);

    function setUp() public {
        // `NAVRegistryLib` is pre-linked at a deterministic CREATE2 address (foundry.toml), which has no code
        // in a unit test, so every DELEGATECALL into it reverts "unlinked library" until it is etched there.
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);
        balances = new InjectedDefaultHarness(address(new GasBurningDefaultAdapter()));
        meta = new MinimalMetaAdapter();
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    /// @notice Releasing a coordinate whose re-include starves reverts `DefaultAdapterReincludeGasExhausted`.
    /// @dev Fails with the metering reverted: the burner's out-of-gas is absorbed by the bare catch and
    ///      `removeMetaInstances` returns successfully, leaving the token governed by nobody.
    function test_starvedReinclude_raisesInsteadOfBeingSwallowed() public {
        bytes32 coord = bytes32(uint256(uint160(TOKEN)));
        // Registration claims the coordinate, which calls `_excludeIfAsset` on the burner — that is
        // `removeSupportedAsset`, a no-op here, so registration itself is unaffected.
        balances.addMetaDirect(address(meta), _one(coord));

        // Release. `_release` -> `_reincludeIfAsset` -> the burner -> starvation, which must surface.
        vm.expectPartialRevert(IBalances.DefaultAdapterReincludeGasExhausted.selector);
        balances.removeMetaInstancesDirect(address(meta), _one(coord));
    }
}
