// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {EtherFiWithdrawalQueueWrapper} from "src/balances/wrappers/EtherFiWithdrawalQueueWrapper.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    IEtherFiWithdrawRequestNFT
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {NotAContract} from "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Mock of ether.fi's WithdrawRequestNFT with a working owner-only `claimWithdraw` that pays the owner ETH.
contract MockClaimNFT {
    mapping(uint256 => address) public ownerOfId;
    mapping(uint256 => IEtherFiWithdrawRequestNFT.WithdrawRequest) private _req;
    mapping(uint256 => uint256) public claimable;
    uint256 public nextId;
    uint256 public lastClaimed;

    /// @dev Mints a finalized request worth `amount` ETH to `to` (mirrors LiquidityPool.requestWithdraw minting).
    function mint(address to, uint256 amount) external returns (uint256 id) {
        id = ++nextId;
        ownerOfId[id] = to;
        _req[id] = IEtherFiWithdrawRequestNFT.WithdrawRequest(uint96(amount), uint96(amount), true, 0);
        claimable[id] = amount;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = ownerOfId[id];
        require(o != address(0), "nonexistent");
    }

    function getRequest(uint256 id) external view returns (IEtherFiWithdrawRequestNFT.WithdrawRequest memory) {
        return _req[id];
    }

    function getClaimableAmount(uint256 id) external view returns (uint256) {
        return claimable[id];
    }

    function isFinalized(uint256) external pure returns (bool) {
        return true;
    }

    function isValid(uint256 id) external view returns (bool) {
        return _req[id].isValid;
    }

    /// @dev Owner-only claim: requires `ownerOf(id) == msg.sender` (approvals ignored), burns, sends ETH to the owner.
    function claimWithdraw(uint256 id) external {
        require(ownerOfId[id] == msg.sender, "Not the owner of the NFT");
        uint256 amt = claimable[id];
        delete ownerOfId[id]; // burn
        lastClaimed = id;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "eth send failed");
    }

    receive() external payable {}
}

/// @notice Mock of ether.fi's LiquidityPool: pulls eETH from the caller (`msg.sender`) and mints a WithdrawRequestNFT
///         to `recipient`. Under the wrapper's delegatecalled `requestWithdraw`, `msg.sender` here is the Safe.
contract MockLiquidityPool {
    IERC20 public immutable eeth;
    MockClaimNFT public immutable nft;

    constructor(IERC20 eeth_, MockClaimNFT nft_) {
        eeth = eeth_;
        nft = nft_;
    }

    function requestWithdraw(address recipient, uint256 amount) external returns (uint256) {
        eeth.transferFrom(msg.sender, address(this), amount);
        return nft.mint(recipient, amount);
    }
}

