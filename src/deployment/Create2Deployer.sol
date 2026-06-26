// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Create2Deployer
/// @notice Stateless CREATE2 deployment library designed for Safe delegatecall usage
/// @dev When Safe delegatecalls this contract, CREATE2 executes in Safe's context,
///      making Safe the deployer and enabling deterministic addresses across chains
/// @author KPK
contract Create2Deployer {
    /// @notice Emitted when a contract is deployed via CREATE2
    /// @param deployed The address of the deployed contract
    /// @param salt The salt used for CREATE2 deployment
    event Deployed(address indexed deployed, bytes32 salt);

    /// @notice Deploys a contract using CREATE2
    /// @dev In delegatecall context, address(this) = Safe's address
    /// @param salt The CREATE2 salt for deterministic address generation
    /// @param bytecode The contract creation bytecode
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes memory bytecode) external returns (address deployed) {
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(deployed) {
                revert(0, 0)
            }
        }
        emit Deployed(deployed, salt);
    }

    /// @notice Computes the CREATE2 address for a given salt and bytecode
    /// @dev Uses address(this) as the deployer, which in delegatecall context is Safe's address
    /// @param salt The CREATE2 salt
    /// @param bytecode The contract creation bytecode
    /// @return The computed CREATE2 address
    function computeAddress(bytes32 salt, bytes memory bytecode) external view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))))
            );
    }

    /// @notice Computes the CREATE2 address for a given salt and bytecode hash
    /// @dev Useful when bytecode is large and you already have its hash
    /// @param salt The CREATE2 salt
    /// @param bytecodeHash The keccak256 hash of the contract creation bytecode
    /// @return The computed CREATE2 address
    function computeAddressFromHash(bytes32 salt, bytes32 bytecodeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
