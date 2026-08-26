// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {console2} from "forge-std/console2.sol";

interface INavAdmin {
    function getAllAdapters() external view returns (address[] memory);
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function addBalanceAdapters(address[] calldata adapters) external;
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function removeBalanceAdapters(address[] calldata adapters) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title AdapterSwapParity — replacing a balance adapter must not move NAV
/// @notice Takes every adapter the live NAV currently has registered, swaps it for an identical twin at a new
///         address, and asserts each adapter's own NAV contribution is bit-identical across the swap.
/// @dev **Why this exists.** Adapters are registered on the NAV by ADDRESS, and a meta-adapter's queried
///      instance set is stored against that same address — so it does NOT follow the adapter across a redeploy.
///      The dangerous failure when re-addressing an adapter is therefore not a wrong address (that reverts
///      loudly or reads as unregistered) but a **lost instance set**: re-register with an empty or partial set
///      and NAV silently drops those positions while every address check still passes. Comparing the
///      contribution across the swap is the only assertion that catches it.
///
///      **Order is load-bearing: remove FIRST, then re-register.** The reverse leaves both adapters registered
///      at once and, because they report the SAME positions, NAV double-counts them — an over-report.
///      Remove-first instead leaves a window where the positions are absent: an under-report, the direction
///      this codebase requires whenever it must pick one.
///
///      **Deliberately discovers adapters from `getAllAdapters()` rather than hard-coding them.** An earlier
///      version pinned the nine pre-migration addresses and so invalidated itself the moment the migration it
///      was guarding actually landed — the addresses stopped being registered and the swap reverted. Reading
///      the live set keeps this a standing regression test for any future re-addressing, not a one-shot.
///
///      Uses `getAccountNavForAdapters`, not `getAccountNav`: a complete mainnet read exceeds one `eth_call`
///      and reverts. Slicing to one adapter is also sharper — it isolates the contribution instead of hiding
///      it inside a total where an offsetting error could cancel out.
contract AdapterSwapParityForkTest is BalanceAdapterTestBase {
    address constant NAV_ADDR = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant MANAGER_HOLDER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    bytes32 constant MANAGER = keccak256("MANAGER");

    /// @dev Meta-adapters only: a plain adapter has no instance set, so it cannot exhibit the failure this
    ///      test is for, and swapping all 29 would cost far more fork time for no extra coverage.
    uint256 constant MAX_ADAPTERS = 12;

    INavAdmin nav = INavAdmin(NAV_ADDR);

    function testSwapPreservesEachAdapterContribution() public {
        vm.selectFork(createForkWithCadence(getAlchemyUrl("eth-mainnet")));

        // FAIL rather than skip. This fork tracks the latest block, so a role rotation is not hypothetical,
        // and returning early here would have made the whole test pass while exercising no swap at all —
        // coverage disappearing silently at exactly the moment the setup needs attention. A red test says
        // "update the holder"; a green one says nothing.
        assertTrue(
            nav.hasRole(MANAGER, MANAGER_HOLDER),
            "MANAGER holder rotated - update MANAGER_HOLDER (or impersonate the current one) to keep this test meaningful"
        );

        address[] memory accounts = new address[](2);
        accounts[0] = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b; // ACCOUNT_2 (~$933k)
        accounts[1] = 0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6; // ACCOUNT_1 (multi-protocol dust)

        address[] memory all = nav.getAllAdapters();
        uint256 checked;
        uint256 carried;
        uint256 nonZero;

        for (uint256 i; i < all.length && checked < MAX_ADAPTERS; ++i) {
            address old = all[i];
            bytes32[] memory instances = nav.getMetaInstances(old);
            if (instances.length == 0) continue; // plain adapter — nothing to lose
            ++checked;

            int256[] memory pre = new int256[](accounts.length);
            for (uint256 a; a < accounts.length; ++a) {
                pre[a] = _sliceNav(accounts[a], old);
                if (pre[a] != 0) ++nonZero;
            }

            address twin = _clone(old);
            address[] memory one = new address[](1);
            one[0] = old;

            vm.startPrank(MANAGER_HOLDER);
            nav.removeBalanceAdapters(one);
            nav.addMetaBalanceAdapter(twin, instances);
            vm.stopPrank();
            carried += instances.length;

            assertEq(nav.getMetaInstances(twin).length, instances.length, "instance set not carried");
            for (uint256 a; a < accounts.length; ++a) {
                assertEq(_sliceNav(accounts[a], twin), pre[a], "adapter contribution changed across the swap");
            }
        }

        console2.log("meta-adapters swapped:", checked);
        console2.log("instances carried:", carried);
        console2.log("non-zero contributions compared:", nonZero);
        assertGt(checked, 0, "no meta-adapters found - the test proved nothing");
        assertGt(carried, 0, "no instance sets carried - the test proved nothing");
    }

    /// @dev Returndata is [offset][value][...]; word 1 is `PartialNAV.value`, an int256 in the struct head.
    function _sliceNav(address account, address adapter) internal view returns (int256) {
        address[] memory one = new address[](1);
        one[0] = adapter;
        (bool ok, bytes memory ret) = NAV_ADDR.staticcall(
            abi.encodeWithSignature("getAccountNavForAdapters(address,address,address[])", account, address(0), one)
        );
        require(ok, "slice read reverted");
        bytes memory w = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            w[i] = ret[32 + i];
        }
        return abi.decode(w, (int256));
    }

    /// @dev Copies an adapter's runtime code to a fresh address. These adapters are immutable and pin the NAV in
    ///      an immutable, which lives in the runtime code, so a code copy behaves identically to redeploying the
    ///      same creation code with the same constructor argument.
    function _clone(address src) internal returns (address twin) {
        twin = address(uint160(uint256(keccak256(abi.encodePacked("twin", src)))));
        vm.etch(twin, src.code);
    }
}
