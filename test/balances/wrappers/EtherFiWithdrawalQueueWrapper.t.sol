// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {EtherFiWithdrawalQueueWrapper} from "src/balances/wrappers/EtherFiWithdrawalQueueWrapper.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {IEtherFiWithdrawRequestNFT} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalValuationBase.sol";
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

/// @notice Mock of ether.fi's LiquidityPool: pulls eETH from the caller and mints a WithdrawRequestNFT to `recipient`.
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

/// @notice Minimal smart-account mock that both CALLs `requestWithdraw` and DELEGATECALLs `claimWithdraw` on the
///         wrapper, and can receive ETH. Stands in for a karpatkey Safe/Avatar.
contract MockSafe {
    function approveEETH(IERC20 eeth, address spender, uint256 amount) external {
        eeth.approve(spender, amount);
    }

    function doRequest(address wrapper, address recipient, uint256 amount) external returns (uint256) {
        return EtherFiWithdrawalQueueWrapper(wrapper).requestWithdraw(recipient, amount);
    }

    /// @dev Executes the wrapper's claim in THIS account's context, so the NFT sees msg.sender == this Safe (== owner).
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
        wrapper = new EtherFiWithdrawalQueueWrapper(
            address(adapter), address(lp), address(nft), address(eeth), address(this)
        );
        adapter.grantRole(adapter.WRAPPER_ROLE(), address(wrapper));

        safe = new MockSafe();
        wrapper.grantRole(wrapper.DEPOSITOR_ROLE(), address(safe));

        // Fund the Safe with eETH and approve the wrapper; fund the NFT so it can pay out claims.
        eeth.mint(address(safe), 100 ether);
        safe.approveEETH(IERC20(address(eeth)), address(wrapper), type(uint256).max);
        vm.deal(address(nft), 100 ether);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroArg() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueWrapper(address(0), address(lp), address(nft), address(eeth), address(this));
    }

    function test_constructor_revertsWhenAdapterNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "adapter"));
        new EtherFiWithdrawalQueueWrapper(makeAddr("eoa"), address(lp), address(nft), address(eeth), address(this));
    }

    // ---- requestWithdraw (normal CALL) ----

    function test_requestWithdraw_pullsEeth_mintsToCaller_andTracks() public {
        uint256 amount = 5 ether;
        uint256 id = safe.doRequest(address(wrapper), address(safe), amount);

        assertEq(nft.ownerOf(id), address(safe), "NFT minted to the caller (Safe)");
        assertEq(eeth.balanceOf(address(safe)), 95 ether, "eETH pulled from the Safe");
        assertEq(eeth.balanceOf(address(lp)), amount, "eETH forwarded to the LiquidityPool");

        uint256[] memory ids = adapter.tokenIdsOf(address(safe));
        assertEq(ids.length, 1);
        assertEq(ids[0], id, "requestId tracked for the Safe");
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE);
        assertEq(owed, amount, "adapter values the tracked request");
    }

    function test_requestWithdraw_onlyDepositorRole() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, keccak256("DEPOSITOR_ROLE")
            )
        );
        wrapper.requestWithdraw(stranger, 1 ether);
    }

    function test_requestWithdraw_revertsWhenRecipientNotCaller() public {
        vm.expectRevert(InvalidArguments.selector);
        // Safe (DEPOSITOR) requests but names a different recipient → reverts.
        safe.doRequest(address(wrapper), makeAddr("someoneElse"), 1 ether);
    }

    // ---- claimWithdraw (DELEGATECALL by the owning Safe) ----

    function test_claimWithdraw_delegatecall_paysSafe_andPrunes() public {
        uint256 amount = 5 ether;
        uint256 id = safe.doRequest(address(wrapper), address(safe), amount);
        assertEq(adapter.tokenIdsOf(address(safe)).length, 1);

        uint256 safeEthBefore = address(safe).balance;
        safe.doClaimDelegate(address(wrapper), id);

        assertEq(nft.lastClaimed(), id, "NFT.claimWithdraw was invoked");
        assertEq(address(safe).balance, safeEthBefore + amount, "ETH paid to the Safe");
        vm.expectRevert("nonexistent");
        nft.ownerOf(id); // burned
        assertEq(adapter.tokenIdsOf(address(safe)).length, 0, "claimed id pruned from the adapter cache");
    }

    /// @notice A direct CALL to claimWithdraw by a non-owner reverts inside the NFT (owner-only) — the wrapper is not
    ///         the NFT owner, so this fails safe when invoked the wrong way.
    function test_claimWithdraw_directCall_byNonOwner_reverts() public {
        uint256 id = safe.doRequest(address(wrapper), address(safe), 5 ether);
        vm.expectRevert("Not the owner of the NFT");
        wrapper.claimWithdraw(id); // msg.sender to NFT is the wrapper, not the owner
    }
}
