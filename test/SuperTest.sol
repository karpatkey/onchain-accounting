// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/balance_adapters.sol";

/// A test setup that includes a lot of boilerplate used by various tests,
/// such as setting up various accounts, contracts, tokens and price oracles
abstract contract SuperTest is Test {
    uint256 constant ZERO_PERCENT = 0;
    uint256 constant FIVE_PERCENT = 5 ether;
    uint256 usdPrice = 1e8;

    // generic account declarations
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address notInvestor = makeAddr("notInvestor");

    // role-based account declarations
    address admin = makeAddr("admin");
    address ops = makeAddr("ops");
    address navCalculatorManager = makeAddr("navCalculatorManager");

    uint64 subscriptionRequestTtl = 24 hours;
    uint64 redemptionRequestTtl = 24 hours;

    // tokens
    Mock_ERC20 public usdc;
    Mock_CustomPriceFeed public usdcAdapter;
    Mock_ERC20 public dai;
    Mock_PriceOracleChainlink public daiAdapter;
    Mock_ERC20 public weth;
    Mock_CustomPriceFeed public wethAdapter;
    Mock_PriceOracleChainlink public ethAdapter;
    Mock_ChainlinkL2SequencerUptimeFeed public sequencerUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeedDown public sequencerUptimeFeedDown;
    Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod public sequencerUptimeFeedtWithinGracePeriod;

    // balance adapter
    Mock_CustomBalanceAdapter public mockBalanceAdapter;

    // fund
    address safe = makeAddr("safe");
    address feeRecipient = makeAddr("feeRecipient");
    NAVCalculator nav;

    function setupAll() internal {
        setupTokens();
        setupNav();
        setupFund();
        setupAllowances();
        setupLabels();
    }

    function setupTokens() internal {
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);
    }

    function setupNav() internal {
        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // In tests there's no chain state, so etch the runtime code there so DELEGATECALL succeeds.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715, priceFeedLibImpl.code);
        vm.etch(0xB47b227eA8B8bcFD3c2e5D54d2ff7Ffa3c1B138D, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

        vm.warp(block.timestamp + 2 hours); // To pass the L2 sequencer default grace period set at deployment
        usdcAdapter = new Mock_CustomPriceFeed("USDC", address(usdc), 100_000_000, 8);
        daiAdapter = new Mock_PriceOracleChainlink("DAI", 100_000_000, 8);
        wethAdapter = new Mock_CustomPriceFeed("WETH", address(weth), 324_057_000_000, 8);
        ethAdapter = new Mock_PriceOracleChainlink("ETH", 324_057_000_000, 8);
        sequencerUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeed();
        sequencerUptimeFeedDown = new Mock_ChainlinkL2SequencerUptimeFeedDown();
        sequencerUptimeFeedtWithinGracePeriod = new Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod();

        mockBalanceAdapter = new Mock_CustomBalanceAdapter();

        // https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades?tab=readme-ov-file#coverage-testing
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(sequencerUptimeFeed), "ETH"))
        );
        nav = NAVCalculator(navProxy);

        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);

        // Native is pre-registered in initialize; set price feed only
        nav.addPriceFeed(
            address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
        );
        // Note: The native address balance adapter is handled by ERC20DefaultAdapter which is set up in initialize()
        // The ERC20DefaultAdapter automatically handles native balances, so we don't need to add it explicitly
        // However, if tests need it, they can access it via nav.erc20DefaultAdapter()

        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);

        nav.registerAsset(address(dai), address(daiAdapter), IPrices.PriceType.Chainlink, 86_400);

        nav.registerAsset(address(weth), address(wethAdapter), IPrices.PriceType.Custom, type(uint256).max);

        vm.stopPrank();
    }

    function setupFund(
        uint256 feePercent,
        uint256 managementFeeRate,
        uint256 redemptionFeeRate,
        uint256 performanceFeeRate
    ) internal {
        // Fund setup removed - no longer using KpkShares
    }

    function setupFund() internal {
        setupFund(ZERO_PERCENT, 100, 50, 1000); // 1% management, 0.5% redemption, 10% performance
    }

    // forge-lint: disable-next-line(mixed-case-function) -- test helper; NAV in name is intentional
    function setupNAVCalculatorWithParams(address admin_, address chainlinkUptimeFeed_) public returns (NAVCalculator) {
        address navCalculatorImpl = address(new NAVCalculator());
        address navCalculatorProxy = UnsafeUpgrades.deployUUPSProxy(
            navCalculatorImpl, abi.encodeCall(NAVCalculator.initialize, (admin_, chainlinkUptimeFeed_, "ETH"))
        );

        return NAVCalculator(navCalculatorProxy);
    }

    function setupAllowances() internal {
        // Token approvals removed - no longer using KpkShares
    }

    function setupLabels() internal {
        vm.label(address(usdc), "USDC");
        vm.label(address(dai), "DAI");
        vm.label(address(weth), "WETH");
        vm.label(address(usdcAdapter), "usdcPrice");
        vm.label(address(daiAdapter), "daiPrice");
        vm.label(address(wethAdapter), "wethPrice");
        vm.label(address(nav), "nav");
    }

    ///  Returns the current NAV of the fund
    // forge-lint: disable-next-line(mixed-case-function) -- test helper prefix t_
    function t_currentNav() public view returns (uint256 currentNav) {
        INAVCalculator.NAV memory navReading = nav.getAccountNav(address(safe), address(0));
        return uint256(navReading.value);
    }

    // forge-lint: disable-next-line(mixed-case-function) -- test helper prefix t_
    function t_readNav() internal view returns (INAVCalculator.NAV memory navReading) {
        navReading = nav.getAccountNav(address(safe), address(0));
    }

    // ERC20 transfer events
    event Transfer(address indexed from, address indexed to, uint256 value);

    error AccessControlUnauthorizedAccount(address, bytes32);

    // ERC20 insufficent allowance error
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
}
