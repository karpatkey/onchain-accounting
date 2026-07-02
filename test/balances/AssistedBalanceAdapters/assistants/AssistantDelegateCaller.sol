// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {
    NexusMutualStakingPoolsAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";

/// @notice Test stand-in for a staking account (e.g. an OIV Safe / Safe module user) that `delegatecall`s the
///         delegatecall-only {NexusMutualStakingPoolsAssistant}. Under the delegatecall, `address(this)` is this
///         contract, so it is the account that holds NXM and owns the StakingNFT.
contract AssistantDelegateCaller {
    function deposit(address wrapper, address pool, uint256 amount, uint256 trancheId, uint256 requestTokenId)
        external
        returns (uint256 tokenId)
    {
        bytes memory ret = _delegate(
            wrapper,
            abi.encodeCall(NexusMutualStakingPoolsAssistant.depositTo, (pool, amount, trancheId, requestTokenId))
        );
        return abi.decode(ret, (uint256));
    }

    function withdraw(address wrapper, address pool, uint256 tokenId, bool ws, bool wr, uint256[] memory trancheIds)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards)
    {
        bytes memory ret = _delegate(
            wrapper, abi.encodeCall(NexusMutualStakingPoolsAssistant.withdraw, (pool, tokenId, ws, wr, trancheIds))
        );
        return abi.decode(ret, (uint256, uint256));
    }

    function _delegate(address wrapper, bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = wrapper.delegatecall(data);
        if (!ok) {
            // bubble the revert reason
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
