# FundConfig vs DeFi Kit: Zodiac Roles v2 permission diff

## Method

- Offline only. `diff.mjs` calls `allow.*` from `defi-kit/eth`, then `processPermissions` and `reconstructPermissions` from `zodiac-roles-sdk`. It never calls `planApply`, `postRole`, or any network API.
- FundConfig side: `docs/research/fund-infra/derivation-example.json` (schema `fundconfig-derivation/v1`, chainId 1, fork block 26500000, 8 positions, 31 leaves).
- DeFi Kit side: four calls. `morphoVaults.deposit({targets:[kpk_USDC_Prime]})`, `aave_v3.deposit({market: Pool, targets:["WETH"]})`, `aave_v3.borrow({market: Pool, targets:["USDC"]})`, `uniswap_v3.deposit({tokens:["USDC","WETH"], fees:["0.05%"]})`. These produced 18 variants.
- Trees are canonicalised (trailing Pass children trimmed, bare root MATCHES treated as null). Options (Send, DelegateCall, None) are compared separately from the tree.
- Matching: exact tree within each `target|selector` group. Leftovers are paired by a recursive count of identical non-Pass nodes at aligned positions.

Command (run from the worktree root):

```
node docs/research/fund-infra/defikit-diff/diff.mjs
```

Versions: `defi-kit@2.27.4`, resolved `zodiac-roles-sdk@3.4.8` (not 3.0.1 as assumed earlier), `zodiac-roles-deployments@3.3.0`.

Last run output:

```
FC variants 31, DK variants 18
status: {"fc_looser":12,"fc_only":17,"different":1,"dk_only":4,"mixed":1}
options on matched: {"fc_looser":14}
pos 0 morpho-vault kpk_USDC_Prime: {"fc_looser":4}
pos 1 aave-v3-supply Aave V3 WETH supply (collateral): {"fc_looser":3}
pos 2 aave-v3-borrow Aave V3 USDC borrow: {"fc_looser":3}
pos 3 uniswap-v3-swap Uniswap V3 USDC/WETH 0.05% swap: {"fc_only":4}
pos 4 uniswap-v3-lp Uniswap V3 USDC/WETH 0.05% LP: {"fc_looser":2,"different":1,"fc_only":2,"mixed":1}
pos 5 curve-pool Curve 3pool: {"fc_only":5}
pos 6 curve-gauge Curve 3pool gauge: {"fc_only":4}
pos 7 etherfi-assisted EtherFi withdrawal assistant: {"fc_only":2}
dk-only by source: {"uniswap_v3.deposit":2,"aave_v3.deposit":2}
wrote defikit-diff.json
```

Status `fc_looser` on a matched pair means the constraint tree is identical and FundConfig grants a broader option (Send vs None). `different` or `mixed` on a pair means a real constraint difference. `fc_only` and `dk_only` mean no pairing was found.

## Findings

### 1. Identical constraint trees on 12 covered entries

These entries match exactly on constraint tree (no parameter differences):

- `approve(address,uint256)` on USDC and WETH, from the Morpho, Aave, and Uniswap deposit variants (5 entries).
- Morpho `deposit(uint256,address)`, `redeem(uint256,address,address)`, `withdraw(uint256,address,address)` (3 entries).
- Aave `supply(address,uint256,address,uint16)` and `withdraw(address,uint256,address)` on the Pool (2 entries).
- Aave `borrow(address,uint256,uint256,uint16,address)` and `repay(address,uint256,uint256,address)` on the Pool (2 entries).

For these functions FundConfig is not looser on argument constraints.

### 2. Value transfer: FundConfig grants Send where DeFi Kit grants None

Every matched pair (14 in total: the 12 identical-tree entries plus Uniswap `mint` and `collect`) shows FundConfig `options: Send` and DeFi Kit `options: None`. `Send` lets the role send native value with the call. The DeFi Kit variants allow no value. This makes FundConfig looser on value transfer for every covered function.

This is not a constraint bug, but it is a real difference from DeFi Kit's stance. The derivation does not record whether `Send` is intentional. Decision for the user.

