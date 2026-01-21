// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalances} from "src/balances/IBalances.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/balance_oracles.sol";

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
    Mock_PriceOracleCustom public usdcOracle;
    Mock_ERC20 public dai;
    Mock_PriceOracleChainlink public daiOracle;
    Mock_ERC20 public weth;
    Mock_PriceOracleCustom public wethOracle;
    Mock_PriceOracleChainlink public ethOracle;
    Mock_ChainlinkL2SequencerUptimeFeed public sequencerUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeedDown public sequencerUptimeFeedDown;
    Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod public sequencerUptimeFeedtWithinGracePeriod;

    // balance oracle
    Mock_CustomBalanceOracle public mockBalanceOracle;

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
        vm.warp(block.timestamp + 3600); // To pass the L2 sequencer default grace period set at deployment
        usdcOracle = new Mock_PriceOracleCustom("USDC", address(usdc), 100_000_000, 8);
        daiOracle = new Mock_PriceOracleChainlink("DAI", 100_000_000, 8);
        wethOracle = new Mock_PriceOracleCustom("WETH", address(weth), 324_057_000_000, 8);
        ethOracle = new Mock_PriceOracleChainlink("ETH", 324_057_000_000, 8);
        sequencerUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeed();
        sequencerUptimeFeedDown = new Mock_ChainlinkL2SequencerUptimeFeedDown();
        sequencerUptimeFeedtWithinGracePeriod = new Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod();

        mockBalanceOracle = new Mock_CustomBalanceOracle();
        mockBalanceOracle.setBalance(address(usdc), safe, int256(123 * 10 ** usdc.decimals()));
        mockBalanceOracle.setBalance(address(dai), safe, int256(456 * 10 ** dai.decimals()));
        mockBalanceOracle.setBalance(address(weth), safe, int256(789 * 10 ** weth.decimals()));
        address[] memory underlyingAssets = new address[](3);
        underlyingAssets[0] = address(usdc);
        underlyingAssets[1] = address(dai);
        underlyingAssets[2] = address(weth);
        mockBalanceOracle.setUnderlyingAssetsSupported(underlyingAssets);
        mockBalanceOracle.setPositionMetadata(
            IBalanceOracleCustom.PositionMetadata({
                protocol: "Mock Protocol", position: "Mock Position", positionType: "Mock Type"
            })
        );

        // https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades?tab=readme-ov-file#coverage-testing
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, safe, address(sequencerUptimeFeed)))
        );
        nav = NAVCalculator(navProxy);

        nav.grantRole(OPERATOR, ops);
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);

        // Register native address with price feed
        nav.registerAsset(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        // Note: The native address balance oracle is handled by ERC20DefaultOracle which is set up in initialize()
        // The ERC20DefaultOracle automatically handles native balances, so we don't need to add it explicitly
        // However, if tests need it, they can access it via nav.erc20DefaultOracle()

        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);

        nav.registerAsset(address(dai), address(daiOracle), IPrices.PriceType.Chainlink, 86_400);
        nav.addBalanceOracle(address(dai), address(dai), IBalances.OracleType.ERC20);

        nav.registerAsset(address(weth), address(wethOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalanceOracle(address(weth), address(weth), IBalances.OracleType.ERC20);

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

    function setupNAVCalculatorWithParams(address admin_, address safe_, address chainlinkUptimeFeed_)
        public
        returns (NAVCalculator)
    {
        address navCalculatorImpl = address(new NAVCalculator());
        address navCalculatorProxy = UnsafeUpgrades.deployUUPSProxy(
            navCalculatorImpl, abi.encodeCall(NAVCalculator.initialize, (admin_, safe_, chainlinkUptimeFeed_))
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
        vm.label(address(usdcOracle), "usdcPrice");
        vm.label(address(daiOracle), "daiPrice");
        vm.label(address(wethOracle), "wethPrice");
        vm.label(address(nav), "nav");
    }

    ///  Returns the current NAV of the fund
    function t_currentNav() public view returns (uint256 currentNav) {
        INAVCalculator.NAV memory navReading = nav.getAccountNav(address(safe), address(0));
        return uint256(navReading.value);
    }

    function t_readNav() internal view returns (INAVCalculator.NAV memory navReading) {
        navReading = nav.getAccountNav(address(safe), address(0));
    }

    // ERC20 transfer events
    event Transfer(address indexed from, address indexed to, uint256 value);

    error AccessControlUnauthorizedAccount(address, bytes32);

    // ERC20 insufficent allowance error
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
}
