// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CapBalanceAdapterBase} from "./CapBalanceAdapterBase.sol";
import {SingleAssetBalanceAdapterBase} from "../../SingleAssetBalanceAdapterBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title Cap Stablecoin Balance Adapter
/// @author KPK
/// @notice Reports the USDC-equivalent value of an account's directly-held cUSD — Cap's synthetic dollar.
/// @dev One leg, one label pair: `["Stablecoin", "cUSD"]` for every position this adapter can emit.
///      Valuation is `ERC20.balanceOf` → `ICUsd.getBurnAmount` → USDC, the same quote the pre-split
///      `CapBalanceAdapter` used for this leg, so the reported amount does not move across the split.
///
///      Sibling of {CapSavingsBalanceAdapter}: same protocol, same taxonomy, same underlying asset, different leg.
///      Both are registered on the NAVCalculator; see {CapBalanceAdapterBase} for why the protocol is served by two
///      contracts rather than one.
contract CapStablecoinBalanceAdapter is CapBalanceAdapterBase {
    /// @param cUsd_ The address of the Cap cUSD token — this adapter's leg token AND its burn-quote oracle.
    /// @param usdc_ The address of USDC (the underlying asset returned).
    /// @param navCalculator_ The address of the NAVCalculator contract.
    constructor(address cUsd_, address usdc_, address navCalculator_)
        CapBalanceAdapterBase(cUsd_, usdc_, navCalculator_)
    {}

    /// @inheritdoc CapBalanceAdapterBase
    function _positionToken() internal view override returns (address) {
        return address(CUSD);
    }

    /// @inheritdoc CapBalanceAdapterBase
    /// @dev Held cUSD is a wallet-held synthetic dollar rather than a staked position, so it reports `Supplied` —
    ///      unchanged from the pre-split adapter's cUSD leg.
    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Supplied;
    }

    /// @inheritdoc CapBalanceAdapterBase
    function _labelPair() internal pure override returns (string memory, string memory) {
        return ("Stablecoin", "cUSD");
    }

    /// @inheritdoc SingleAssetBalanceAdapterBase
    /// @dev USDC equivalent of the account's directly-held cUSD (0 if none).
    function _owedAmount(address account) internal view override returns (uint256) {
        return _usdcForCUsd(IERC20(address(CUSD)).balanceOf(account));
    }
}