### 3. Uniswap V3 LP: four distinct cases

- `mint` (`0x88316456`): `different`. DeFi Kit uses an OR over both token orders (`token0=USDC,token1=WETH` OR `token0=WETH,token1=USDC`). FundConfig pins `token0 == USDC` and `token1 == WETH`. FundConfig is narrower. Because USDC `0xA0b8…` sorts below WETH `0xC02a…`, `token0=USDC` is the canonical order, so FundConfig's pin matches the pool. Not a bug, provided the strategy always encodes sorted order.
- `collect` (`0xfc6f7865`): `mixed`. FundConfig pins `tokenId` through the Custom checker `0x1d1499e6…`. DeFi Kit has PASS on that parameter. FundConfig is stricter on tokenId and also grants Send.
- `increaseLiquidity` (`0x219f5d17`) and `decreaseLiquidity` (`0x0c49ccbe`): FundConfig entries are `fc_only`. DeFi Kit entries are `dk_only` (they did not pair). The DeFi Kit `decreaseLiquidity` entry has zero root constraints (`dkRootConstraints: 0` in the JSON), so DeFi Kit permits it without argument constraints. The derivation summary says FundConfig constrains tokenId via the Custom checker, but the FundConfig tree was not inspected here.

### 4. DeFi Kit-only selectors (not in FundConfig)

- Aave Pool `0x5a3b74b9` = `setUserUseReserveAsCollateral(address,bool)`. Verified by selector computed with ethers `id()`.
- Aave incentives `0x8164cc65…bfcb`, selector `0x236300dc` = `claimRewards(address[],uint256,address,address)`. Verified by selector computed with ethers `id()`.
- Uniswap `increaseLiquidity` and `decreaseLiquidity` in the DeFi Kit form (see finding 3).

These are functions DeFi Kit grants and FundConfig does not. This is coverage breadth, not looseness on functions FundConfig covers.

### 5. FundConfig-only coverage (not covered by DeFi Kit's recipes)

- Position 3, Uniswap SwapRouter02 `exactInputSingle` (`0x04e45aaf`) and its USDC approve. DeFi Kit's `cowswap.swap` is a different target. Not covered by the kit.
- Position 5, Curve 3pool `add_liquidity` (`0x4515cef3`) and `remove_liquidity` (`0xecb586a5`), plus DAI and USDT approves. No curve key in the kit. Not covered.
- Position 6, Curve gauge `deposit` (`0xb6b55f25`), `withdraw` (`0x2e1a7d4d`), CRV minter `mint` (`0x6a627842`), 3Crv approve. Not covered.
- Position 7, EtherFi assistant `requestWithdraw` (`0x745400c9`) and `claimWithdraw` (`0xb13acedd`), both DelegateCall, no conditions. No etherfi key in the kit. Not covered.

These are kit coverage gaps, not FundConfig findings.

## Verdict

For the functions both sides cover with identical constraint trees (12 entries), FundConfig is at least as strict on arguments. It is looser on value: it grants `Send` on every covered entry where DeFi Kit grants none.

On the Uniswap LP position, FundConfig is stricter than DeFi Kit: it pins token order in `mint` and tokenId in `collect`. DeFi Kit's `decreaseLiquidity` has no root constraints, so FundConfig is stricter there too, if the FundConfig tree confirms the tokenId pin.

Overall: FundConfig is at least as strict for overlapping function arguments. The one clear looseness is value transfer (`Send`) on all covered entries.

## Derivation bugs

None found in this comparison. The `Send` option on all covered entries is a question for the user, not a bug report. No reproducing test was written, per the assignment (validate, report, do not fix).

## Open items

- Confirm the FundConfig tree for `decreaseLiquidity` (`0x0c49ccbe`) shows a tokenId constraint, and confirm the meaning of `dkRootConstraints`.
- Decide whether `Send` on FundConfig entries is intended.
- Confirm the strategy always encodes the USDC/WETH mint in sorted order.
- Not verified: whether DeFi Kit `morphoVaults.deposit` also covers `mint` and `withdraw` variants beyond what FundConfig derives.
