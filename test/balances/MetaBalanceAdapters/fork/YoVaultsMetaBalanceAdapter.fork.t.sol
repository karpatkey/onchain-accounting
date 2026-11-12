// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {YoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/YoVaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";

interface IYoVaultFull {
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function fulfillRedeem(address receiver, uint256 shares, bool atCurrentPrice) external;
    function updateWithdrawFee(uint256 newFee) external;
    function pendingRedeemRequest(address user) external view returns (uint256, uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function feeOnWithdraw() external view returns (uint256);
    function owner() external view returns (address);
}

interface IYoOracle {
    function getLatestPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
}

interface INavGov {
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function isAdapterRegistered(address adapter) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title YoVaultsMetaBalanceAdapter fork tests — the governance batch applied to the LIVE NAVCalculator
/// @notice Deploys the adapter, applies the exact batch the PR proposes (`addMetaBalanceAdapter(adapter, [Edge])`,
///         pranked as the TimelockController that holds MANAGER), then
///         drives a real Portfolio Safe through deposit → requestRedeem → fulfillRedeem on yoUSD Edge and checks the
///         Safe's NAV at each step.
/// @dev NAV reads go through raw staticcalls and decode only `value` (word 1 of the returned struct), so the test
///      does not depend on this build's `INAVCalculator` struct layout matching the live implementation.
///      To force the escrow path, the vault's idle USDC is zeroed with `deal` before `requestRedeem` (with idle
///      liquidity the vault redeems instantly and no queue entry is created), and re-funded before `fulfillRedeem`.
contract YoVaultsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    uint256 internal constant FORK_BLOCK = 26_399_700;

    address internal constant EDGE = 0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant YO_ORACLE = 0x6E879d0CcC85085A709eBf5539224f53d0D396B0;
    address internal constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address internal constant TIMELOCK = 0xAB92EA75D07792915eB1f29259354866B880dFC2; // MANAGER on the NAV
    address internal constant MORPHO_VAULTS_META = 0x72a012B30b240458C3f79fd20E5c2A907d77e54f;
    bytes32 internal constant MANAGER = keccak256("MANAGER");
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev The address the governance batch registers; pinned in `Create2FleetWideAddresses.t.sol` too.
    address internal constant YO_VAULTS_META = 0x64Fb8b1d04b28B0389beEB76E844e2935E25f4b3;

    /// @dev The five Portfolio Safes (eth, usd, wbtc, xaut, cbbtc). None holds Edge at FORK_BLOCK.
    address internal constant SAFE_ETH = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b;
    address internal constant SAFE_USD = 0x38F6a1B46144fAEe6a6D9F79D8dE264C18e23848;
    address internal constant SAFE_WBTC = 0x0295E5d0530C23E560CdbFc097C488a0A0D7752D;
    address internal constant SAFE_XAUT = 0x67269455871526A052cA89329218a41e810Ecc15;
    address internal constant SAFE_CBBTC = 0xc7B7Fe7DFfb11869023dA5C327e725B361bdFe5D;

    /// @dev The account the lifecycle tests drive (cbBTC Carry is the Safe the first Edge allocation targets).
    address internal constant SAFE = SAFE_CBBTC;
    uint256 internal constant DEPOSIT = 100_000e6;

