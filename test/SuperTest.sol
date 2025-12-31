// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "src/nav/NAVCalculator.sol";
import "src/prices/Prices.sol";
import "src/balances/Balances.sol";
import "src/fund/kpkShares.sol";
import "src/errors.sol";

import "test/mocks/tokens.sol";
import "test/mocks/price_oracles.sol";
import "test/mocks/balance_oracles.sol";

/// A test setup that includes a lot of boilerplate used by various tests,
/// such as setting up various accounts, contracts, tokens and price oracles
abstract contract SuperTest is Test {
    uint256 constant zeroPercent = 0;
    uint256 constant fivePercent = 5 ether;
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
    KpkShares public shares;
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
                protocol: "Mock Protocol",
                position: "Mock Position",
                positionType: "Mock Type"
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

        // This price oracle could be added here, but then it couldn't be removed later because by default its' balance
        // oracle is added in the Balances.sol constructor and that triggers a sanity check of the removePrice()
        // function, affecting the test_read_noAssets_doesNotRevert test
        // nav.addPrice(address(nav.NATIVE_ADDRESS()), address(ethOracle),
        // IPrices.PriceType.Chainlink,type(uint256).max);
        // No need to add the balance oracle for the native token, as it is added in the constructor

        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);

        nav.addPrice(address(dai), address(daiOracle), IPrices.PriceType.Chainlink, 86_400);
        nav.addBalance(address(dai), address(dai), IBalances.BalanceType.ERC20);

        nav.addPrice(address(weth), address(wethOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(weth), address(weth), IBalances.BalanceType.ERC20);

        vm.stopPrank();
    }

    function setupFund(
        uint256 feePercent,
        uint256 managementFeeRate,
        uint256 redemptionFeeRate,
        uint256 performanceFeeRate
    ) internal {
        // https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades?tab=readme-ov-file#coverage-testing
        address sharesImpl = address(new KpkShares());
        address sharesProxy = UnsafeUpgrades.deployUUPSProxy(
            sharesImpl,
            abi.encodeCall(
                KpkShares.initialize,
                (
                    KpkShares.ConstructorParams({
                        asset: address(usdc),
                        admin: admin,
                        name: "kpk",
                        symbol: "kpk",
                        safe: safe,
                        subscriptionRequestTtl: subscriptionRequestTtl,
                        redemptionRequestTtl: redemptionRequestTtl,
                        feeReceiver: feeRecipient,
                        managementFeeRate: managementFeeRate,
                        redemptionFeeRate: redemptionFeeRate,
                        performanceFeeModule: address(0),
                        performanceFeeRate: performanceFeeRate
                    })
                )
            )
        );
        shares = KpkShares(sharesProxy);

        vm.startPrank(admin);
        shares.grantRole(OPERATOR, ops);
        shares.grantRole(OPERATOR, admin);

        vm.startPrank(ops);
        shares.grantRole(INVESTOR, alice);
        shares.grantRole(INVESTOR, bob);
        shares.grantRole(INVESTOR, carol);
        vm.stopPrank();
    }

    function setupFund() internal {
        setupFund(zeroPercent, 100, 50, 1000); // 1% management, 0.5% redemption, 10% performance
    }

    function setupFundWithParams(KpkShares.ConstructorParams memory params) public returns (KpkShares) {
        // https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades?tab=readme-ov-file#coverage-testing
        address sharesImpl = address(new KpkShares());
        address sharesProxy = UnsafeUpgrades.deployUUPSProxy(sharesImpl, abi.encodeCall(KpkShares.initialize, (params)));

        return KpkShares(sharesProxy);
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
        address[] memory addrs = new address[](5);
        addrs[0] = address(alice);
        addrs[1] = address(bob);
        addrs[2] = address(carol);
        addrs[3] = address(admin);
        addrs[4] = address(ops);

        Mock_ERC20[] memory tokens = new Mock_ERC20[](4);
        tokens[0] = usdc;
        tokens[1] = dai;
        tokens[2] = weth;
        tokens[3] = Mock_ERC20(address(shares));

        for (uint256 a = 0; a < addrs.length; a++) {
            vm.startPrank(addrs[a]);
            for (uint256 t = 0; t < tokens.length; t++) {
                tokens[t].approve(address(shares), type(uint256).max);
            }
            vm.stopPrank();
        }

        vm.prank(safe);
        usdc.approve(address(shares), type(uint256).max);
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

    function t_setupFund_revertsWithInvalidParams(KpkShares.ConstructorParams memory params) public {
        address sharesImpl = address(new KpkShares());
        vm.expectRevert(InvalidArguments.selector);
        UnsafeUpgrades.deployUUPSProxy(sharesImpl, abi.encodeCall(KpkShares.initialize, (params)));
    }

    ///  Returns the current NAV of the fund
    function t_currentNav() public view returns (uint256 currentNav) {
        INAVCalculator.NAV memory navReading = nav.read(address(safe));
        return uint256(navReading.usd);
    }

    /// Converts shares to assets with the current NAV
    function t_sharesToAssets(uint256 sharesAmount) public view returns (uint256 assetsToRedeem) {
        uint256 currentNav = t_currentNav();
        return shares.sharesToAssets(sharesAmount, currentNav, address(usdc));
    }

    /// Runs a subscription request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_requestSubscription(address beneficiary, uint256 usdcAmount)
        external
        returns (uint256 requestId, uint256 sharesToIssue)
    {
        return this.t_requestSubscriptionAs(beneficiary, usdcAmount, beneficiary);
    }

    /// Runs a subscription request, as a given caller
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_requestSubscriptionAs(address beneficiary, uint256 usdcAmount, address caller)
        external
        returns (uint256 requestId, uint256 sharesToIssue)
    {
        uint256 currentNav = t_currentNav();
        sharesToIssue = shares.previewSubscription(usdcAmount, currentNav, address(usdc));

        vm.startPrank(caller);
        requestId = shares.requestSubscription(usdcAmount, currentNav, beneficiary, address(usdc));
        vm.stopPrank();
    }

    /// Runs a redemption request (shares-based)
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_requestRedemption(address beneficiary, uint256 sharesAmount)
        external
        returns (uint256 requestId, uint256 assetsToRedeem)
    {
        return this.t_requestRedemptionAs(beneficiary, sharesAmount, beneficiary);
    }

    /// Runs a redemption request, as a given caller (shares-based)
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_requestRedemptionAs(address beneficiary, uint256 sharesAmount, address caller)
        external
        returns (uint256 requestId, uint256 assetsToRedeem)
    {
        uint256 currentNav = t_currentNav();
        assetsToRedeem = shares.sharesToAssets(sharesAmount, currentNav, address(usdc));

        // Ensure beneficiary has approved the caller to spend their shares
        if (beneficiary != caller) {
            vm.prank(beneficiary);
            shares.approve(caller, sharesAmount);
        } else {
            // If beneficiary is the same as caller, approve the contract to spend shares
            vm.prank(beneficiary);
            shares.approve(address(shares), sharesAmount);
        }

        uint256 assetsOut = shares.sharesToAssets(sharesAmount, currentNav, address(usdc));
        vm.startPrank(caller);
        requestId = shares.requestRedemption(sharesAmount, assetsOut, address(usdc), beneficiary);
        vm.stopPrank();
    }

    /// Runs a redemption request (USDC-based)
    /// Converts the USDC amount to shares using the current state, then calls the shares-based redeem
    function t_requestRedemptionInUsdc(address beneficiary, uint256 usdcAmount)
        external
        returns (uint256 requestId, uint256 sharesToRedeem)
    {
        return this.t_requestRedemptionAsInUsdc(beneficiary, usdcAmount, beneficiary);
    }

    /// Runs a redemption request as a given caller (USDC-based)
    /// Converts the USDC amount to shares using the current state, then calls the shares-based redeem
    function t_requestRedemptionAsInUsdc(address beneficiary, uint256 usdcAmount, address caller)
        external
        returns (uint256 requestId, uint256 sharesToRedeem)
    {
        uint256 currentNav = t_currentNav();
        sharesToRedeem = shares.assetsToShares(usdcAmount, currentNav, address(usdc));
        return this.t_requestRedemptionAs(beneficiary, sharesToRedeem, caller);
    }

    /// Approves a subscription request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_approveSubscription(uint256 reqId) external {
        uint256[] memory approveRequests = new uint256[](1);
        uint256[] memory rejectRequests = new uint256[](0);
        approveRequests[0] = reqId;
        vm.prank(ops);
        shares.processRequests(approveRequests, rejectRequests, address(usdc), usdPrice);
    }

    /// Rejects a subscription request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_rejectSubscription(uint256 reqId) external {
        uint256[] memory approveRequests = new uint256[](0);
        uint256[] memory rejectRequests = new uint256[](1);
        rejectRequests[0] = reqId;
        vm.prank(ops);
        shares.processRequests(approveRequests, rejectRequests, address(usdc), usdPrice);
    }

    /// Cancels a subscription request, with a given caller
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_cancelSubscriptionAs(uint256 reqId, address caller) external {
        vm.prank(caller);
        shares.cancelSubscription(reqId);
    }

    /// Cancels a redemption request, with a given caller
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_cancelRedemptionAs(uint256 reqId, address caller) external {
        vm.prank(caller);
        shares.cancelRedemption(reqId);
    }

    /// Approves a redemption request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_approveRedemptionWithFees(
        uint256 reqId,
        uint256 redemptionFeeRate,
        uint256 managementFeeValue,
        uint256 performanceFeeValue
    ) public {
        uint256[] memory approveRequests = new uint256[](1);
        uint256[] memory rejectRequests = new uint256[](0);

        approveRequests[0] = reqId;

        vm.startPrank(ops);
        shares.processRequests(approveRequests, rejectRequests, address(usdc), usdPrice);
        vm.stopPrank();
    }

    /// Approves a redemption request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_approveRedemption(uint256 reqId, uint256 redemptionFeeRate) external {
        t_approveRedemptionWithFees(reqId, redemptionFeeRate, 0, 0);
    }

    function t_readNav() internal view returns (INAVCalculator.NAV memory navReading) {
        navReading = nav.read(address(safe));
    }

    /// Rejects a subscription request
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_rejectRedemption(uint256 reqId) external {
        uint256[] memory approveRequests = new uint256[](0);
        uint256[] memory rejectRequests = new uint256[](1);
        rejectRequests[0] = reqId;

        vm.prank(ops);
        shares.processRequests(approveRequests, rejectRequests, address(usdc), usdPrice);
    }

    // Note: Fee charging functions may not be available in kpkShares interface
    // These functions are commented out until the interface is clarified
    /*
    /// Charges performance fees
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_chargePerformanceFees(address payee, uint256 value) external {
        IkpkShares.Fee[] memory fees = new IkpkShares.Fee[](1);
        uint256 nonce = shares.performanceFeeNextNonce(payee);
        fees[0] = IkpkShares.Fee({value: value, payee: payee, nonce: nonce});

        vm.prank(ops);
        shares.chargePerformanceFees(fees);
    }

    /// Charges management fees
    /// @dev marked as public so that assertions such as vm.expectRevert can still function properly (must be called
    /// with `this.`)
    function t_chargeManagementFees(address payee, uint256 value) external {
        IkpkShares.Fee[] memory fees = new IkpkShares.Fee[](1);
        uint256 nonce = shares.managementFeeNextNonce(payee);
        fees[0] = IkpkShares.Fee({value: value, payee: payee, nonce: nonce});

        vm.prank(ops);
        shares.chargeManagementFees(fees);
    }
    */

    // ERC20 transfer events
    event Transfer(address indexed from, address indexed to, uint256 value);

    error AccessControlUnauthorizedAccount(address, bytes32);

    // ERC20 insufficent allowance error
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
}
