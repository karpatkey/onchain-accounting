// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter,
    IEtherFiWithdrawRequestNFT
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {CoordinateNotOwned, CoordinateStillLive} from "src/errors.sol";

/// @title Keeper path (ADR 0030) against the real protocols on mainnet
/// @notice Each case files a REAL holder's position that was never fed through an assistant, from a separate keeper
///         account via `submitFor`, then checks the cached read equals the cache-free `previewPositions` and the
///         values the existing per-member fork tests pin. Holders, ids and blocks are those fork tests' constants.
contract AssistedKeeperPathForkTest is BalanceAdapterTestBase {
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
    }

    function _setupFork() internal override {}

    function _assertSameLegs(INAVCalculator.PositionBalance[] memory a, INAVCalculator.PositionBalance[] memory b)
        internal
        pure
    {
        assertEq(a.length, b.length, "leg count");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].amount, b[i].amount, "amount");
            assertEq(a[i].isLocked, b[i].isLocked, "isLocked");
            assertEq(uint8(a[i].positionKind), uint8(b[i].positionKind), "kind");
            assertEq(a[i].positionId, b[i].positionId, "positionId");
            assertEq(a[i].positionInstanceId, b[i].positionInstanceId, "instance");
        }
    }

    function _one(bytes memory coord) internal pure returns (bytes memory) {
        bytes[] memory coords = new bytes[](1);
        coords[0] = coord;
        return abi.encode(coords);
    }

    // ---- ether.fi ----

    address internal constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address internal constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address internal constant EF_HOLDER = 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4;
    uint256 internal constant EF_TOKEN = 80_154;
    uint256 internal constant EF_EXPECTED = 253_077_459_762_665_832;

    function test_etherfi_keeperFilesRealRequest() public {
        vm.rollFork(25_387_000);
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        EtherFiWithdrawalQueueAssistedBalanceAdapter a = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);

        INAVCalculator.PositionBalance[] memory preview = a.previewPositions(EF_HOLDER, _one(abi.encode(EF_TOKEN)));
        vm.prank(keeper);
        a.submitFor(EF_HOLDER, abi.encode(EF_TOKEN));
        INAVCalculator.PositionBalance[] memory cached = a.getAdapterPositions(EF_HOLDER, address(0));
        _assertSameLegs(preview, cached);
        assertEq(cached[0].amount, EF_EXPECTED, "pinned value");

        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, keeper, EF_TOKEN));
        vm.prank(keeper);
        a.submitFor(keeper, abi.encode(EF_TOKEN));

        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, EF_HOLDER, EF_TOKEN));
        a.removeFor(EF_HOLDER, abi.encode(EF_TOKEN));
    }

    /// @notice The proof-of-death shape `_isDead` relies on, read from the real contract: a claimed request has its
    ///         NFT burned (`ownerOf` reverts) and its request deleted (`getRequest` returns zeros).
    function test_etherfi_claimedRequestShape() public {
        vm.rollFork(25_387_000);
        IEtherFiWithdrawRequestNFT nft = IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT);
        vm.expectRevert();
        nft.ownerOf(1000);
        IEtherFiWithdrawRequestNFT.WithdrawRequest memory r = nft.getRequest(1000);
        assertEq(r.amountOfEEth, 0);
        assertEq(r.shareOfEEth, 0);
    }

    // ---- StakeWise V3 ----

    address internal constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address internal constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;
    address internal constant SW_HOLDER = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    uint256 internal constant SW_TICKET = 241_843_370_089_062_440_762_194;
    uint256 internal constant SW_TS = 1_782_159_731;
    uint256 internal constant SW_EXPECTED = 1_000_033_196_791_603_018_908;

    function test_stakewise_keeperFilesRealTicket_andRejectsWrongTimestamp() public {
        vm.rollFork(25_380_000);
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        StakeWiseV3ExitQueueAssistedBalanceAdapter a = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days, address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);

        bytes memory coord = abi.encode(GENESIS_VAULT, SW_TICKET, SW_TS);
        INAVCalculator.PositionBalance[] memory preview = a.previewPositions(SW_HOLDER, _one(coord));
        vm.prank(keeper);
        a.submitFor(SW_HOLDER, coord);
        INAVCalculator.PositionBalance[] memory cached = a.getAdapterPositions(SW_HOLDER, address(0));
        _assertSameLegs(preview, cached);
        uint256 total;
        for (uint256 i; i < cached.length; ++i) {
            total += cached[i].amount;
        }
        assertEq(total, SW_EXPECTED, "pinned value");

        // S3: the request key includes the timestamp, so a wrong one owns nothing.
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, SW_HOLDER, SW_TICKET));
        vm.prank(keeper);
        a.submitFor(SW_HOLDER, abi.encode(GENESIS_VAULT, SW_TICKET, SW_TS + 1));
    }

    /// @notice The proof-of-death shape the StakeWise `_isDead` relies on, read from the real vault: the ticket above
    ///         was fully claimed at block 25,382,071, after which `calculateExitedAssets` succeeds and returns zeros.
    function test_stakewise_claimedRequestShape() public {
        vm.rollFork(25_383_000);
        IStakeWiseVaultReads v = IStakeWiseVaultReads(GENESIS_VAULT);
        int256 idx = v.getExitQueueIndex(SW_TICKET);
        uint256 q = idx < 0 ? type(uint256).max : uint256(idx);
        (uint256 left, uint256 exited, uint256 assets) = v.calculateExitedAssets(SW_HOLDER, SW_TICKET, SW_TS, q);
        assertEq(left + exited + assets, 0);
    }

    // ---- Nexus Mutual ----

    address internal constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address internal constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address internal constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address internal constant NX_HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3;

    function test_nexus_keeperBatchFilesRealIds() public {
        vm.rollFork(25_388_000);
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");
        NexusMutualStakingPoolsAssistedBalanceAdapter a = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);

        uint256[5] memory ids = [uint256(180), 184, 185, 186, 187];
        address[] memory accounts = new address[](5);
        bytes[] memory coords = new bytes[](5);
        for (uint256 i; i < 5; ++i) {
            accounts[i] = NX_HOLDER;
            coords[i] = abi.encode(ids[i]);
        }
        INAVCalculator.PositionBalance[] memory preview = a.previewPositions(NX_HOLDER, abi.encode(coords));
        vm.prank(keeper);
        a.submitForBatch(accounts, coords);
        _assertSameLegs(preview, a.getAdapterPositions(NX_HOLDER, address(0)));
        assertGt(preview.length, 0);

        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, NX_HOLDER, 180));
        a.removeFor(NX_HOLDER, abi.encode(uint256(180)));
    }
}

interface IStakeWiseVaultReads {
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);
    function calculateExitedAssets(address receiver, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets);
}
