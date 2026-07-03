// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {InvalidArguments, NotAContract} from "src/errors.sol";

/// @notice Minimal mock of Stader's UserWithdrawalManager for the plain (on-chain-enumerating) adapter.
/// @dev Models the two reads the adapter uses: `getRequestIdsByUser(owner)` (the live, claim-pruned id array) and the
///      `userWithdrawRequests(id)` public mapping getter. `addRequest` records a request AND appends its id to the
///      owner's enumeration, mirroring Stader's `requestWithdraw`.
contract MockUserWithdrawalManager {
    struct Info {
        address owner;
        uint256 ethXAmount;
        uint256 ethExpected;
        uint256 ethFinalized;
        uint256 requestBlock;
    }

    mapping(uint256 => Info) public userWithdrawRequests;
    mapping(address => uint256[]) private _ids;

    /// @notice The StaderConfig the adapter derives the StakePoolManager from (auto-getter matches `staderConfig()`).
    address public staderConfig;

    function setStaderConfig(address config) external {
        staderConfig = config;
    }

    function getRequestIdsByUser(address owner) external view returns (uint256[] memory) {
        return _ids[owner];
    }

    /// @dev Record a request owned by `owner` and append it to `owner`'s enumeration (as `requestWithdraw` would).
    function addRequest(address owner, uint256 id, uint256 ethExpected, uint256 ethFinalized) external {
        userWithdrawRequests[id] = Info(owner, 1e18, ethExpected, ethFinalized, 0);
        _ids[owner].push(id);
    }

    /// @dev Append `id` to `arrayOwner`'s enumeration but record the request under a DIFFERENT on-chain owner — models
    ///      an inconsistency the adapter must defend against by re-checking `owner == account` per request.
    function addForeignRequest(address arrayOwner, uint256 id, address infoOwner, uint256 ethExpected) external {
        userWithdrawRequests[id] = Info(infoOwner, 1e18, ethExpected, 0, 0);
        _ids[arrayOwner].push(id);
    }

    /// @dev Append `count` pending requests to `owner`'s enumeration (to exercise the read cap).
    function bloat(address owner, uint256 count, uint256 ethExpectedEach) external {
        uint256 next = _ids[owner].length + 1;
        for (uint256 i; i < count; i++) {
            uint256 id = next + i;
            userWithdrawRequests[id] = Info(owner, 1e18, ethExpectedEach, 0, 0);
            _ids[owner].push(id);
        }
    }
}

