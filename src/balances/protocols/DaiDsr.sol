// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "src/errors.sol";

/// @notice A balance oracle for the DAI token that uses the DSRManager contract to calculate the balance.
contract DaiDsrBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // Constants
    //

    /// @notice Copied from the original DSRManager contract
    /// @notice https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    uint256 public constant RAY = 10 ** 27;

    //
    // State
    //

    /// @notice Address of the DAI token
    address public immutable dai;

    /// @notice Address of the DSR Manager contract.
    DsrManager public immutable dsrManager;

    /// @notice Address of the Pot contract
    PotLike public immutable pot;

    /// @notice Position metadata tags describing the DeFi position this oracle is associated to.
    PositionMetadata private _positionMetadata;

    //
    // Constructor
    //

    /// @param dai_ The address of the DAI token
    /// @param dsrManager_ The address of the DSR Manager contract
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address dai_, address dsrManager_, PositionMetadata memory positionMetadata_) {
        if (dai_ == address(0) || dsrManager_ == address(0)) revert InvalidArguments();
        dai = dai_;
        dsrManager = DsrManager(dsrManager_);
        pot = dsrManager.pot();
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address safe) external view returns (int256) {
        if (underlyingAsset != dai) {
            revert InvalidArguments();
        }
        return _daiBalance(safe).toInt256();
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = dai;
        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    //
    // Internal API
    //

    /// @notice Adapted from the write-function on the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param usr The address of the account
    /// @return wad The balance of the account
    function _daiBalance(address usr) internal view returns (uint256 wad) {
        // we don't call drip as in the original code, only chi, since we're in a view function
        // but we emulate it by calling the same instructions that are in the drip function
        // uint256 chi = (block.timestamp > pot.rho()) ? pot.drip() : pot.chi();
        uint256 chi = pot.chi();

        uint256 rho = pot.rho();
        if (block.timestamp > rho) {
            // tmp = rmul(rpow(dsr, now - rho, ONE), chi);
            uint256 dsr = pot.dsr();
            chi = _rmul(_rpow(dsr, block.timestamp - rho, RAY), chi);
        }
        wad = _rmul(chi, dsrManager.pieOf(usr));
    }

    /// @notice Copied from the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The first number
    /// @param y The second number
    /// @return z The result of the multiplication
    function _mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // solhint-disable-next-line reason-string, gas-custom-errors
        require(y == 0 || (z = x * y) / y == x);
    }

    /// @notice Copied from the original DSRManager contract
    ///   https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The first number
    /// @param y The second number
    /// @return z The result of the multiplication
    function _rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds down
        z = _mul(x, y) / RAY;
    }

    /// @notice Copied from the original DSRManager contract
    ///  https://etherscan.io/address/0x373238337bfe1146fb49989fc222523f83081ddb#code
    /// @param x The base number to be raised to the power of n
    /// @param n The exponent
    /// @param base The base for the fixed point math used to scale the result
    /// @return z The result of the exponentiation
    function _rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := base }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := base }
                default { z := x }
                let half := div(base, 2) // for rounding.
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface DsrManager {
    /// @notice from the original DsrManager contract
    /// @return The pot value
    function pot() external view returns (PotLike);

    /// @notice from the original DsrManager contract
    /// @param account The address of the account
    /// @return The pie value
    function pieOf(address account) external view returns (uint256);
}

interface PotLike {
    /// @notice The dai saving rate
    /// @return The dsr value
    function dsr() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The chi value
    function chi() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The rho value
    function rho() external view returns (uint256);

    /// @notice from the original Pot contract
    /// @return The drip value
    function drip() external returns (uint256);

    /// @notice from the original Pot contract
    /// @param a The number of DAI to join
    function join(uint256 a) external;

    /// @notice from the original Pot contract
    /// @param a The address to transfer the balance to
    function exit(uint256 a) external;
}
