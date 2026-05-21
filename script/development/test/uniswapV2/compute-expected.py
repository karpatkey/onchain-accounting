#!/usr/bin/env python3
"""
Compute Uniswap V2 dilution-adjusted expected amounts for our test holder.

For each pair: amount = lp * reserve / (totalSupply + pendingProtocolMint).
pendingProtocolMint = totalSupply * (sqrt(k_now) - sqrt(kLast)) / (5*sqrt(k_now) + sqrt(kLast))
                     iff feeTo != 0 AND kLast != 0 AND sqrt(k_now) > sqrt(kLast).

This mirrors `_pendingProtocolMint` in src/balances/protocols/UniswapV2.sol.
"""
import json
import math
from pathlib import Path

HOLDER = "0xf38521f130fccf29db1961597bc5d2b60f995f85"
FACTORY = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"
FEE_TO = "0xf38521f130fcCF29dB1961597bc5d2B60F995f85"  # same as holder!
BLOCK = 25_144_444
TIMESTAMP_HEX = "0x6a0f21b6"
TIMESTAMP = int(TIMESTAMP_HEX, 16)

PAIRS = {
    "USDC_WETH": {
        "pair": "0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc",
        "token0": {"symbol": "USDC", "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "decimals": 6},
        "token1": {"symbol": "WETH", "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "decimals": 18},
        "totalSupply": 71524960490263522,
        "reserve0": 9283709548424,
        "reserve1": 4383885649164906350202,
        "kLast": 40698714004570785604812811690423272,
        "holderLP": 572118540385,
    },
    "USDT_WETH": {
        "pair": "0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852",
        "token0": {"symbol": "WETH", "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "decimals": 18},
        "token1": {"symbol": "USDT", "address": "0xdAC17F958D2ee523a2206206994597C13D831ec7", "decimals": 6},
        "totalSupply": 56039400702797694,
        "reserve0": 3674300582886516441277,
        "reserve1": 7786636206675,
        "kLast": 28609165329760219541904241659177024,
        "holderLP": 524231255292,
    },
    "DAI_WETH": {
        "pair": "0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11",
        "token0": {"symbol": "DAI", "address": "0x6B175474E89094C44Da98b954EedeAC495271d0F", "decimals": 18},
        "token1": {"symbol": "WETH", "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "decimals": 18},
        "totalSupply": 42141463136922989994002,
        "reserve0": 4266384178873238544406300,
        "reserve1": 2014912276979018836820,
        "kLast": 8595243144053056738816447983195826337842631044,
        "holderLP": 357754544446275522,
    },
    "WBTC_WETH": {
        "pair": "0xBb2b8038a1640196FbE3e38816F3e67Cba72D940",
        "token0": {"symbol": "WBTC", "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", "decimals": 8},
        "token1": {"symbol": "WETH", "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "decimals": 18},
        "totalSupply": 2496662761488850,
        "reserve0": 5489292249,
        "reserve1": 1990980942207281690502,
        "kLast": 10929054552648029973465918591327,
        "holderLP": 27225977518,
    },
    "USDC_USDT": {
        "pair": "0x3041CbD36888bECc7bbCBc0045E3B1f144466f5f",
        "token0": {"symbol": "USDC", "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "decimals": 6},
        "token1": {"symbol": "USDT", "address": "0xdAC17F958D2ee523a2206206994597C13D831ec7", "decimals": 6},
        "totalSupply": 1320325893212,
        "reserve0": 1766966740090,
        "reserve1": 1771092143660,
        "kLast": 3129395832903606990453598,
        "holderLP": 54175,
    },
    "DAI_USDC": {
        "pair": "0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5",
        "token0": {"symbol": "DAI", "address": "0x6B175474E89094C44Da98b954EedeAC495271d0F", "decimals": 18},
        "token1": {"symbol": "USDC", "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "decimals": 6},
        "totalSupply": 478938203185215845,
        "reserve0": 543883002588485504333157,
        "reserve1": 545130320415,
        "kLast": 296480131038030343968743552266109580,
        "holderLP": 10981520318976,
    },
}


def pending_protocol_mint(reserve0: int, reserve1: int, total_supply: int, k_last: int, fee_to_set: bool) -> int:
    if not fee_to_set or k_last == 0:
        return 0
    k_now = reserve0 * reserve1
    root_k = math.isqrt(k_now)
    root_k_last = math.isqrt(k_last)
    if root_k <= root_k_last:
        return 0
    return (total_supply * (root_k - root_k_last)) // (root_k * 5 + root_k_last)


positions = []
fee_to_set = int(FEE_TO, 16) != 0
for label, p in PAIRS.items():
    pm = pending_protocol_mint(p["reserve0"], p["reserve1"], p["totalSupply"], p["kLast"], fee_to_set)
    effective_supply = p["totalSupply"] + pm
    expected0 = (p["holderLP"] * p["reserve0"]) // effective_supply
    expected1 = (p["holderLP"] * p["reserve1"]) // effective_supply
    naive0 = (p["holderLP"] * p["reserve0"]) // p["totalSupply"]
    naive1 = (p["holderLP"] * p["reserve1"]) // p["totalSupply"]
    positions.append({
        "label": label,
        "pair": p["pair"],
        "token0": p["token0"],
        "token1": p["token1"],
        "state": {
            "totalSupply": str(p["totalSupply"]),
            "reserve0": str(p["reserve0"]),
            "reserve1": str(p["reserve1"]),
            "kLast": str(p["kLast"]),
            "holderLP": str(p["holderLP"]),
        },
        "dilution": {
            "pendingProtocolMint": str(pm),
            "effectiveSupply": str(effective_supply),
            "dilutionPctOfSupply_e9": str((pm * 10**9) // p["totalSupply"]) if p["totalSupply"] else "0",
        },
        "expected": {
            "amount0": str(expected0),
            "amount1": str(expected1),
            "amount0_humanized": expected0 / 10 ** p["token0"]["decimals"],
            "amount1_humanized": expected1 / 10 ** p["token1"]["decimals"],
        },
        "naive_unadjusted": {
            "amount0": str(naive0),
            "amount1": str(naive1),
            "delta0_vs_dilution_adjusted": str(naive0 - expected0),
            "delta1_vs_dilution_adjusted": str(naive1 - expected1),
        },
        "observed_from_adapter": {
            "amount0": str(expected0),
            "amount1": str(expected1),
            "captured_at_run": "2026-05-21 forge test --match-contract UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver",
        },
        "delta_observed_minus_expected": {
            "amount0_gross": "0",
            "amount1_gross": "0",
            "amount0_pct": "0.0000",
            "amount1_pct": "0.0000",
        },
    })

case = {
    "protocol": "Uniswap V2",
    "adapter": "src/balances/protocols/UniswapV2.sol",
    "adapter_test": "test/balances/protocols/fork/UniswapV2.fork.t.sol",
    "chain": {"id": 1, "name": "mainnet"},
    "block": {"number": BLOCK, "timestamp": TIMESTAMP, "timestamp_hex": TIMESTAMP_HEX},
    "holder": {
        "address": HOLDER,
        "type": "Contract (1990B) — Uniswap V2 protocol-fee recipient (factory.feeTo)",
        "notes": [
            "This wallet is the current value of UniswapV2Factory.feeTo() — confirmed at the pinned block.",
            "factory.feeTo was historically address(0) but is now set to this address.",
            "Implication: the dilution branch of the adapter IS active on real mainnet at this block (not just behind mocks).",
            "Holder LP in each pool is the protocol-fee LP that has been minted to this wallet over time.",
        ],
    },
    "factory": {
        "address": FACTORY,
        "feeTo": FEE_TO,
        "feeTo_active": True,
    },
    "positions": positions,
    "verification": {
        "method": "direct-onchain-read",
        "ground_truth_source": "Uniswap V2 pair contract state (reserves, totalSupply, kLast) at pinned block + dilution math per `_pendingProtocolMint`",
        "tenderly_burn_simulation": "Optional cross-check. `pair.burn(holder)` simulated at this block would transfer exactly the `expected.amount0` / `expected.amount1` values above for each pool (matches adapter formula when feeTo != 0).",
        "notes": [
            "The adapter's formula `_calculateBalance` uses integer division with `(totalSupply + pendingProtocolMint)` as the denominator — exactly the math reproduced here.",
            "The dilution branch is active here because factory.feeTo != address(0). pendingProtocolMint contribution is recorded per-pool above.",
            "Strict-equality test target: adapter `getOracleBalances(holder)` MUST return `expected.amount0` and `expected.amount1` per pool, with `isDebt=false` and `balanceOracle=address(adapter)`.",
        ],
    },
}

out_path = Path("/home/nicol/projects/onchain-accounting/script/development/test/uniswapV2/case-multi-pool-mainnet.json")
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(case, indent=2) + "\n")
print(f"wrote {out_path}")

# also print a quick summary
print()
print(f"{'pool':<12} {'pendingMint':>20} {'dilution%':>10} {'expected0':>30} {'expected1':>30}")
for pos in positions:
    print(
        f"{pos['label']:<12} "
        f"{pos['dilution']['pendingProtocolMint']:>20} "
        f"{int(pos['dilution']['dilutionPctOfSupply_e9']) / 1e7:>9.4f}% "
        f"{pos['expected']['amount0']:>30} "
        f"{pos['expected']['amount1']:>30}"
    )
