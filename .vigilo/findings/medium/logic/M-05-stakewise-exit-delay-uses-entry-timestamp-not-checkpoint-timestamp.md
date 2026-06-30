# [WITHDRAWN — behavior verified correct]

`StakeWiseV3ExitQueueBalanceAdapter._owedForPosition` uses `block.timestamp >= timestamp + EXIT_CLAIM_DELAY` where `timestamp` is the entry block's `block.timestamp`. StakeWise V3's own `claimExitedAssets` function uses the SAME entry timestamp for the same delay gate (the entry timestamp is part of the exit-request key). The adapter correctly mirrors the protocol's own claim gate. No bug.
