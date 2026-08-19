// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface INav {
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function addBalanceAdapters(address[] calldata adapters) external;
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function removeBalanceAdapters(address[] calldata adapters) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title AdapterCreate2Swap — fork proof that the CREATE2 adapter migration is NAV-neutral
/// @notice For every NAV-only balance adapter on mainnet, replaces it with an identical twin and asserts that
///         the adapter's own NAV contribution is bit-identical before and after.
/// @dev **What this guards, and why an address check would not.** These adapters are live and registered. The
///      NAV keys its adapter set — and each meta-adapter's INSTANCE set — by adapter address, so migrating one
///      is remove-then-re-register, not an in-place swap. The dangerous failure is therefore not a wrong
///      address (that reverts loudly or reads as unregistered); it is a LOST INSTANCE SET. Re-register a
///      meta-adapter with an empty or partial set and the NAV silently drops those positions while every
///      address assertion still passes. Comparing the contribution across the swap is the only check that sees
///      it, which is why this test exists.
///
///      **The swap order is load-bearing.** `removeBalanceAdapters` runs FIRST. The reverse order leaves the
///      old and new adapter both registered at once and, since they report the SAME positions, the NAV
///      double-counts them — an over-report. Remove-first instead leaves a window where those positions are
///      absent: an under-report, the direction this codebase requires whenever it must pick one.
///
///      **Why the per-adapter read rather than `getAccountNav`.** A complete mainnet read exceeds a single
///      `eth_call` (~30M gas) and reverts, which is why `getAccountNavForAdapters` exists. Slicing to the one
///      adapter under test is both cheaper and sharper: it isolates the adapter's contribution instead of
///      hiding it inside a fleet total where an offsetting error could cancel out.
contract AdapterCreate2SwapForkTest is Test {
    INav constant NAV = INav(0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214);
    address constant MANAGER_HOLDER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    bytes32 constant MANAGER = keccak256("MANAGER");

    function testSwapPreservesEachAdapterContribution() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        assertTrue(NAV.hasRole(MANAGER, MANAGER_HOLDER), "assumed MANAGER holder lost the role");

        address[] memory accounts = new address[](3);
        accounts[0] = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b; // ACCOUNT_2 (~$933k)
        accounts[1] = 0x13CE0c26a44c644cCeb29b1E5b437521095F86df; // ACCOUNT_4_UMBRELLA
        accounts[2] = 0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6; // ACCOUNT_1 (multi-protocol dust)

        address[] memory olds = new address[](9);
        olds[0] = 0xc88f983FC38a415d7d708F12F2B8606FdDbD6614; // AaveV3InstancesMeta
        olds[1] = 0xF965821a68f2A86C2436127c05c8B73D6071df85; // AaveV3SafetyModule
        olds[2] = 0xe1E960efA5eC39eFe660bb029d70f1Cfd691A2e5; // BalancerV3PoolsMeta
        olds[3] = 0xEb00A71347ae40ac73675B84B79A9EE36Eb3D992; // CurvePoolsMeta
        olds[4] = 0x3956f81Ee3Cc9E7cd84ce202F4F6B19BabB1bD06; // EulerVaultsMeta
        olds[5] = 0xD67599377DB7A4e0b785AB0582afA45f78f2413C; // FluidFTokensMeta
        olds[6] = 0xd52DdbEaE7927CAb3031A33795aDBd99743F5Db9; // GearboxV3MarketsMeta
        olds[7] = 0x5867831c24E0d46E78C4df09e098d730B7281eEA; // MorphoVaultsMeta
        olds[8] = 0xa2B7EEacD06C674Dda300F0206778a7574EC786D; // SymbioticVaultsMeta

        uint256 carried;
        uint256 nonZero;

        for (uint256 i; i < olds.length; ++i) {
            address old = olds[i];

            int256[] memory pre = new int256[](accounts.length);
            for (uint256 a; a < accounts.length; ++a) {
                pre[a] = _sliceNav(accounts[a], old);
                if (pre[a] != 0) ++nonZero;
            }

            bytes32[] memory instances = NAV.getMetaInstances(old);
            address twin = _clone(old);

            address[] memory one = new address[](1);
            one[0] = old;

            vm.startPrank(MANAGER_HOLDER);
            NAV.removeBalanceAdapters(one);
            if (instances.length > 0) {
                NAV.addMetaBalanceAdapter(twin, instances);
                carried += instances.length;
            } else {
                address[] memory add = new address[](1);
                add[0] = twin;
                NAV.addBalanceAdapters(add);
            }
            vm.stopPrank();

            for (uint256 a; a < accounts.length; ++a) {
                assertEq(_sliceNav(accounts[a], twin), pre[a], "adapter contribution changed across the swap");
            }
            console2.log("adapter ok, instances carried:", instances.length);
        }

        console2.log("total instances carried:", carried);
        console2.log("non-zero contributions compared:", nonZero);
        assertGt(carried, 0, "no instance sets were carried - the test proved nothing");
        assertGt(nonZero, 0, "every contribution was zero - the test proved nothing");
    }

    /// @dev First word of the struct body is `PartialNAV.value` (an int256, so it sits in the head).
    ///      Returndata is [offset][value][...]; word index 1 is the value.
    function _sliceNav(address account, address adapter) internal view returns (int256) {
        address[] memory one = new address[](1);
        one[0] = adapter;
        (bool ok, bytes memory ret) = address(NAV)
            .staticcall(
                abi.encodeWithSignature("getAccountNavForAdapters(address,address,address[])", account, address(0), one)
            );
        require(ok, "slice read reverted");
        return abi.decode(_word(ret, 1), (int256));
    }

    function _word(bytes memory data, uint256 index) private pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            out[i] = data[index * 32 + i];
        }
    }

    /// @dev Copies an adapter's runtime code to a fresh address. These adapters are immutable and hold their NAV
    ///      pointer in an immutable, which lives in the runtime code — so a code copy behaves identically to
    ///      redeploying the same creation code with the same constructor argument. The real address derivation is
    ///      pinned separately by `cast create2`; this test is about the registration handover.
    function _clone(address src) internal returns (address twin) {
        twin = address(uint160(uint256(keccak256(abi.encodePacked("twin", src)))));
        vm.etch(twin, src.code);
    }
}
