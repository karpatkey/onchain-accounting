// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IL2StandardBridge Interface
/// @notice Interface for Optimism L2 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L2 to L1
interface IL2StandardBridge {
    /// @notice Withdraws ETH to a recipient on L1
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ETH to a specific recipient on L1
    /// @param _to Address on L1 to receive the ETH
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _to, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(address _l2Token, uint256 _amount, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a specific recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _to Address on L1 to receive the tokens
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _l2Token, address _to, uint256 _amount, uint32 _l1Gas, bytes calldata _data)
        external
        payable;

    /// @notice Event emitted when ETH withdrawal is initiated
    event ETHWithdrawalInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 withdrawal is initiated
    event ERC20WithdrawalInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}
