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
    mapping(address account => uint256) public lastReplaced;

    constructor(address admin, address assistant) AssistedBalanceAdapter(admin, assistant) {}

    function submit(uint256 value) external onlyRole(ASSISTANT_ROLE) {
        lastSubmitted = value;
    }

    /// @notice Friendly typed wrapper over the base's shared {_submit} orchestration (mirrors how the real adapters
    ///         expose `submitTokenIds` etc.). Routes through the access-control-gated, account-checked chokepoint.
    function submitReplace(address account, uint256 value) external onlyRole(ASSISTANT_ROLE) {
        _submit(account, abi.encode(value));
    }

    function submitReplaceBatch(address[] calldata accounts, uint256[] calldata values)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        bytes[] memory data = new bytes[](values.length);
        for (uint256 i; i < values.length; ++i) {
            data[i] = abi.encode(values[i]);
        }
        _submitBatch(accounts, data);
    }

    /// @inheritdoc AssistedBalanceAdapter
    function _applyReplace(address account, bytes memory data) internal override {
        lastReplaced[account] = abi.decode(data, (uint256));
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

    // No supportsInterface override needed — the base advertises IBalanceAdapter, so this minimal concrete
    // (which implements no IPositionDescribable) registers as-is.
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

    // ---- Shared _submit / _submitBatch orchestration (base) ----

    function test_Submit_RoutesThroughChokepoint() public {
        vm.prank(assistant);
        adapter.submitReplace(makeAddr("acct"), 123);
        assertEq(adapter.lastReplaced(makeAddr("acct")), 123);
    }

    function test_Submit_RevertsOnZeroAccount() public {
        vm.expectRevert(InvalidArguments.selector);
        vm.prank(assistant);
        adapter.submitReplace(address(0), 1);
    }

    function test_Submit_OnlyAssistant() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ASSISTANT_ROLE)
        );
        vm.prank(stranger);
        adapter.submitReplace(makeAddr("acct"), 1);
    }

    function test_SubmitBatch_ReplacesEachAccount() public {
        address[] memory accounts = new address[](2);
        uint256[] memory values = new uint256[](2);
        accounts[0] = makeAddr("a");
        values[0] = 10;
        accounts[1] = makeAddr("b");
        values[1] = 20;
        vm.prank(assistant);
        adapter.submitReplaceBatch(accounts, values);
        assertEq(adapter.lastReplaced(makeAddr("a")), 10);
        assertEq(adapter.lastReplaced(makeAddr("b")), 20);
    }

    function test_SubmitBatch_RevertsOnLengthMismatch() public {
        address[] memory accounts = new address[](2);
        uint256[] memory values = new uint256[](1);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vm.prank(assistant);
        adapter.submitReplaceBatch(accounts, values);
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
