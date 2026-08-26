// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/// @title ICreate2Deployer
/// @notice Interface of the canonical CREATE2 deployer contract.
/// @dev Vendored VERBATIM from Compound's comet. Source:
///      https://github.com/compound-finance/comet/blob/ed6ebcd84ac00906e8e725716891d482f4bef8b9/contracts/Create2DeployerInterface.sol
///
///      Upstream repo: https://github.com/compound-finance/comet
///      Upstream path: contracts/Create2DeployerInterface.sol
///      Pinned rev:    ed6ebcd84ac00906e8e725716891d482f4bef8b9
///
///      Vendored rather than carried as a submodule: this interface was the only thing imported
///      from `lib/comet` (25 MB working tree), and its sole consumer is
///      script/test/Test02_DeployProxies.t.sol. Deviations from upstream: none — the two function
///      signatures are copied unmodified, because they must match the already-deployed canonical
///      deployer at CANONICAL_CREATE2_DEPLOYER for the staticcalls in that test to decode.
///
///      NOTE: distinct from src/deployment/Create2Deployer.sol, which is this repo's own
///      Safe-delegatecall deployer and takes `computeAddress(bytes32, bytes memory)`. This
///      interface's `computeAddress` takes a bytecode HASH, not the bytecode.
///
///      The upstream MIT licence tag at the top of this file is retained verbatim: this file
///      is NOT under the repo's
///      BUSL-1.1 licence. See docs/decisions/0024-dependency-size-vendor-single-file-deps.md and
///      the third-party note in the root LICENSE.
interface ICreate2Deployer {
    /**
     * @dev Deploys a contract using `CREATE2`.
     * @param value Amount of ETH to send with the contract creation.
     * @param salt A unique salt used to compute the deployment address.
     * @param code The bytecode of the contract to deploy.
     */
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;

    /**
     * @dev Returns the address where a contract will be stored if deployed via `deploy`.
     * @param salt A unique salt used to compute the deployment address.
     * @param codeHash The keccak256 hash of the contract bytecode.
     */
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);
}