    IYoVaultFull internal edge = IYoVaultFull(EDGE);
    INavGov internal nav = INavGov(NAV);
    YoVaultsMetaBalanceAdapter internal adapter;
    address internal yoOwner;

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function setUp() public override {
        super.setUp();
        assertTrue(nav.hasRole(MANAGER, TIMELOCK), "MANAGER holder rotated - update TIMELOCK");
        // Deploy exactly as `04_DeployBalanceAdapters._deployYoVaultsMeta` does (CREATE2 via the canonical deployer),
        // so the address the batch registers is the one exercised here.
        bytes32 salt = keccak256(abi.encodePacked("YoVaultsMetaBalanceAdapter", DeploySalts.YO_VAULTS_META));
        (bool ok,) = CREATE2_DEPLOYER.call(
            abi.encodePacked(salt, type(YoVaultsMetaBalanceAdapter).creationCode, abi.encode(NAV))
        );
        require(ok, "CREATE2 deploy failed");
        adapter = YoVaultsMetaBalanceAdapter(YO_VAULTS_META);
        assertGt(YO_VAULTS_META.code.length, 0, "CREATE2 address mismatch - re-derive the batch");
        yoOwner = edge.owner();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The governance batch from the PR description, executed as the timelock would.
    function _applyBatch() internal {
        vm.prank(TIMELOCK);
        nav.addMetaBalanceAdapter(address(adapter), _edgeInstance());
    }

    function _edgeInstance() internal pure returns (bytes32[] memory inst) {
        inst = new bytes32[](1);
        inst[0] = bytes32(uint256(uint160(EDGE)));
    }

    function _legs() internal view returns (INAVCalculator.PositionBalance[] memory) {
        return adapter.getAdapterPositionsForInstances(SAFE, _edgeInstance(), address(0));
    }

    function _assertYoIdentity(INAVCalculator.PositionBalance memory p) internal view {
        assertEq(p.balanceAsset.asset, USDC);
        assertEq(p.balanceAdapter, address(adapter));
        assertEq(uint8(p.positionKind), uint8(PositionKind.Supplied));
        assertEq(p.protocolBrand, ProtocolIds.YO);
        assertEq(p.protocolId, ProtocolIds.YO);
        assertEq(p.protocolSubId, ProtocolIds.YO_VAULTS);
        assertEq(p.positionId, abi.encode(EDGE));
        assertEq(p.positionInstanceId, bytes32(0));
    }

    function _navRaw(address account) internal view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = NAV.staticcall(abi.encodeWithSignature("getAccountNav(address,address)", account, address(0)));
        require(ok, "getAccountNav reverted");
    }

    function _nav(address account) internal view returns (int256) {
        return _word1(_navRaw(account));
    }

    function _word1(bytes memory ret) internal pure returns (int256 v) {
        assembly {
            v := mload(add(ret, 0x40))
        }
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(USDC, SAFE, IERC20(USDC).balanceOf(SAFE) + amount);
        vm.startPrank(SAFE);
        IERC20(USDC).approve(EDGE, amount);
        shares = edge.deposit(amount, SAFE);
        vm.stopPrank();
    }

    /// @dev Queue a redeem of `shares` (vault idle liquidity zeroed first so it cannot settle instantly).
    function _requestQueued(uint256 shares) internal {
        deal(USDC, EDGE, 0);
        vm.prank(SAFE);
        uint256 ret = edge.requestRedeem(shares, SAFE, SAFE);
        assertEq(ret, 0, "redeem settled instantly - escrow path not exercised");
    }

    function _fulfill(uint256 shares, bool atCurrentPrice) internal {
        deal(USDC, EDGE, 10_000_000e6);
        vm.prank(yoOwner);
        edge.fulfillRedeem(SAFE, shares, atCurrentPrice);
    }

    /// @dev Held-share leg (`isLocked = false`) for Edge, 0 if absent.
    function _heldLeg() internal view returns (uint256 amount) {
        INAVCalculator.PositionBalance[] memory p = _legs();
        for (uint256 i; i < p.length; ++i) {
            _assertYoIdentity(p[i]);
            if (!p[i].isLocked) amount += p[i].amount;
        }
    }

    /// @dev Pending leg (`isLocked = true`) for Edge, and how many locked legs there are.
    function _pendingLeg() internal view returns (uint256 amount, uint256 legs) {
        INAVCalculator.PositionBalance[] memory p = _legs();
        for (uint256 i; i < p.length; ++i) {
            _assertYoIdentity(p[i]);
            if (p[i].isLocked) {
                amount += p[i].amount;
                ++legs;
            }
        }
    }

    /// @dev Edge legs the live MorphoVaultsMeta reports for SAFE — must be none (Edge is NOT a Morpho instance).
    function _morphoEdgeLegs() internal view returns (uint256 n) {
        INAVCalculator.PositionBalance[] memory p =
            INAVCalculatorPositions(MORPHO_VAULTS_META).getAdapterPositions(SAFE, address(0));
        for (uint256 i; i < p.length; ++i) {
            if (keccak256(p[i].positionId) == keccak256(abi.encode(EDGE))) ++n;
        }
    }

    /// @dev NAV is 8-dp USD; allow 1 USD-cent of drift for USDC price rounding across the two legs.
    uint256 internal constant NAV_TOL = 1e6;

    // ─── field order (pinned) ──────────────────────────────────────────────────────────────────────────────────────