/// @notice Minimal smart-account mock that DELEGATECALLs the wrapper's `requestWithdraw` / `claimWithdraw` (so the
///         wrapper's code runs in this account's context — `msg.sender` seen by ether.fi is this Safe), and can
///         receive ETH. Stands in for a karpatkey Safe/Avatar.
contract MockSafe {
    function doRequestDelegate(address wrapper, uint256 amount) external returns (uint256) {
        (bool ok, bytes memory ret) = wrapper.delegatecall(abi.encodeWithSignature("requestWithdraw(uint256)", amount));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    function doClaimDelegate(address wrapper, uint256 tokenId) external {
        (bool ok, bytes memory ret) = wrapper.delegatecall(abi.encodeWithSignature("claimWithdraw(uint256)", tokenId));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {}
}

/// @title EtherFiWithdrawalQueueWrapper unit tests
contract EtherFiWithdrawalQueueWrapperTest is Test {
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    Mock_ERC20 eeth;
    MockClaimNFT nft;
    MockLiquidityPool lp;
    BalancesHarness balances;
    EtherFiWithdrawalQueueAssistedBalanceAdapter adapter;
    EtherFiWithdrawalQueueWrapper wrapper;
    MockSafe safe;

    function setUp() public {
        eeth = new Mock_ERC20("eETH", 18);
        nft = new MockClaimNFT();
        lp = new MockLiquidityPool(IERC20(address(eeth)), nft);
        balances = new BalancesHarness();
        balances.addSupportedAssetForTest(NATIVE);

        // Adapter first (wrapper unknown at construction) → deploy wrapper → grant WRAPPER_ROLE to the wrapper.
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(this), address(0)
        );
        wrapper = new EtherFiWithdrawalQueueWrapper(address(adapter), address(lp), address(nft), address(eeth));
        adapter.grantRole(adapter.WRAPPER_ROLE(), address(wrapper));

        safe = new MockSafe();

        // The Safe holds eETH; the delegatecalled requestWithdraw approves the LiquidityPool from the Safe itself, so
        // no pre-approval to the wrapper is needed. Fund the NFT so it can pay out claims.
        eeth.mint(address(safe), 100 ether);
        vm.deal(address(nft), 100 ether);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroArg() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueWrapper(address(0), address(lp), address(nft), address(eeth));
    }

    function test_constructor_revertsWhenAdapterNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "adapter"));
        new EtherFiWithdrawalQueueWrapper(makeAddr("eoa"), address(lp), address(nft), address(eeth));
    }

    // ---- requestWithdraw (DELEGATECALL by the owning Safe) ----

    function test_requestWithdraw_delegatecall_pullsEethFromSafe_mintsToSafe_andTracks() public {
        uint256 amount = 5 ether;
        uint256 id = safe.doRequestDelegate(address(wrapper), amount);

        assertEq(nft.ownerOf(id), address(safe), "NFT minted to the Safe");
        assertEq(eeth.balanceOf(address(safe)), 95 ether, "eETH pulled directly from the Safe");
        assertEq(eeth.balanceOf(address(lp)), amount, "eETH landed in the LiquidityPool");

        uint256[] memory ids = adapter.tokenIdsOf(address(safe));
        assertEq(ids.length, 1);
        assertEq(ids[0], id, "requestId tracked for the Safe");
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE);
        assertEq(owed, amount, "adapter values the tracked request");
    }

    /// @notice A direct CALL to requestWithdraw reverts `NotDelegateCall` (the onlyDelegateCall guard) — it must be
    ///         delegatecalled by the Safe.
    function test_requestWithdraw_directCall_reverts() public {
        vm.expectRevert(NotDelegateCall.selector);
        wrapper.requestWithdraw(5 ether);
    }

    // ---- claimWithdraw (DELEGATECALL by the owning Safe) ----

    function test_claimWithdraw_delegatecall_paysSafe_andPrunes() public {
        uint256 amount = 5 ether;
        uint256 id = safe.doRequestDelegate(address(wrapper), amount);
        assertEq(adapter.tokenIdsOf(address(safe)).length, 1);

        uint256 safeEthBefore = address(safe).balance;
        safe.doClaimDelegate(address(wrapper), id);

        assertEq(nft.lastClaimed(), id, "NFT.claimWithdraw was invoked");
        assertEq(address(safe).balance, safeEthBefore + amount, "ETH paid to the Safe");
        vm.expectRevert("nonexistent");
        nft.ownerOf(id); // burned
        assertEq(adapter.tokenIdsOf(address(safe)).length, 0, "claimed id pruned from the adapter cache");
    }

    /// @notice A direct CALL to claimWithdraw reverts `NotDelegateCall` (the onlyDelegateCall guard fires before the
    ///         NFT owner check) — it must be delegatecalled by the Safe.
    function test_claimWithdraw_directCall_reverts() public {
        uint256 id = safe.doRequestDelegate(address(wrapper), 5 ether);
        vm.expectRevert(NotDelegateCall.selector);
        wrapper.claimWithdraw(id);
    }

    /// @notice remove forwards to the adapter AS the wrapper (which holds WRAPPER_ROLE), keyed to msg.sender; the
    ///         adapter requires the id still belongs to the caller. Standalone untrack path (also used by
    ///         claimWithdraw via the SELF self-call, before the burn).
    function test_remove_forwardsAsWrapper() public {
        uint256 id = safe.doRequestDelegate(address(wrapper), 5 ether); // Safe owns the request
        assertEq(adapter.tokenIdsOf(address(safe)).length, 1);
        vm.prank(address(safe));
        wrapper.remove(id); // owned → untracks
        assertEq(adapter.tokenIdsOf(address(safe)).length, 0, "owned id untracked via the wrapper");
    }

    /// @notice submit forwards to the adapter AS the wrapper, keyed to msg.sender — a caller registers only its own
    ///         owned ids (also used by requestWithdraw via the SELF self-call).
    function test_submit_forwardsAsWrapper() public {
        uint256 id = nft.mint(address(safe), 3 ether); // Safe owns a request minted outside the wrapper
        vm.prank(address(safe));
        wrapper.submit(id);
        uint256[] memory ids = adapter.tokenIdsOf(address(safe));
        assertEq(ids.length, 1);
        assertEq(ids[0], id, "id registered for the Safe via the wrapper");
    }
}
