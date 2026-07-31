// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Mock_ERC20 is ERC20 {
    uint8 _decimals;

    constructor(string memory symbol, uint8 _decimals_) ERC20(symbol, symbol) {
        _decimals = _decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @notice Minimal ERC-4626 mock with a linear, configurable per-share rate and a distinct underlying asset, so
///         tests can exercise vaults whose share decimals differ from the underlying's decimals (a decimals offset).
///         `convertToAssets` returns amounts denominated in the underlying asset's decimals, matching real ERC-4626.
contract Mock_ERC4626 is Mock_ERC20 {
    /// @notice The underlying asset (exposes `asset()` for callers).
    address public asset;

    /// @notice Assets (in the underlying's decimals) returned for one whole share (`10**shareDecimals`).
    uint256 public assetsForOneShare;

    constructor(string memory symbol, uint8 shareDecimals, address asset_, uint256 assetsForOneShare_)
        Mock_ERC20(symbol, shareDecimals)
    {
        asset = asset_;
        assetsForOneShare = assetsForOneShare_;
    }

    /// @notice Linear in shares: `convertToAssets(10**shareDecimals) == assetsForOneShare`.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsForOneShare / (10 ** decimals());
    }

    /// @notice Fee-less redemption preview, equal to {convertToAssets}.
    /// @dev `previewRedeem` is a MANDATORY part of ERC4626, and this mock did not implement it — so it modelled
    ///      a vault that cannot exist. That gap was load-bearing rather than cosmetic: adapters value shares
    ///      through `ERC4626RedeemLib.redeemValue`, which prefers `previewRedeem` precisely because
    ///      `convertToAssets` is required to IGNORE any redemption fee (EIP-4626 §4.3). Against a mock missing
    ///      the fee-aware accessor, every such test silently exercised the fallback instead of the real path.
    ///      Equal to `convertToAssets` here because this mock charges no fee; a mock that DOES charge one, and
    ///      therefore returns different values from the two, lives in `test/balances/ERC4626RedeemLib.t.sol`
    ///      where the difference is the thing under test.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return shares * assetsForOneShare / (10 ** decimals());
    }
}
