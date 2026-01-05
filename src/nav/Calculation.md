Following the refactor of the `NAVCalculator`, we have successfully removed the legacy "flagging" system. However, we now lack a formal mechanism to track and account for assets that are not currently held within the fund's primary vault (i.e., assets in transit).

The system currently has a "blind spot" during bridging. We need a dedicated infrastructure that not only facilitates the move but maintains a verifiable ledger of these assets to ensure the Total NAV remains accurate and "flawless" at all times.

<aside>
❗

**Current situation**

The `NAVCalculator` is now "clean" but only reports on-chain vault assets. Without any way of tracking assets being bridged, any asset leaving the vault to a bridge disappears from the total NAV reporting until it arrives at the destination.

</aside>

<aside>
ℹ️

**Requirements**

- **`BridgeEscrow` Contract:** Deploy one instance per chain. This contract acts as the "ledger of record" for all assets currently moving through a bridge.
- **Modular Adapters:** Implement a `BridgeAdapter` system.
    - Adapters are the only entities (along side Safes) authorised to receive funds from the Escrow.
    - They encapsulate the specific logic for different bridge providers (e.g., CCTP logic vs. Gnosis Bridge logic).
- **Invoice System:** Every bridge operation must generate a unique identity to be tracked off-chain.
    - **Fields:** `sourceChainId`, `destinationChainId`, `portfolioSafe`, and a `globalNonce` (incrementing counter).
- **Strict Access Control:** The `BridgeEscrow` can **only** transfer funds to:
    1. The approved **Portfolio Safe** for a given fund on that chain.
    2. An approved **BridgeAdapter**.
- **Accounting Logic:**
    - **Inflow:** Assets entering from a Portfolio Safe increase the "In-Transit" balance.
    - **Outflow:** Assets exiting to a Portfolio Safe decrease the "In-Transit" balance.NAV Aggregation: Total NAV is now calculated as:
    $NAV_{total} = NAV_{calculator} + \sum BridgeEscrow_{balances}$
- **Security Requirement:** The `BridgeEscrow` will be a high-value target. It must be designed with extreme constraint—it is not a general-purpose wallet, but a restricted accounting gateway.
- **Infrastructure:** We need a standardised way to talk to various bridges (CCTP, Gnosis, etc.) without hardcoding logic into the main escrow contract.
</aside>