    /// @notice A real `requestRedeem` populates `pendingRedeemRequest` as `(assets, shares)` — ASSETS FIRST, and
    ///         `assets` is the GROSS (pre-fee) `convertToAssets(shares)`. Edge's share price is ≠ 1, so the two
    ///         fields are numerically distinguishable and a swapped decode would fail here.
    function test_fork_pendingRedeemRequest_fieldOrder_assetsThenShares() public {
        uint256 shares = _deposit(DEPOSIT);
        uint256 gross = edge.convertToAssets(shares);
        assertTrue(gross != shares, "price == 1, field order not distinguishable");
        _requestQueued(shares);

        (uint256 first, uint256 second) = edge.pendingRedeemRequest(SAFE);
        assertEq(first, gross, "field 0 is the gross reserved assets");
        assertEq(second, shares, "field 1 is the escrowed shares");
        assertEq(edge.balanceOf(SAFE), 0, "shares left the Safe");
    }

    // ─── acceptance criteria ───────────────────────────────────────────────────────────────────────────────────────

    /// @notice (1) Safe holding Edge shares → held leg == previewRedeem(balance) (Part A, config-only).
    function test_fork_1_heldShares_valuedAtPreviewRedeem() public {
        _applyBatch();
        deal(USDC, SAFE, IERC20(USDC).balanceOf(SAFE) + DEPOSIT);
        int256 navBefore = _nav(SAFE);
        vm.startPrank(SAFE);
        IERC20(USDC).approve(EDGE, DEPOSIT);
        uint256 shares = edge.deposit(DEPOSIT, SAFE);
        vm.stopPrank();

        assertEq(_heldLeg(), edge.previewRedeem(shares), "held leg != previewRedeem(balance)");
        assertEq(_morphoEdgeLegs(), 0, "Edge must not be reported under Morpho");
        (, uint256 legs) = _pendingLeg();
        assertEq(legs, 0, "no pending leg without a request");
        // USDC out, Edge leg in: NAV moves only by the 0.001% withdraw fee embedded in previewRedeem (~$1 on $100k).
        assertApproxEqAbs(_nav(SAFE), navBefore, 2e8, "NAV moved on deposit beyond the withdraw fee");
    }

    /// @notice (2) requestRedeem → total NAV unchanged; held leg → pending leg.
    function test_fork_2_requestRedeem_navUnchanged() public {
        _applyBatch();
        uint256 shares = _deposit(DEPOSIT);
        uint256 held = _heldLeg();
        int256 navBefore = _nav(SAFE);

        _requestQueued(shares);

        assertEq(_heldLeg(), 0, "held leg must drop to 0");
        (uint256 pending, uint256 legs) = _pendingLeg();
        assertEq(legs, 1);
        assertApproxEqAbs(pending, held, 1, "pending leg != former held leg");
        assertApproxEqAbs(_nav(SAFE), navBefore, NAV_TOL, "NAV moved on requestRedeem");
    }

    /// @notice (3) fulfillRedeem → pending leg 0, USDC up by exactly the reported value, NAV unchanged.
    function test_fork_3_fulfillRedeem_navUnchanged() public {
        _applyBatch();
        uint256 shares = _deposit(DEPOSIT);
        _requestQueued(shares);
        (uint256 pending,) = _pendingLeg();
        uint256 usdcBefore = IERC20(USDC).balanceOf(SAFE);
        int256 navBefore = _nav(SAFE);

        _fulfill(shares, false);

        (, uint256 legs) = _pendingLeg();
        assertEq(legs, 0, "pending leg must be gone");
        assertEq(IERC20(USDC).balanceOf(SAFE) - usdcBefore, pending, "payout != reported pending value");
        assertApproxEqAbs(_nav(SAFE), navBefore, NAV_TOL, "NAV moved on fulfillRedeem");
    }

