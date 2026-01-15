// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IL1StandardBridge Interface
/// @notice Interface for Optimism L1 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L1 to L2
interface IL1StandardBridge {
    /// @notice Deposits ETH to a recipient's balance on L2
    /// @param _to Address on L2 to receive the ETH
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    function depositETHTo(address _to, uint32 _l2Gas, bytes calldata _data) external payable;

    /// @notice Deposits an amount of ERC20 tokens to a recipient's balance on L2
    /// @param _l1Token Address of the L1 token
    /// @param _l2Token Address of the corresponding L2 token
    /// @param _to Address on L2 to receive the tokens
    /// @param _amount Amount of tokens to deposit
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _l2Gas,
        bytes calldata _data
    ) external;

    /// @notice Event emitted when ETH deposit is initiated
    event ETHDepositInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 deposit is initiated
    event ERC20DepositInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}
