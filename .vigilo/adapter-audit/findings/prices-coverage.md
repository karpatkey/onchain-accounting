# Oracle Price Feed Coverage — All 27 Custom Feeds

| Feed | Rate Source | How Combined | Freshness Gate | Verdict |
|------|-------------|--------------|----------------|---------|
| CrossRate | Chainlink X/USD × Chainlink Y/X | mulDiv(xToUsd, yToX, 10^yToXDecimals) | Both heartbeats independently checked | CLEAN |
| ETHPlus | Reserve Protocol basketHandler.price() (low bound), basketsNeeded/totalSupply | basketUnitsPerToken × basketPriceUSD / 1e18 / 1e10 | min(lastSave()) < RESERVE_PROTOCOL_HEARTBEAT + status==SOUND | CLEAN |
| ETHx | StaderStakePoolsManager.getExchangeRate() (totalETH/totalETHx, live on-chain) × ETH/USD | BaseCustomPriceFeed: rate × baseAnswer / 1e18 | ETH/USD Chainlink heartbeat only; rate is live-computed (no timestamp needed) | CLEAN |
| LDO | Chainlink LDO/ETH × Chainlink ETH/USD | mulDiv(ldoToEth, ethToUsd, 10^ldoToEthDecimals) | Both heartbeats independently checked | CLEAN |
| NXM | RAMM.getInternalPrice() (TWAP ETH/NXM, 18 dec) × ETH/USD | mulDiv(ethPerNxm, ethToUsd, 1e18) | ETH/USD Chainlink heartbeat only; RAMM rate is TWAP (manipulation-resistant, no push timestamp) | CLEAN |
| RWIV | IERC4626(RWIV).convertToAssets(10^vaultDecimals) × USDC/USD | mulDiv(rwivToUsdc, usdcToUsd, 10^vaultDecimals) | USDC/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| ankrETH | IankrETH.ratio() (ankrETH/ETH, 18 dec) inverted × ETH/USD | ETH/USD × 1e18 / ratio | ETH/USD Chainlink heartbeat only; ratio() is keeper-updated with no timestamp | MEDIUM (M-03) |
| cbETH | IcbETH.exchangeRate() (ETH/cbETH, 18 dec) × ETH/USD | BaseCustomPriceFeed: rate × baseAnswer / 1e18 | ETH/USD Chainlink heartbeat; exchangeRate() is Coinbase-managed accumulator (low staleness risk) | CLEAN |
| cbETH_L2 | Chainlink cbETH/ETH × Chainlink ETH/USD | mulDiv(cbEthToEth, ethToUsd, 10^cbEthToEthDecimals) | Both heartbeats independently checked | CLEAN |
| eETH | Chainlink weETH/ETH ÷ IweETH.getRate() (eETH/weETH) × ETH/USD | eETH/ETH = weEthToEth × 1e18 / weEthToEEthRate; then × ethToUsd / 1e18 | Both Chainlink heartbeats; getRate() is live on-chain ratio (no timestamp needed) | CLEAN |
| ezETH (L1) | RestakeManager.calculateTVLs() (aggregates internal sub-oracles) / totalSupply × ETH/USD | rate × baseAnswer / 1e18 | ETH/USD Chainlink heartbeat only; Renzo sub-oracle freshness not checked | MEDIUM (M-01) |
| ezETH_L2 | xRenzoDeposit.getRate() (keeper-relayed L1→L2 rate) × ETH/USD | mulDiv(ezEthRate, ethToUsd, 1e18) | ETH/USD Chainlink heartbeat only; keeper rate has no age check | MEDIUM (M-02) |
| osToken | OsTokenVaultController.convertToAssets(1e18) (underlying/osToken, 18 dec) × underlying/USD | BaseCustomPriceFeed: rate × baseAnswer / 1e18 | base feed heartbeat; convertToAssets is live on-chain accumulator | CLEAN |
| rETH | IrETH.getExchangeRate() (ETH/rETH, 18 dec) × ETH/USD | BaseCustomPriceFeed: rate × baseAnswer / 1e18 | ETH/USD Chainlink heartbeat; Rocket Pool rate is live on-chain (no push timestamp) | CLEAN |
| rsETH | IRsETHRateProvider.getLatestRate() (ETH/rsETH, 18 dec) × ETH/USD | BaseCustomPriceFeed: rate × baseAnswer / 1e18 | ETH/USD Chainlink heartbeat; rate provider is a live on-chain ratio | CLEAN |
| rsETH_L2 | Chainlink rsETH/ETH × Chainlink ETH/USD | mulDiv(rsEthToEth, ethToUsd, 10^rsEthToEthDecimals) | Both heartbeats independently checked | CLEAN |
| sDAI | MakerDAO Pot.chi() (27 dec RAY, continuously accruing) × DAI/USD | mulDiv(daiToUsd, chi, 10^27) | DAI/USD Chainlink heartbeat; chi is live on-chain DSR accumulator | CLEAN |
| sGHO | IERC4626(sGHO).convertToAssets(10^vaultDecimals) × GHO/USD | mulDiv(sghoToGho, ghoToUsd, 10^vaultDecimals) | GHO/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| sUSDS | IERC4626(sUSDS).convertToAssets(10^vaultDecimals) × USDS/USD | mulDiv(sUsdsToUsds, usdsToUsd, 10^vaultDecimals) | USDS/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| sUSDe | IERC4626(sUSDe).convertToAssets(10^vaultDecimals) × USDe/USD | mulDiv(sUsdeToUsde, usdeToUsd, 10^vaultDecimals) | USDe/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| sXDAI | IERC4626(sXDAI).convertToAssets(10^vaultDecimals) × xDAI/USD | mulDiv(xDaiToUsd, underlyingValue, 10^vaultDecimals) | xDAI/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| syrupUSDC | IERC4626(syrupUSDC).convertToAssets(10^vaultDecimals) × USDC/USD | mulDiv(syrupToUsdc, usdcToUsd, 10^vaultDecimals) | USDC/USD Chainlink heartbeat | LOW (L-02 ERC4626 donation) |
| syrupUSDC_L2 | Chainlink syrupUSDC/USDC × Chainlink USDC/USD | mulDiv(syrupToUsdc, usdcToUsd, 10^syrupToUsdcDecimals) | Both heartbeats independently checked | CLEAN |
| weETH | Chainlink weETH/ETH × Chainlink ETH/USD | mulDiv(weEthToEth, ethToUsd, 10^weEthToEthDecimals) | Both heartbeats independently checked | CLEAN |
| weETH_L2 | Chainlink weETH/eETH × ETH/USD (eETH≈ETH 1:1 assumed) | mulDiv(weEthToEeth, ethToUsd, 10^weEthToEethDecimals) | Both heartbeats checked; eETH≈ETH parity not validated | MEDIUM (M-04) |
| wstETH | IwstETH.stEthPerToken() × Chainlink stETH/ETH × Chainlink ETH/USD | stEthPerToken × stEthToEthRate / 1e18 → ethPerWstEth; × ethToUsd / 1e18 | Both Chainlink heartbeats; stEthPerToken is live on-chain | CLEAN |
| wstETH_L2 | Chainlink wstETH/ETH × Chainlink ETH/USD | mulDiv(wstEthToEth, ethToUsd, 10^wstEthToEthDecimals) | Both heartbeats independently checked | CLEAN |

