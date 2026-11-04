# I-02 — seed_assisted.py discovery/provenance notes (off-chain, under-report only)
- ether.fi/Nexus discovery keys on mint Transfer(from=0) to the account: NFTs transferred in are never discovered. This looks intentional under S13.
- StakeWise discovery uses only the ExitQueueEntered topic. Positions entered on v2.0.x vaults (V2ExitQueueEntered) are missed. Remainder-following only runs for tickets discovered in the same run (`ts_of`), so a remainder of a ticket that came only via `migrate` (old cache) and was claimed outside an Assistant is not followed.
- The trace rule accepts any log in the subtree of a Safe exec frame. A Safe transaction that calls third-party code which mints a position to the Safe passes. The residual is the S13 dust case again.