/// @notice Mock StaderStakePoolManager — `previewWithdraw` returns a settable value (the live ETHx→ETH re-conversion).
///         Default `type(uint256).max` so the pending cap `min(ethExpected, preview)` never bites (picks ethExpected),
///         keeping the non-cap tests unaffected; a test lowers it to exercise the cap.
contract MockStaderStakePoolManager {
    uint256 public previewReturn = type(uint256).max;
    bool public shouldRevert;

    function setPreviewReturn(uint256 v) external {
        previewReturn = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function previewWithdraw(uint256) external view returns (uint256) {
        require(!shouldRevert, "preview revert");
        return previewReturn;
    }
}

/// @notice Mock StaderConfig — only the getter the adapter derives the StakePoolManager from.
contract MockStaderConfig {
    address public stakePoolManager;

    constructor(address spm) {
        stakePoolManager = spm;
    }

    function getStakePoolManager() external view returns (address) {
        return stakePoolManager;
    }
}

/// @title StaderWithdrawalQueueBalanceAdapter unit tests (plain, on-chain enumeration via getRequestIdsByUser)
contract StaderWithdrawalQueueBalanceAdapterTest is BalanceAdapterTestBase {
    StaderWithdrawalQueueBalanceAdapter public adapter;
    MockUserWithdrawalManager public manager;
    MockStaderStakePoolManager public spm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        manager = new MockUserWithdrawalManager();
        spm = new MockStaderStakePoolManager();
        manager.setStaderConfig(address(new MockStaderConfig(address(spm))));
        adapter = new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceAdapter(address(0), address(weth), address(balances));
    }

    function test_constructor_revertsWhenManagerNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "UserWithdrawalManager"));
        new StaderWithdrawalQueueBalanceAdapter(makeAddr("eoa"), address(weth), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceAdapter(address(manager), address(0), address(balances));
    }

    function test_constructor_revertsWhenNavNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), makeAddr("eoa"));
    }

    function test_immutables() public view {
        assertEq(address(adapter.USER_WITHDRAWAL_MANAGER()), address(manager));
        assertEq(adapter.UNDERLYING_TOKEN(), address(weth));
    }

    // ---- Balances ----

    function test_noRequests_reportsZero() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 0);
        assertEq(isDebt, false);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_zeroAccount_reportsZero() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    function test_pendingRequest_valuedAtEthExpected_locked() public {
        manager.addRequest(holder, 8196, 5 ether, 0); // pending: ethFinalized == 0

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 5 ether);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 5 ether);
        assertEq(p[0].isDebt, false);
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied));
        assertEq(p[0].isLocked, true, "pending => locked");
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].protocolId, ProtocolIds.STADER);
        assertEq(p[0].protocolSubId, ProtocolIds.STADER_WITHDRAWAL);
        assertEq(p[0].positionId, abi.encode(address(manager)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(8196)));
    }

    /// @notice A pending request is capped at the LIVE re-conversion when the ETHx/ETH rate has dropped below the
    ///         request-time estimate: owed = min(ethExpected, previewWithdraw(ethXAmount)). When the live value is
    ///         higher, the (lower) request-time estimate stands — never an over-report.
    function test_pendingRequest_cappedByLiveRate() public {
        manager.addRequest(holder, 8196, 5 ether, 0); // pending, ethExpected 5e18 (mock ethXAmount 1e18)

        spm.setPreviewReturn(3 ether); // live re-conversion dropped below the request-time estimate
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 3 ether, "pending capped at the live value on a rate drop");

        spm.setPreviewReturn(9 ether); // live value above the estimate → estimate retained
        (amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 5 ether, "request-time estimate retained when the live value is higher");
    }

    /// @notice If the live re-conversion reverts, the pending value fails open to the request-time estimate.
    function test_pendingRequest_liveRevert_failsOpenToEstimate() public {
        manager.addRequest(holder, 8196, 5 ether, 0);
        spm.setShouldRevert(true);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 5 ether, "falls back to ethExpected when previewWithdraw reverts");
    }

    function test_finalizedRequest_valuedAtEthFinalized_notLocked() public {
        manager.addRequest(holder, 8197, 5 ether, 3 ether); // finalized: exact ethFinalized takes precedence

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 3 ether, "finalized uses ethFinalized, not ethExpected");

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 3 ether);
        assertEq(p[0].isLocked, false, "finalized => claimable");
    }

    function test_multipleRequests_summedAndOnePerLeg() public {
        manager.addRequest(holder, 1, 5 ether, 0); // pending
        manager.addRequest(holder, 2, 0, 3 ether); // finalized

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 8 ether);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
    }

    function test_wrongAsset_reportsZero() public {
        manager.addRequest(holder, 1, 5 ether, 0);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(usdc));
        assertEq(amount, 0);
    }

    function test_assetFilterMismatch_noPositions() public {
        manager.addRequest(holder, 1, 5 ether, 0);
        assertEq(adapter.getAdapterPositions(holder, address(usdc)).length, 0);
    }

    /// @notice Defensive: a request in the account's enumeration whose on-chain owner is someone else contributes 0.
    function test_foreignOwnedRequest_contributesZero() public {
        manager.addForeignRequest(holder, 9, other, 5 ether);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    /// @notice There is no adapter-level cap: a large live-request list is read in full (every request contributes its
    ///         real, claimable value). A griefed queue makes the read expensive but never zeroes a real balance — see the
    ///         contract NatSpec / docs/operations/stader-withdrawal-queue-griefing.md.
    function test_largeList_readInFull() public {
        manager.bloat(holder, 600, 1 ether); // well beyond the old 500 cap and toward Stader's 1000 ceiling
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amount, 600 ether, "every request is summed, not skipped");
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 600, "one leg per request");
    }

    // ---- IPositionDescribable / ERC165 ----

    function test_protocolName() public view {
        assertEq(adapter.protocolName(), "Stader");
    }

    function test_positionLabels() public view {
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 2);
        assertEq(labels[0], "Withdrawal Queue");
        assertEq(labels[1], "ETHx");
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
    }
}