## Prior Finding Disposition

| Prior ID | Description | Status |
|----------|-------------|--------|
| M-2 (ankrETH staleness) | ankrETH ratio() no freshness guard | CORROBORATED → M-03 in this audit |
| M-4 (ERC4626 convertToAssets vs previewRedeem) | ERC4626 feeds use convertToAssets | PARTIALLY REFUTED for on-chain exploit (NAVCalculator is read-only eth_call); downgraded to LOW (L-02) |
| M-3 (rate-only-feed sentinel domination) | sentinel path unreachable / updatedAt from Chainlink base | REFUTED as a high-risk issue; noted as LOW informational (L-01) |
| ezETH L2 keeper staleness | xRenzoDeposit.getRate() no age check | CORROBORATED → M-02 in this audit |
| sUSDe/sUSDS share-unit | prior verifier ruled CORRECT | CONFIRMED CORRECT — `10^_vaultDecimals` is the right one-share unit |

## New Findings Summary

| ID | Severity | Feed | Title |
|----|----------|------|-------|
| M-01 | Medium | ezETH (L1) | Renzo internal oracle freshness unverified |
| M-02 | Medium | ezETH_L2 | Keeper-relayed rate has no freshness guard |
| M-03 | Medium | ankrETH | ratio() has no freshness guard |
| M-04 | Medium | weETH_L2 | eETH≈ETH 1:1 parity assumption unvalidated |
| L-01 | Low | All rate-only feeds | Sentinel updatedAt path unreachable for BaseCustomPriceFeed class |
| L-02 | Low | sGHO, sUSDe, sUSDS, syrupUSDC, RWIV, sXDAI | ERC4626 convertToAssets donation sensitivity (read-only context, no on-chain exploit) |
