// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    AaveV4SpokesMetaBalanceAdapter,
    ISpoke
} from "src/balances/MetaBalanceAdapters/AaveV4SpokesMetaBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title AaveV4SpokesMetaBalanceAdapter fork tests
/// @notice The real mainnet Aave V4 Gold Spoke, a real account with a live three-leg position, at a pinned
///         block. The account supplies XAUt WITH collateral enabled and borrows USDC + USDT, so the fixture
///         exercises the two things that cannot be exercised against a mock alone: the Spoke's own share→asset
///         conversion, and `getUserReserveStatus` deciding `Collateral` vs `Supplied`.
/// @dev The block is pinned deliberately tight: the account repaid and withdrew a few thousand blocks later
///      (block 25_947_674 onward), so at HEAD it holds nothing. Re-pin to a block where the position is live if
///      this fixture is ever refreshed — do not "fix" a zero-length result by loosening the assertions.
contract AaveV4SpokesMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    /// @dev The Aave V4 Gold Spoke on Ethereum. `SPOKE_REVISION() == 1`, `getReserveCount() == 8`.
    address public constant GOLD_SPOKE = 0x65407b940966954b23dfA3caA5C0702bB42984DC;

    /// @dev The Gold Spoke's reserve 0, and its ONLY non-borrowable (collateral-only) reserve — which is what
    ///      makes the label leaf "XAUt".
    address public constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @dev Account with XAUt supplied as collateral plus USDC and USDT borrows on the Gold Spoke at FORK_BLOCK.
    address public constant HOLDER = 0xA6Efb408aCe37E59D66dD37129C78dC3C99178E8;

    uint256 public constant FORK_BLOCK = 25_942_506;

    /// @dev The adapter deployed on mainnet (CREATE2, canonical deployer) and recorded in
    ///      `script/config/deployments/1.json`.
    address public constant DEPLOYED_ADAPTER = 0x79cad9584012806a76E7892808556Ed3797EAbcD;
    /// @dev The fleet-wide NAVCalculator proxy the deployed adapter was constructed against.
    address public constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    uint256 constant XAUT_ID = 0;
    uint256 constant USDC_ID = 1;
    uint256 constant USDT_ID = 7;

    AaveV4SpokesMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        address[] memory assets = new address[](3);
        assets[0] = XAUT;
        assets[1] = USDC;
        assets[2] = USDT;
        balances = _deployBalancesForAdapter(assets);
        meta = new AaveV4SpokesMetaBalanceAdapter(address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(GOLD_SPOKE)));
    }

    function _leg(INAVCalculator.PositionBalance[] memory p, address asset)
        internal
        pure
        returns (INAVCalculator.PositionBalance memory found)
    {
        for (uint256 i; i < p.length; ++i) {
            if (p[i].balanceAsset.asset == asset) return p[i];
        }
        revert("no leg for asset");
    }

    /// @notice Every leg matches the Spoke's own view at the same block — the adapter converts nothing itself.
    function test_parityWithSpoke() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _instance(), address(0));
        assertEq(p.length, 3, "XAUt collateral + USDC borrow + USDT borrow");

        ISpoke spoke = ISpoke(GOLD_SPOKE);
        assertEq(_leg(p, XAUT).amount, spoke.getUserSuppliedAssets(XAUT_ID, HOLDER));
        assertEq(_leg(p, USDC).amount, spoke.getUserTotalDebt(USDC_ID, HOLDER));
        assertEq(_leg(p, USDT).amount, spoke.getUserTotalDebt(USDT_ID, HOLDER));
        assertGt(_leg(p, XAUT).amount, 0, "fixture must have a live supply at FORK_BLOCK");
        assertGt(_leg(p, USDC).amount, 0, "fixture must have a live borrow at FORK_BLOCK");
    }

    /// @notice The supply leg is `Collateral` because the Spoke reports collateral ENABLED for it, and the
    ///         borrows are `Borrowed` with a positive amount plus `isDebt` — never a negative amount.
    function test_legKindsAndSigns() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _instance(), address(0));

        (bool usingAsCollateral,) = ISpoke(GOLD_SPOKE).getUserReserveStatus(XAUT_ID, HOLDER);
        assertTrue(usingAsCollateral, "fixture premise: XAUt is enabled as collateral at FORK_BLOCK");

        INAVCalculator.PositionBalance memory xaut = _leg(p, XAUT);
        assertFalse(xaut.isDebt);
        assertEq(uint8(xaut.positionKind), uint8(PositionKind.Collateral));

        assertTrue(_leg(p, USDC).isDebt);
        assertEq(uint8(_leg(p, USDC).positionKind), uint8(PositionKind.Borrowed));
        assertTrue(_leg(p, USDT).isDebt);
        assertEq(uint8(_leg(p, USDT).positionKind), uint8(PositionKind.Borrowed));
    }

    /// @notice positionId is the Spoke — the unit a v4 health factor is scoped to — for every leg, and the
    ///         reserve is carried by `balanceAsset`, not by the id.
    function test_positionIdIsTheSpoke() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _instance(), address(0));
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionId, abi.encode(GOLD_SPOKE));
            assertEq(p[i].balanceAdapter, address(meta));
        }
    }

    /// @notice Reserves are enumerated on-chain by numeric id, so the Spoke's whole reserve list is the asset
    ///         set — no reserve is a configured coordinate.
    function test_reservesEnumeratedOnChain() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instance());
        assertEq(a.length, ISpoke(GOLD_SPOKE).getReserveCount(), "every populated reserve, none dropped");
        assertEq(a[XAUT_ID], XAUT);
        assertEq(a[USDC_ID], USDC);
        assertEq(a[USDT_ID], USDT);
    }

    /// @notice The gate the fan-out relies on, asserted against the real Spoke rather than assumed: an account
    ///         with zero shares on a reserve has zero converted assets on BOTH sides, so skipping the two
    ///         balance reads cannot drop a real balance.
    function test_gate_zeroSharesImpliesZeroAssets() public view {
        ISpoke spoke = ISpoke(GOLD_SPOKE);
        address stranger = address(uint160(uint256(keccak256("aave-v4-stranger"))));
        uint256 n = spoke.getReserveCount();
        for (uint256 id; id < n; ++id) {
            ISpoke.UserPosition memory up = spoke.getUserPosition(id, stranger);
            assertEq(up.suppliedShares, 0);
            assertEq(up.drawnShares, 0);
            assertEq(up.premiumShares, 0);
            assertEq(spoke.getUserSuppliedAssets(id, stranger), 0);
            assertEq(spoke.getUserTotalDebt(id, stranger), 0);
        }
        assertEq(meta.getAdapterPositionsForInstances(stranger, _instance(), address(0)).length, 0);
    }

    /// @notice The label leaf is derived from the Spoke's collateral-only reserves on-chain — the Gold Spoke's
    ///         is exactly XAUt.
    function test_positionLabels() public view {
        string[] memory l = meta.positionLabels(abi.encode(GOLD_SPOKE));
        assertEq(l.length, 2);
        assertEq(l[0], "Spoke");
        assertEq(l[1], "XAUt");
    }

    /// @notice What this PR records must be what mainnet runs: the recorded adapter address is a contract bound
    ///         to the recorded NAV proxy, registered on it, and carrying the Gold Spoke as its instance set.
    /// @dev Asserts the DEPLOYED adapter, not the locally deployed one — the config entry is only worth
    ///      anything if the address it names is the live registration.
    function test_deployedAdapterIsRegisteredWithTheGoldSpoke() public view {
        assertGt(DEPLOYED_ADAPTER.code.length, 0, "recorded address must hold code at FORK_BLOCK");
        assertEq(
            address(AaveV4SpokesMetaBalanceAdapter(DEPLOYED_ADAPTER).NAV_CALCULATOR()),
            NAV_PROXY,
            "deployed adapter is bound to the fleet-wide NAV proxy"
        );
        assertTrue(IBalances(NAV_PROXY).isAdapterRegistered(DEPLOYED_ADAPTER), "not registered on the live NAV");
        bytes32[] memory live = IBalances(NAV_PROXY).getMetaInstances(DEPLOYED_ADAPTER);
        assertEq(live.length, 1);
        assertEq(live[0], bytes32(uint256(uint160(GOLD_SPOKE))));
    }
}
