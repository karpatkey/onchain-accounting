// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistantSafeRolesForkBase} from "test/utils/AssistantSafeRolesForkBase.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";

/// @notice StakeWise V3 Genesis vault surface used to fund + value the avatar's position.
interface IStakeWiseVault {
    function deposit(address receiver, address referrer) external payable returns (uint256 shares);
    function getShares(address account) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @title StakeWiseV3ExitQueueAssistant — Safe + Zodiac Roles integration (happy path)
/// @notice End-to-end proof of the delegatecall path: the manager Safe, a member of a Roles role permitting a
///         DELEGATECALL to the assistant, calls `execTransactionWithRole`; the Roles modifier makes the **avatar Safe**
///         delegatecall `StakeWiseV3ExitQueueAssistant.enterExitQueue`, moving the avatar's vault shares into the exit
///         queue and recording the resulting ticket on the adapter. The avatar first deposits ETH into the Genesis
///         vault to hold shares (setup).
contract StakeWiseV3ExitQueueAssistantSafeRolesForkTest is AssistantSafeRolesForkBase {
    address public constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address public constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;

    uint256 public constant FORK_BLOCK = 25_440_928;
    uint256 public constant DEPOSIT_ETH = 10 ether; // ETH the avatar stakes into the Genesis vault (setup)

    StakeWiseV3ExitQueueAssistedBalanceAdapter public adapter;
    StakeWiseV3ExitQueueAssistant public assistant;

    function setUp() public override {
        super.setUp(); // invokes _setupFork()
        balances = _balancesForNativeEth();

        adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days
        );
        assistant = new StakeWiseV3ExitQueueAssistant(address(adapter));

        _initManagerSafe();
        _permitDelegatecall(address(assistant));

        // Setup: the avatar Safe stakes ETH into the Genesis vault so it holds vault shares to exit.
        vm.deal(AVATAR_SAFE, DEPOSIT_ETH + 1 ether);
        vm.prank(AVATAR_SAFE);
        IStakeWiseVault(GENESIS_VAULT).deposit{value: DEPOSIT_ETH}(AVATAR_SAFE, address(0));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @notice Manager Safe → Roles `execTransactionWithRole` (DelegateCall) → avatar Safe delegatecalls the assistant's
    ///         `enterExitQueue`, moving vault shares into the exit queue and tracking the ticket on the adapter.
    function test_managerSafe_viaRoles_delegatecalls_enterExitQueue() public {
        uint256 sharesToExit = IStakeWiseVault(GENESIS_VAULT).convertToShares(1 ether);

        // Precondition: avatar holds vault shares; adapter tracks no exit position yet.
        assertGt(IStakeWiseVault(GENESIS_VAULT).getShares(AVATAR_SAFE), sharesToExit, "avatar holds vault shares");
        assertEq(adapter.positionsOf(AVATAR_SAFE).length, 0, "no exit position tracked yet");

        // The manager Safe drives the avatar Safe to delegatecall the assistant through the Roles modifier.
        bytes memory data = abi.encodeCall(StakeWiseV3ExitQueueAssistant.enterExitQueue, (GENESIS_VAULT, sharesToExit));
        _managerDelegatecall(address(assistant), data);

        // The delegatecall executed as the avatar: an exit-queue position is now tracked and valued for the avatar.
        StakeWiseV3ExitQueueAssistedBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(AVATAR_SAFE);
        assertEq(cached.length, 1, "one exit position tracked for the avatar Safe");
        assertEq(cached[0].vault, GENESIS_VAULT);

        (uint256 owed,) = adapter.getAdapterBalanceForAsset(AVATAR_SAFE, NATIVE_ETH);
        assertGt(owed, 0, "queued exit is valued (ETH owed to the avatar Safe)");
        // Fully-pending exit → valued via convertToAssets(shares); allow a small tolerance.
        assertApproxEqRel(
            owed,
            IStakeWiseVault(GENESIS_VAULT).convertToAssets(sharesToExit),
            0.01e18,
            "owed approximates the exited shares"
        );
    }
}
