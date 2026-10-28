# ADR 0029 rollout — deploy log

Live record of the rollout's on-chain steps (PRs #354 + #358). Procedure: `ADR0029_ROLLOUT.md`.

## EOA deploys — `01_2` (2026-10-28)

From the kpk-deployer `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72`, CREATE2 through `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
Same addresses on every chain: PriceFeedLib `0xaBCC2526a6ebCFE637EB2B660410adff60eCFB73`, NAV implementation
`0x1D7a950730620795434216827B8D15B6Fc37e79a` (NavRegistryLib `0x3D5369B0b2044d62a8f643bf9a2b8CC03775934D` unchanged,
already deployed). Nothing live changes until each chain's Council batch executes (`upgradeToAndCall`).

| Chain | PriceFeedLib tx | NAV implementation tx |
|---|---|---|
| 1 Ethereum | `0x5413d5c02fe81b1e6028f15a94cf54de65d8525974a6110488138bcd39121b49` | `0xd00d5addbe1c4f0618595124f29dba78540c6bdb19ab6e893d6149afaaa24c38` |
| 10 Optimism | `0xf2d179cff487eb86f572a5cd7aceb28a03b202fb458b6cc54f98582b8a295130` | `0x7dba87715bd6d405a4997660941bbe86698d6f9ccb22f34db5cceaf41a02d574` |
| 56 BNB Chain | `0x18662a7c07c92fef09cc990d89ab57a8fc866a2945e066e320459c8fa2da68cf` | `0x824c9119a6f9048af56156da8ec1b0384339176b745bb3238e328349c3b7a8b1` |
| 100 Gnosis | `0x6e7a2adb0bb782829ab04ccbf8b70357370a825f214f1d7cd0986647cc5210c4` | `0x4195437387f143479f8c20cc94078470821299fee21f4b728213e121e3cac537` |
| 130 Unichain | `0xbb573e397d36718cf8027aa0dcb43a044f3c07b5d57df6291fa7a1892e9b0396` | `0xdce775f95b136519668de36798b8d4e8cf7f2872065938511c504942a91a5e7c` |
| 137 Polygon | `0xcae659fdd4a648bd89ab284116fe39c9ec83eb6b1e3d06ca79308bd160ab3ef4` | `0xb46395c9008ba6937007c0412e4a1804520772aa27865756305884bfdebb34d3` |
| 143 Monad | `0xcb50d18dd6af9ad19a916692b04e1e696e73712ffec5d80c93c53660389c940a` | `0x69c339c04ab7591c2b0acf1c5e790f8dd96b917cbebcc7a0fd566010fb8c4d32` |
| 146 Sonic | `0xcd67352a580a9db1737641595d0b4d2c86a9195641d0e7ef9fd5cfb2c610087a` | `0x1f05f0269ecd70a3b7a9de5eac2781d109f4af6885cbd49fa01a76302cde0ee3` |
| 196 X Layer | `0xcf2f8a3355a3fed7d8b8bce2d0674080c3f5103d2da62409ad96df216f0a5982` | `0x5ed7518687979d97dd7429274264098fb319cd1157b94af12b36c4e2b557ccbe` |
| 204 opBNB | `0x5eaea73851e147d5f8390322541b78f1b616814e2841c0e986c153a559cc2685` | `0xdff9bf07baab2a8aa5bb5579d66740dae1e45067e963314277e93052d143b539` |
| 480 World Chain | `0x6dca4759dafd7ba6e83fe29ab00956c613a72ecd49498239f8be27ee7090cf15` | `0x9f72927341162b109f91724c3147dcd2488aa2f06866a53845de7c5aa7c1fe40` |
| 999 HyperEVM | `0xf2722320006dda585c1509888cf3a5ed85e56aa86aa9a94f05f746a1b31f06c9` | `0xd29b9db12c5d36e0ada41b5f21cb4f40a06b83ba985f99cb39f69b739eb53ca0` |
| 5000 Mantle | `0x36674b98622806127d38655b03ab14a04dbfd6eb69d630b0afb006e8b9a90c0d` | `0x814db58971c2d69db6c62d5c2f59d25d1e30a570ca216b81818b7de40cfd6e50` |
| 5042 Arc | `0x0493577ba570f1649a6532a2dffb22102d9d5bb0cb50cc1eb92f0da8d147f767` | `0x8ca695a18cbc7ec4ba54743af8fffc921ebcfbd967a4c07cfbd3b2d48a4db47e` |
| 8453 Base | `0x7501973072c17c0f2f75f328ae283c9d0e56f2e30637494d0bde80c4d438b87a` | `0xf0ba032fe4608e80baa84df9537089bc0c42692e8fe7d55a9e460e1db40c4c7f` |
| 9745 Plasma | `0x1a3f09d143d51ae203bd076d68b0d4771c4df634e510e985dd974df91df58b27` | `0x74890db4ef354c119fdea255ab651f8248ffae65e5688f118612317521e779bc` |
| 16661 0G | `0x3a2ee6c026f9b1a6f3441a6ebb3d4b0cf3da2ff984913e9faf625f179269b24f` | `0x830ac2fa48c9f7bccb85a1650e53212484f5e995a47d2542a4a88c1ea76beff5` |
| 42161 Arbitrum | `0x72891af696f2806bc45c7c33feea3fc32bd7cca97fadeb7539176826ef091c0a` | `0xb9d381f96ae3802908bfe09d72074db9a4f509d2cfced9a42ed34ba2f483b7c0` |
| 42220 Celo | `0x03107be5a45a453ecaef9675ddb733dc45b85ef339cf860485310a8e36f6d4c4` | `0x01686851816b87412aff9dc2574a546bffe853ff177202ed7160b0d1526713fa` |
| 43111 Hemi | `0x750da45aff507c19bfc8800421620069de6c638fb496b2cc6d3d0ffea0613bd0` | `0x9644324a1f86ad8cfed79da717c12bedbac59189e2fbb09589593eba63b38663` |
| 43114 Avalanche | `0x5c9ea3680dff4aa3d80015e39a597a44eafb6c17f49c3c16c12a3f5b41b50a91` | `0x65987b9695d6335a72d42ec880167bf81f3e492c39bdb7555c0bccfc24ce01a1` |
| 57073 Ink | `0x89720b6b54822d0a1d0fc44b62096272f9442032e3162de6d6929241ea741499` | `0x53385c2266bf2023898f5aa3529b9d878c56ec191b9f2a62957147fba781cc7f` |
| 59144 Linea | `0x2be8546a35fa42d9b74ee37a67c80894d25be13160a1dae5f5ce8ee24e1ff8e8` | `0x2e8dddf378fcc12141685c0363abfdb30fdab961f681bab3cb9d165a72dd2752` |
| 80094 Berachain | `0xf9d3a63cbcb65d980e3bb5cfd8387d46f523ec698192679e91078c66d578eee5` | `0x8ea4ac25745b76380d43a53db96e8ed027039afbccbdceeb7be433e7272476d3` |
| 534352 Scroll | `0x587bb91eb83448d15cd017fe5e2322ce1c816ca11901c2ad995b390667c9e385` | `0xee7754de771b8416c1fca11bd5edde5e366d0262e86cd12dbad7c684c8a0618a` |
| 4663 Robinhood | `0x1de9aad168abb4be18d73281dcbae270aa4d219c26d96f3ffaf048c3b975fb1c` | `0x683f25d644ffbff4bb75198cc19fad8d6faf42ad67b0765c08eaa695f5c69b00` |

25 chains + Robinhood, every transaction status 1, code verified at both addresses after each deploy.
- World Chain (480): the first post-deploy code read returned empty (RPC lag); both receipts were status 1 and the code
  was present on re-read.
- HyperEVM (999): deployed with `--legacy` with HyperEVM big blocks switched ON for the deployer (Hyperliquid
  `evmUserModify`), then switched OFF again.
- Robinhood (4663): no chain config in this repo, so `01_2` cannot run there; chain 130's two CREATE2 inputs were
  replayed byte-identical from its broadcast. Code hashes equal chain 130's (PriceFeedLib
  `0xf73d64e47f904d64f2169e1c21d62d35302470477b4128cb57ff6fa2a1b24262`, implementation
  `0x5d35998279f6d972a0a5213f9b853faca6087d260e471b2446ccf3869d88e651`).

## Custom price feeds — `03` (2026-10-28)

Retired the replaced keys with `retire_custom_feeds.py` (old addresses kept under `retiredCustomPriceFeeds`), then `03`
from the deployer (plain CREATE). Checked after each chain: every configured feed's record has code, none is still the
old address, and every replaced feed returns the same `getLatestPrice()` as the feed it replaces (the two new WBTC
monitors price WBTC at ~$81k). `bytecode_audit.py`: every new feed CURRENT; the old ones RETIRED_BUT_REGISTERED until
each chain's Council batch swaps them. Arc's first attempt sent nothing: a `03` simulation run before it wrote the
predicted address into the record, so the broadcast logged "already deployed"; the key was reset and redeployed.

### 1 Ethereum — 32 feeds

| Feed | Address | Tx |
|---|---|---|
| LDO | `0xa215bb87448d69f5389bbd58fe87f47f05cbb880` | `0x240773423d58024a0e3dcc9352b0e9ea0c9c4a6c03f3fce29cec1e96c5f2af2b` |
| sUSDS | `0x49722f676dc72274c78f1f188a5347b84636647d` | `0x10a3edf83565df4b54f0d42ee903b6fcd5005523f097430a7274443b9215d4f8` |
| sUSDe | `0x234b2c5a02860e2fa67b4aaa018794583c04de4b` | `0x0f35dd6df820f2468497f33ebb2fe1482852b6f6598c09b0977b4c411c9fab03` |
| syrupUSDC | `0x7bc96e9455426dc88e467bc065eea8abe99a7bfb` | `0xeaee9668cf24b8f956003f0d95256aa31e5552d0b8d942d93d9b5541203ed3f7` |
| syrupUSDG | `0x61e39bfdb1274b939836177a4f4236f7280d8a88` | `0x61e5ff013c85adbc08cef332b457a822a7e1c684d64f2ccb5cc4e0b96068a951` |
| syrupUSDT | `0x25b10769a991cedd1daf522ff36aafbe2510a827` | `0x4ce9f7d694b069409fe7a7c2a2f61e853d55afadeaeb58eb6d2934cc510e261e` |
| LBTC | `0x676bcb3ca68769b00b1a7fb8e70928de7a6652ba` | `0xad6c384ca39d373011528c30b5f6a900eaa87b4bb6134b70252b2f9ba0aedc01` |
| LBTCCrossRateMarket | `0x04fbb733112300c09125e91cc500fe4033df7842` | `0x0e63ac0c31832fa1d26374062f30d2dcf0bb3506d85576ed3e26a5622ee2ab37` |
| spUSDC | `0x7f3cebdecf9ea0e3ef98e4c47247b0e898ca0e2a` | `0xfc16db0ce6a269101089dc98102448c2393c4bc6bc3ceeaa6469455f616431ff` |
| spUSDT | `0x95dbbac54fd9f24bc7d470e7af28fe9cbb518d9f` | `0x15ad270bc43d7e457c19859d81a221b101f28b295a75b12cecca0afc24110cc4` |
| spETH | `0x64c77d734ad06d007536c31b2ff78f11c6ae9fd1` | `0xfcd2f88cb0251f79d7fe4c607a690ac9ee8647643664a8118e361c2173cd1b1c` |
| sDAI | `0x4a1e7c2f32dbb348e197eadbffe5b82f7597f632` | `0xbcbf82ad45954f6c0f373462c5cbcb1e9cf24d03bddfa497264ab7c38a990596` |
| RWIV | `0x9f754fc5611b20978cd971c0eeef53bb258972d6` | `0xd4c1336a6cc03890a0d3d6f4081f94910abdf45cde2256e487466a2c32fa884e` |
| sGHO | `0x6e51baac4cd0bd3b0134596ffe9fad91ea12458f` | `0x619f64d1a73db48b780e3f04b6a9a39a6c2c0d3a7ff3120172c9624d21394780` |
| wstETH | `0xe2a290e65af7288c2fec0a37078b3f95c135141a` | `0xafd1c61fca92f53ec7ae173621aeacdac6c450d72542c88430ef79d24c9d3eea` |
| stETHFundamental | `0x73f88dc4ac4d66752430f481778863e9d8d28c1b` | `0xb621cf697e5eb5ad3d0cc9168904d8c5c56453e630f94a6268ad682b9488c440` |
| stETHCrossRate | `0x3aec270a31a05f497714a963564b22cc39e007ee` | `0xb827ed483064aef6144b1b5e2628c06d868d660227f7431f95ba19f24dd3438e` |
| lsETH | `0xa60f3f3f992062b0d3a4c06169e4998f1a21bb5c` | `0x24c48baf12fd6b43ad85fefd2f0565f6deab03e4ed6c0e8e3e89e0e78ecc0bb1` |
| rETH | `0x9307dbff0edca57541d21b2383fb5a778f0fff21` | `0xdc0b772363e499cd2e84c091808a61d52a46396ea6b2f1c8d7039d3cb48ceb92` |
| weETH | `0xa564909d2815ebc6f3449f3f6105cd8b07c29373` | `0x673700e3ed633b3865b56342a32c50f359820bb3d7fe4e898e889c76dec7e3cd` |
| rsETH | `0xb5a6993335b046c373a637b4200446613302d9ff` | `0x2d6fa5d7f9fc060894db7900a27db841b4a288862becc3b47460158333de82c4` |
| eETH | `0x9925829882b1b562e5c527c2f519f63b1136e7bd` | `0x94ae71cc39824bf4649833bc54c9fb0e687858aa07a6ba26b772b9b452aafdf3` |
| ETHx | `0x1e5c8c1cd602e9af8e32c8f0db6df12bff07ef39` | `0x4372f4915abe1030dfae6972d32b28a243ec9db4120007a10c535e4619edd9d5` |
| osETH | `0x51da3d0e890a63c9c960b21d19fcd3f81ea4d75e` | `0x12e7092068b0ea937eb4d205db88e04019ecfc62471df1bc82d9428981590727` |
| ETHxCrossRate | `0x2471fc16cadd1dea6448080a6a0be7f9987a8626` | `0x2cd1302ad8d4613acf162e013cd3d8b3c82e13f3c378342e43faa09ed9c5261e` |
| rETHCrossRate | `0xb0c579815a3888a47dc3346e151e80f893d758d9` | `0x50c86a1fddf6b9ffc0212ed0fb119a9750d3abba530a2931ec707756bab2c6ba` |
| ankrETH | `0xb24353a022bc964601d93b31e7b4aa4ba5411fa6` | `0x1acc94e9d7eb4c1016ec60dbb100c6b6d607103a570a2df907a04b57f652bdfe` |
| wARS | `0x11618048a0746967c31d103a52985bf59edbb6aa` | `0xccb541de397a486847a081cbe447b55f9957568ed37ce7a726b644c759324f55` |
| WBTCCrossRate | `0xea2a1daee93626d2f8f06dcb74f808b77a13513d` | `0x520a07934a6053df8bb5532e65b011173cc452e954eb787ee0710714311364b2` |
| WBTCCrossRateRedstone | `0x2b6b43852cf181e04c620feb55b602d3b1da8663` | `0x9d29611afc35e99bff41922445f3626c68003f413179292dd7d328af20a80939` |
| NXM | `0x5481f435dd6dde913ca0fbea4f1b3bda883df44c` | `0x2db631c695ac5e4711ce022157e07fdf000bc60c53c87a513fd39721cf02970c` |
| wNXM | `0xb716d5b601f2979201bcb2ddecf241d836d9e7eb` | `0x5ef49d812516d9f972e8dbc4ba6679bcf677e4d43271f4099068d77f72f8d09a` |

### 42161 Arbitrum — 6 feeds

| Feed | Address | Tx |
|---|---|---|
| wstETH_L2 | `0x7fff8527dfcb5d4e00cfa81c2af702d15b1c0521` | `0x1ddbd22ca7ca23e1be59f5a9845a101b02d328793ae45603fa6f1d79f60a3343` |
| weETH_L2 | `0xf9a11fd76d76de5f5b2c85b33b9741bd9177409b` | `0xf621f61510f50f6d5f95b80eff635a2c72e74b7f3f2dae5265b65bd43299ec09` |
| rsETH_L2 | `0x1682f4dc1d22e3e8ee25f80e1823f433f7518d7b` | `0x976a4d5ce37d7c437cd5e55b68539b92fa86f999d538e1f1fbf521248bc21fe5` |
| syrupUSDC_L2 | `0x9675780d906203f7df6a8e98fc27f11f8c4294a6` | `0xf5aaebb1955b994597ca4d705e426596ba47e183e66dd5186737d808e0e0932a` |
| weETHCrossRate | `0x2105d9f888bc05512660050b8f8ef844f15f1e05` | `0x61230ebd8fc7e4bf45cb9416816e69f77e2b558c282454fd2d197c20e3c83ae5` |
| rsETHCrossRate | `0x19a35cb4fc26e5b9ed4d8d3ab01967d6f5291e3c` | `0xdb25bb6c6a6dd2518156293bf9c2ff939f92333beb1dbe4800c76f4586afe00b` |

### 8453 Base — 4 feeds

| Feed | Address | Tx |
|---|---|---|
| wstETH_L2 | `0x1f6fb1969b79e3a43e63103c39e13457a5340a64` | `0x23a17b01a4637e3e7e2b6307981d827e11b95d5944fdb5b06c7ab77e23ee1729` |
| weETH_L2 | `0x92bda9ff899f2e37832943e72fe2d5ed9f5fa7fd` | `0x3187b4b6302bd6d564ba5ec913fa415f8752c7fb870e3df4d4ba43b702e87347` |
| cbETH_L2 | `0xaa3e29e95e8e573a6b07640a0ee2b597b21c7774` | `0xc2ed6716da444b337916b16390f0dfadbdba17c98258bc99af7704b1f5714b61` |
| weETHCrossRate | `0x4bc85b1f615258d0a35f01ddfa44df5ce8cf8764` | `0xc4b8febb3ec459dbe445b8537f8316033e6678aa08f8c57035be12d4896acb80` |

### 100 Gnosis — 3 feeds

| Feed | Address | Tx |
|---|---|---|
| sXDAI | `0xbef120b82415f113f8997ff1c17360c678359187` | `0x868b10ed31717b8e719bac85f8b48ffd34ef476b66a76d04cbdefadb7b1e9871` |
| wstETH_L2 | `0x8b9f7493100fbd1d2b70f873ce270c586d49fe45` | `0x47decdf22868a09570f7b19bc276ec1db87d6f4027f168a2a30b7883afe0c743` |
| osGNO | `0xc3b09c9a8b7c7bce3442c22a834069df737713ad` | `0x46283fa47b4499aa1292a10366f414540f87687279dff5128e08e5eb4cc9870d` |

### 5042 Arc — 1 feeds

| Feed | Address | Tx |
|---|---|---|
| wARS | `0x3edc5a9b0db866779aca1710b4f27179e160920e` | `0x9093bae63fd00a48b33dcf93dbc0644e59b575ca1111627c17a1725266f7ac41` |