    /// @notice (4) Oracle price drops while escrowed → pending leg reflects the LOWER current value, and an
    ///         `atCurrentPrice` fulfilment pays exactly that (NAV unchanged across fulfilment).
    function test_fork_4_lowerPrice_atCurrentPrice() public {
        _applyBatch();
        uint256 shares = _deposit(DEPOSIT);
        _requestQueued(shares);
        (uint256 pendingAtRequest,) = _pendingLeg();

        (uint256 price, uint256 ts) = IYoOracle(YO_ORACLE).getLatestPrice(EDGE);
        vm.mockCall(YO_ORACLE, abi.encodeCall(IYoOracle.getLatestPrice, (EDGE)), abi.encode(price * 90 / 100, ts));

        (uint256 pending,) = _pendingLeg();
        assertEq(pending, edge.previewRedeem(shares), "leg must follow the lower current value");
        assertLt(pending, pendingAtRequest * 91 / 100, "leg did not drop with the price");

        int256 navBefore = _nav(SAFE);
        uint256 usdcBefore = IERC20(USDC).balanceOf(SAFE);
        _fulfill(shares, true);
        assertApproxEqAbs(IERC20(USDC).balanceOf(SAFE) - usdcBefore, pending, 1, "payout != reported value");
        assertApproxEqAbs(_nav(SAFE), navBefore, NAV_TOL, "NAV moved on atCurrentPrice fulfilment");
    }

    /// @notice (5) Withdraw fee raised to 9.99% → held and pending legs both reflect it exactly once.
    function test_fork_5_feeRaised_appliedOnce() public {
        _applyBatch();
        uint256 shares = _deposit(DEPOSIT);
        uint256 fee = 999e14; // 9.99% (YoVault MAX_FEE is 10%, exclusive)
        vm.prank(yoOwner);
        edge.updateWithdrawFee(fee);
        assertEq(edge.feeOnWithdraw(), fee);

        uint256 gross = edge.convertToAssets(shares);
        uint256 netOnce = gross * 1e18 / (1e18 + fee); // YoVault: fee is charged on the total, gross / (1 + fee)
        assertApproxEqAbs(_heldLeg(), netOnce, 2, "held leg: fee not applied exactly once");

        _requestQueued(shares);
        (uint256 pending,) = _pendingLeg();
        assertApproxEqAbs(pending, netOnce, 2, "pending leg: fee not applied exactly once");

        uint256 usdcBefore = IERC20(USDC).balanceOf(SAFE);
        _fulfill(shares, false);
        assertEq(IERC20(USDC).balanceOf(SAFE) - usdcBefore, pending, "payout != reported pending value");
    }

    // ─── fail closed ───────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice A reverting vault read drops the leg (under-report), it never substitutes a gross figure.
    function test_fork_failClosed_onReadRevert() public {
        _applyBatch();
        uint256 shares = _deposit(DEPOSIT);
        _requestQueued(shares);
        (uint256 pending,) = _pendingLeg();
        assertGt(pending, 0);

        vm.mockCallRevert(YO_ORACLE, abi.encodeCall(IYoOracle.getLatestPrice, (EDGE)), "oracle down");
        (, uint256 legs) = _pendingLeg();
        assertEq(legs, 0, "oracle failure must drop the leg");
        vm.clearMockedCalls();

        vm.mockCallRevert(EDGE, abi.encodeWithSignature("feeOnWithdraw()"), "x");
        (, legs) = _pendingLeg();
        assertEq(legs, 0, "fee read failure must drop the leg");
        vm.clearMockedCalls();

        vm.mockCallRevert(EDGE, abi.encodeWithSignature("pendingRedeemRequest(address)", SAFE), "x");
        (, legs) = _pendingLeg();
        assertEq(legs, 0, "queue read failure must drop the leg");
    }

    // ─── no regression ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Applying the batch leaves `getAccountNav` for all five Portfolio Safes BYTE-IDENTICAL at the same block
    ///         (none holds Edge or a pending Edge redeem at FORK_BLOCK).
    function test_fork_batch_noRegression_fivePortfolioSafes() public {
        address[5] memory safes = [SAFE_ETH, SAFE_USD, SAFE_WBTC, SAFE_XAUT, SAFE_CBBTC];
        bytes[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = _navRaw(safes[i]);
            emit log_named_int("NAV before (8dp USD)", _word1(before[i]));
        }

        _applyBatch();
        assertTrue(nav.isAdapterRegistered(address(adapter)));
        assertEq(nav.getMetaInstances(address(adapter)).length, 1);

        for (uint256 i; i < 5; ++i) {
            assertEq(keccak256(_navRaw(safes[i])), keccak256(before[i]), "getAccountNav changed for a Portfolio Safe");
        }
    }
}

interface INAVCalculatorPositions {
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory);
}
