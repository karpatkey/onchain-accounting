// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {PolygonStakingMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IStakeManager {
    function token() external view returns (address);
    function getValidatorContract(uint256 validatorId) external view returns (address);
}

/// @title PolygonStakingMetaBalanceAdapter fork tests (Ethereum mainnet)
/// @notice Polygon PoS staking settles on Ethereum L1, so this is a chain-1 fork despite the protocol's name.
contract PolygonStakingMetaForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address public constant STAKE_MANAGER = 0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908;

    /// @dev Validator 192's ValidatorShare ("Delegated POL #c0" / `dPOLc0`) — the only Polygon delegation any
    ///      covered Safe holds, and the instance configured in nav-config.
    address public constant VALIDATOR_SHARE = 0x97997023aAB1D6b9760538Eb621bF10cfCD84868;
    address public constant TEST_USER = 0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89;

    /// @dev A live validator share with no delegation from TEST_USER — pins that "configured but empty" yields no
    ///      legs at all rather than zero-amount noise.
    address public constant EMPTY_SHARE = 0xd60537988F1FA1F471f94d669C4a3e936c977537;

    uint256 public constant FORK_BLOCK = 25_735_412;

    /// @dev Measured at FORK_BLOCK. The staked figure is stable across blocks (no deposits since); rewards accrue
    ///      every checkpoint, which is why only the principal is pinned exactly.
    uint256 public constant EXPECTED_STAKED = 106_114_233772116024377328;

    PolygonStakingMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
    }

    function _deploy() internal {
        balances = _deployBalancesForAdapter(POL);
        meta = new PolygonStakingMetaBalanceAdapter(POL, address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(VALIDATOR_SHARE)));
    }

    function _fork() internal {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        _deploy();
    }

    /// @notice The staked principal matches the exact on-chain figure, and the rewards leg is present and non-zero.
    function test_stakingAndRewardsLegs() public {
        _fork();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER, _instance(), address(0));
        assertEq(p.length, 2, "one Staking leg + one Rewards leg");

        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Staking));
        assertEq(p[0].amount, EXPECTED_STAKED, "staked principal");
        assertFalse(p[0].isDebt);

        assertEq(uint256(p[1].positionKind), uint256(PositionKind.Rewards));
        assertGt(p[1].amount, 0, "rewards accrue continuously and are non-zero at this block");
        assertFalse(p[1].isDebt, "rewards are credit, never debt");

        // Independent sanity band that does NOT mirror the implementation: rewards are a small fraction of
        // principal, so a leg that swapped the two returns would fail here even though both are non-zero.
        assertLt(p[1].amount, p[0].amount / 100, "rewards must be far smaller than principal");
    }

    /// @notice Both legs carry the same positionId (the share address) and the POL asset.
    function test_identityDerivedOnChain() public {
        _fork();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(TEST_USER, _instance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(VALIDATOR_SHARE), "positionId = ValidatorShare address");
            assertEq(p[i].balanceAsset.asset, POL);
            assertEq(p[i].balanceAdapter, address(meta));
        }
    }

    /// @notice The adapter's underlying really is the token the StakeManager settles in. Guards the one constructor
    ///         argument that is not otherwise checked on-chain — the analogue of pinning a protocol address.
    function test_underlyingMatchesStakeManagerToken() public {
        _fork();
        assertEq(IStakeManager(STAKE_MANAGER).token(), POL, "StakeManager settles in POL");
        assertEq(meta.UNDERLYING_TOKEN(), POL);
    }

    /// @notice The configured instance really is validator 192's share, per the StakeManager's own registry. If the
    ///         config is ever re-pointed at another validator, this fails rather than silently valuing the wrong one.
    function test_instanceIsValidator192() public {
        _fork();
        assertEq(
            IStakeManager(STAKE_MANAGER).getValidatorContract(192),
            VALIDATOR_SHARE,
            "configured instance must be validator 192's share contract"
        );
    }

    /// @notice A live share the user has not delegated to yields NO legs — not zero-amount ones.
    function test_emptyValidator_yieldsNoLegs() public {
        _fork();
        bytes32[] memory ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(EMPTY_SHARE)));
        assertEq(meta.getAdapterPositionsForInstances(TEST_USER, ins, address(0)).length, 0);
    }

    /// @notice Label is derived from the real `validatorId()`, not from the share's opaque `name()`.
    function test_positionLabels_realValidatorId() public {
        _fork();
        string[] memory l = meta.positionLabels(abi.encode(VALIDATOR_SHARE));
        assertEq(l.length, 2);
        assertEq(l[0], "Validator");
        assertEq(l[1], "#192");
    }

    /// @notice Fails open on a code-less address rather than reverting a display-only view.
    function test_positionLabels_codeless_failsOpen() public {
        _fork();
        address codeless = address(0xBEEF);
        string[] memory l = meta.positionLabels(abi.encode(codeless));
        assertEq(l.length, 2);
        assertEq(l[1], string.concat("POL ", codeless.toHexString()));
    }
}
