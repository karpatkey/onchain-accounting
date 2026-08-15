// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CapBalanceAdapterBase} from "./CapBalanceAdapterBase.sol";
import {SingleAssetBalanceAdapterBase} from "../../SingleAssetBalanceAdapterBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title Cap Protocol stcUSD Interface
/// @notice Minimal ERC4626 interface for the staked cUSD (stcUSD) token.
interface IStcUsd {
    /// @notice Convert stcUSD shares to underlying cUSD assets.
    /// @param shares The amount of stcUSD shares to convert
    /// @return The equivalent amount of cUSD
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title Cap Savings Balance Adapter
/// @author KPK
/// @notice Reports the USDC-equivalent value of an account's staked stcUSD — Cap's yield-bearing savings token.
/// @dev One leg, one label pair: `["Savings", "stcUSD"]` for every position this adapter can emit.
///      Valuation is `ERC20.balanceOf` → ERC4626 `convertToAssets` → cUSD → `ICUsd.getBurnAmount` → USDC, the same
///      two-hop quote the pre-split `CapBalanceAdapter` used for this leg, so the reported amount does not move
///      across the split.
///
///      Sibling of {CapStablecoinBalanceAdapter}: same protocol, same taxonomy, same underlying asset, different
///      leg. Both are registered on the NAVCalculator; see {CapBalanceAdapterBase} for why the protocol is served
///      by two contracts rather than one.
contract CapSavingsBalanceAdapter is CapBalanceAdapterBase {
    /// @notice Cap protocol stcUSD token (ERC4626-like, redeems to cUSD) — this adapter's leg token.
    IStcUsd public immutable STCUSD;

    /// @param cUsd_ The address of the Cap cUSD token — the burn-quote oracle for the second valuation hop.
    /// @param stcUsd_ The address of the Cap stcUSD token — this adapter's leg token.
    /// @param usdc_ The address of USDC (the underlying asset returned).
    /// @param navCalculator_ The address of the NAVCalculator contract.
    constructor(address cUsd_, address stcUsd_, address usdc_, address navCalculator_)
        CapBalanceAdapterBase(cUsd_, usdc_, navCalculator_)
    {
        if (stcUsd_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(stcUsd_, "stcUSD");
        STCUSD = IStcUsd(stcUsd_);
    }

    /// @inheritdoc CapBalanceAdapterBase
    function _positionToken() internal view override returns (address) {
        return address(STCUSD);
    }

    /// @inheritdoc CapBalanceAdapterBase
    /// @dev Staked cUSD is a staking principal, so it reports `Staking` — unchanged from the pre-split adapter's
    ///      stcUSD leg.
    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Staking;
    }

    /// @inheritdoc CapBalanceAdapterBase
    function _labelPair() internal pure override returns (string memory, string memory) {
        return ("Savings", "stcUSD");
    }

    /// @inheritdoc SingleAssetBalanceAdapterBase
    /// @dev USDC equivalent of the account's staked stcUSD (shares → cUSD → USDC; 0 if none). The intermediate
    ///      zero-check matters: a share balance that converts to zero cUSD must not reach the burn quote, which
    ///      would charge a fee against nothing.
    function _owedAmount(address account) internal view override returns (uint256) {
        uint256 shares = IERC20(address(STCUSD)).balanceOf(account);
        if (shares == 0) return 0;
        return _usdcForCUsd(STCUSD.convertToAssets(shares));
    }
}
