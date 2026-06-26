// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal concrete to exercise the abstract base: trivial IBalanceAdapter impl plus an assistant-gated
///         mutator that flips a flag, so we can assert the role actually gates submission.
contract MockAssistedAdapter is AssistedBalanceAdapter {
    uint256 public lastSubmitted;

    constructor(address admin, address assistant) AssistedBalanceAdapter(admin, assistant) {}

    function submit(uint256 value) external onlyRole(ASSISTANT_ROLE) {
        lastSubmitted = value;
    }

    function getAdapterPositions(address, address) external pure returns (INAVCalculator.PositionBalance[] memory) {
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address) external pure returns (address[] memory, uint256[] memory, bool[] memory) {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure returns (address[] memory) {
        return new address[](0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AssistedBalanceAdapter) returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract AssistedBalanceAdapterTest is Test {
    MockAssistedAdapter internal adapter;

    address internal admin = makeAddr("admin");
    address internal assistant = makeAddr("assistant");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant ASSISTANT_ROLE = keccak256("ASSISTANT_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        adapter = new MockAssistedAdapter(admin, assistant);
    }

    function test_Constructor_GrantsRoles() public view {
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin missing DEFAULT_ADMIN_ROLE");
        assertTrue(adapter.hasRole(ASSISTANT_ROLE, assistant), "assistant missing ASSISTANT_ROLE");
        assertFalse(adapter.hasRole(ASSISTANT_ROLE, admin), "admin should not auto-hold ASSISTANT_ROLE");
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(InvalidArguments.selector);
        new MockAssistedAdapter(address(0), assistant);
    }

    function test_Constructor_AllowsZeroAssistant() public {
        MockAssistedAdapter a = new MockAssistedAdapter(admin, address(0));
        assertTrue(a.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertFalse(a.hasRole(ASSISTANT_ROLE, address(0)), "zero assistant must not be granted the role");
    }

    function test_AssistantRoleConstant() public view {
        assertEq(adapter.ASSISTANT_ROLE(), keccak256("ASSISTANT_ROLE"));
    }

    function test_OnlyAssistantCanSubmit() public {
        vm.prank(assistant);
        adapter.submit(42);
        assertEq(adapter.lastSubmitted(), 42);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ASSISTANT_ROLE)
        );
        vm.prank(stranger);
        adapter.submit(7);
    }

    function test_AdminGrantsAndRevokesAssistant() public {
        // admin grants a new assistant, who can then submit
        vm.prank(admin);
        adapter.grantRole(ASSISTANT_ROLE, stranger);
        vm.prank(stranger);
        adapter.submit(99);
        assertEq(adapter.lastSubmitted(), 99);

        // admin revokes; stranger can no longer submit
        vm.prank(admin);
        adapter.revokeRole(ASSISTANT_ROLE, stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ASSISTANT_ROLE)
        );
        vm.prank(stranger);
        adapter.submit(1);
    }

    function test_NonAdminCannotGrant() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, assistant, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(assistant);
        adapter.grantRole(ASSISTANT_ROLE, stranger);
    }

    function test_SupportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId), "IAssistedBalanceAdapter");
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId), "IBalanceAdapter");
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl");
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(adapter.supportsInterface(0xffffffff), "must reject 0xffffffff");
        assertFalse(adapter.supportsInterface(0x12345678), "must reject an unrelated interfaceId");
    }
}
