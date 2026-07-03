// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssistantSafeRolesForkBase} from "test/utils/AssistantSafeRolesForkBase.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol";

/// @title EtherFiWithdrawalQueueAssistant — Safe + Zodiac Roles integration (happy path)
/// @notice End-to-end proof that the delegatecall path works through the real ops stack: the manager Safe, as a member
///         of a Roles role permitting a DELEGATECALL to the assistant, calls `execTransactionWithRole`; the Roles
///         modifier makes the **avatar Safe** delegatecall `EtherFiWithdrawalQueueAssistant.requestWithdraw`, which
///         spends the avatar's eETH, mints the WithdrawRequestNFT to the avatar, and records it on the adapter.
contract EtherFiWithdrawalQueueAssistantSafeRolesForkTest is AssistantSafeRolesForkBase {
    address public constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address public constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    /// @dev weETH wrapper holds ~1.7M eETH at FORK_BLOCK — the real eETH source for funding the avatar Safe.
    address public constant EETH_WHALE = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    uint256 public constant FORK_BLOCK = 25_410_000;
    uint256 public constant FUND = 10 ether; // eETH transferred to the avatar Safe (rebasing → lands ~1 wei less)
    uint256 public constant WITHDRAW = 9 ether; // eETH requested via the queue (safely below the funded balance)

    EtherFiWithdrawalQueueAssistedBalanceAdapter public adapter;
    EtherFiWithdrawalQueueAssistant public assistant;

    function setUp() public override {
        super.setUp(); // invokes _setupFork()
        balances = _balancesForNativeEth();

        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances)
        );
        assistant = new EtherFiWithdrawalQueueAssistant(address(adapter), LIQUIDITY_POOL, WITHDRAW_REQUEST_NFT, EETH);

        _initManagerSafe();
        _permitDelegatecall(address(assistant));

        // Fund the avatar Safe with real eETH (rebasing — transfer from a whale rather than deal()).
        vm.prank(EETH_WHALE);
        IERC20(EETH).transfer(AVATAR_SAFE, FUND);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @notice Manager Safe → Roles `execTransactionWithRole` (DelegateCall) → avatar Safe delegatecalls the assistant's
    ///         `requestWithdraw`, entering ether.fi's queue and tracking the resulting request on the adapter.
    function test_managerSafe_viaRoles_delegatecalls_requestWithdraw() public {
        // Precondition: avatar holds eETH (≈FUND, less rebasing dust); adapter tracks nothing for it yet.
        assertGt(IERC20(EETH).balanceOf(AVATAR_SAFE), WITHDRAW, "avatar funded with eETH");
        assertEq(adapter.tokenIdsOf(AVATAR_SAFE).length, 0, "nothing tracked yet");
        (uint256 owedBefore,) = adapter.getAdapterBalanceForAsset(AVATAR_SAFE, NATIVE_ETH);
        assertEq(owedBefore, 0);

        // The manager Safe drives the avatar Safe to delegatecall the assistant through the Roles modifier.
        bytes memory data = abi.encodeCall(EtherFiWithdrawalQueueAssistant.requestWithdraw, (WITHDRAW));
        _managerDelegatecall(address(assistant), data);

        // The delegatecall executed as the avatar: a request NFT is now tracked and valued for the avatar Safe.
        uint256[] memory tracked = adapter.tokenIdsOf(AVATAR_SAFE);
        assertEq(tracked.length, 1, "one withdrawal request tracked for the avatar Safe");

        (uint256 owedAfter,) = adapter.getAdapterBalanceForAsset(AVATAR_SAFE, NATIVE_ETH);
        assertGt(owedAfter, 0, "pending withdrawal is valued (ETH owed to the avatar Safe)");
        // A fresh pending request is worth ~the eETH burned (minus any queue fee); allow a small tolerance.
        assertApproxEqRel(owedAfter, WITHDRAW, 0.01e18, "owed approximates the withdrawn eETH");
    }
}
