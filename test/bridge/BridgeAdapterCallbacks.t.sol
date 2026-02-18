// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {AcrossBridgeAdapter} from "src/bridge/adapters/AcrossBridgeAdapter.sol";
import {CcipBridgeAdapter} from "src/bridge/adapters/CcipBridgeAdapter.sol";
import {GnosisBridgeAdapter} from "src/bridge/adapters/GnosisBridgeAdapter.sol";
import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/bridge/adapters/interfaces/ICcipBridgeAdapter.sol";
import {IAcrossBridgeAdapter} from "src/bridge/adapters/interfaces/IAcrossBridgeAdapter.sol";
import {IStargateBridgeAdapter} from "src/bridge/adapters/interfaces/IStargateBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title BridgeAdapterCallbacksTest
/// @notice Tests that each bridge adapter's protocol callback (ccipReceive, lzReceive, handleAcrossMessage, onTokenTransfer)
///         works when invoked via BridgeEscrow fallback and reverts when invoked directly on the adapter.
contract BridgeAdapterCallbacksTest is BridgeScenarioHelper {
    uint64 public constant SOURCE_CHAIN_SELECTOR = 5009297550715157269;
    uint64 public constant DEST_CHAIN_SELECTOR = 3734403246176062136;
    uint16 public constant SOURCE_LZ_CHAIN_ID = 101;
    uint16 public constant DEST_LZ_CHAIN_ID = 111;
    uint256 public constant SRC_POOL_ID = 1;
    uint256 public constant DST_POOL_ID = 1;
    uint64 public constant GNOSIS_CHAIN_ID = 100;
    int64 public constant DEFAULT_RELAYER_FEE_PCT = 0.01e18;

    /// @notice Expected callback selectors (must match adapter's callback method; tests fail if signature changes)
    bytes4 public constant EXPECTED_CCIP_CALLBACK_SELECTOR = bytes4(0x85572ffb); // ccipReceive(Any2EVMMessage)
    bytes4 public constant EXPECTED_ACROSS_CALLBACK_SELECTOR = bytes4(0x0ea1f938); // handleAcrossMessage(...)
    bytes4 public constant EXPECTED_STARGATE_CALLBACK_SELECTOR = bytes4(0x001d3567); // lzReceive(uint16,bytes,uint64,bytes)
    bytes4 public constant EXPECTED_GNOSIS_CALLBACK_SELECTOR = bytes4(0x0bad0c90); // onTokenTransfer(address,bytes32,bytes)

    // ============ Callback selector consistency (fail if any adapter's callback method changes) ============

    /// @notice If any adapter's protocol callback is renamed or its signature changes, this test fails
    function test_allCallbackSelectors_matchAdapterMethods() public pure {
        assertEq(
            CcipBridgeAdapter.ccipReceive.selector,
            EXPECTED_CCIP_CALLBACK_SELECTOR,
            "CCIP: ccipReceive selector must match documented value"
        );
        assertEq(
            AcrossBridgeAdapter.handleAcrossMessage.selector,
            EXPECTED_ACROSS_CALLBACK_SELECTOR,
            "Across: handleAcrossMessage selector must match documented value"
        );
        assertEq(
            StargateBridgeAdapter.lzReceive.selector,
            EXPECTED_STARGATE_CALLBACK_SELECTOR,
            "Stargate: lzReceive selector must match documented value"
        );
        assertEq(
            GnosisBridgeAdapter.onTokenTransfer.selector,
            EXPECTED_GNOSIS_CALLBACK_SELECTOR,
            "Gnosis: onTokenTransfer selector must match documented value"
        );
    }

    /// @notice Documents and tests the bytes4 callback selectors from script/config/README.md "Bridge adapters: callbacks" table
    function test_documentedCallbackSelectors_bytes4() public pure {
        bytes4 ccip = bytes4(0x85572ffb);
        bytes4 across = bytes4(0x0ea1f938);
        bytes4 stargate = bytes4(0x001d3567);
        bytes4 gnosis = bytes4(0x0bad0c90);

        assertEq(CcipBridgeAdapter.ccipReceive.selector, ccip, "CCIP bytes4");
        assertEq(AcrossBridgeAdapter.handleAcrossMessage.selector, across, "Across bytes4");
        assertEq(StargateBridgeAdapter.lzReceive.selector, stargate, "Stargate bytes4");
        assertEq(GnosisBridgeAdapter.onTokenTransfer.selector, gnosis, "Gnosis bytes4");
    }

    // ============ CCIP callback tests ============

    /// @notice CCIP: callback via escrow fallback releases funds to account
    function test_ccip_callback_releasesFundsWhenCalledViaEscrow() public {
        assertEq(
            CcipBridgeAdapter.ccipReceive.selector,
            EXPECTED_CCIP_CALLBACK_SELECTOR,
            "CCIP callback selector must match expected"
        );
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockCcipRouter destRouter = new MockCcipRouter();
        Mock_ERC20 destLink = new Mock_ERC20("LINK", 18);
        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CcipBridgeAdapter()),
            abi.encodeCall(
                CcipBridgeAdapter.initialize,
                (admin, address(destEscrow), address(destRouter), address(destLink), "1.0.0")
            )
        );
        CcipBridgeAdapter destAdapter = CcipBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destAdapter.setChainSelectorMapping(SOURCE_CHAIN_ID, SOURCE_CHAIN_SELECTOR);
        destAdapter.setChainSelectorMapping(DEST_CHAIN_ID, DEST_CHAIN_SELECTOR);
        destEscrow.authorizeAdapter(destAdapterProxy);
        vm.stopPrank();
        _registerCallbackModule(destEscrow, CcipBridgeAdapter.ccipReceive.selector, destAdapterProxy);

        uint256 balanceBefore = usdc.balanceOf(account);
        uint64 msgId = destRouter.addMessageForDelivery(messagePayload, address(usdc), amount);
        usdc.mint(address(destRouter), amount);
        destRouter.deliverMessage(msgId, address(destEscrow));

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account), balanceBefore + amount, "account received bridged amount");
    }

    /// @notice CCIP: calling ccipReceive on the adapter directly reverts (must go via escrow)
    function test_ccip_callback_revertsWhenCalledDirectlyOnAdapter() public {
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000 * 10 ** usdc.decimals()
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(123)),
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(address(this)),
            data: messagePayload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        MockCcipRouter r = new MockCcipRouter();
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CcipBridgeAdapter()),
            abi.encodeCall(
                CcipBridgeAdapter.initialize, (admin, address(bridgeEscrow), address(r), address(0), "1.0.0")
            )
        );
        _authorizeAdapter(adapterProxy);
        CcipBridgeAdapter adapter = CcipBridgeAdapter(adapterProxy);

        vm.prank(address(r));
        vm.expectRevert(abi.encodeWithSelector(ICcipBridgeAdapter.InvalidBridgeData.selector));
        adapter.ccipReceive(ccipMessage);
    }

    // ============ Across callback tests ============

    /// @notice Across: callback via escrow fallback releases funds to account
    function test_across_callback_releasesFundsWhenCalledViaEscrow() public {
        assertEq(
            AcrossBridgeAdapter.handleAcrossMessage.selector,
            EXPECTED_ACROSS_CALLBACK_SELECTOR,
            "Across callback selector must match expected"
        );
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePool destSpokePool = new MockSpokePool();
        address destAdapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new AcrossBridgeAdapter()),
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destSpokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            )
        );
        vm.prank(admin);
        destEscrow.authorizeAdapter(destAdapterProxy);
        _registerCallbackModule(destEscrow, AcrossBridgeAdapter.handleAcrossMessage.selector, destAdapterProxy);

        uint256 balanceBefore = usdc.balanceOf(account);
        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destEscrow), messagePayload);
        usdc.mint(address(destSpokePool), amount);
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account), balanceBefore + amount, "account received bridged amount");
    }

    /// @notice Across: calling handleAcrossMessage on the adapter directly reverts (must go via escrow)
    function test_across_callback_revertsWhenCalledDirectlyOnAdapter() public {
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000 * 10 ** usdc.decimals()
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        MockSpokePool spokePool = new MockSpokePool();
        address adapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new AcrossBridgeAdapter()),
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), address(spokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            )
        );
        _authorizeAdapter(adapterProxy);
        AcrossBridgeAdapter adapter = AcrossBridgeAdapter(payable(adapterProxy));

        vm.prank(address(spokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.MessageReceiveFailed.selector));
        adapter.handleAcrossMessage(address(usdc), invoiceData.amount, true, address(this), messagePayload);
    }

    // ============ Stargate callback tests ============

    /// @notice Stargate: callback via escrow fallback releases funds to account
    function test_stargate_callback_releasesFundsWhenCalledViaEscrow() public {
        assertEq(
            StargateBridgeAdapter.lzReceive.selector,
            EXPECTED_STARGATE_CALLBACK_SELECTOR,
            "Stargate callback selector must match expected"
        );
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockStargateRouter destRouter = new MockStargateRouter();
        address destEndpoint = address(destRouter);
        address destAdapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter()),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destRouter), destEndpoint, "1.0.0")
                )
            )
        );
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(payable(destAdapterProxy));
        vm.startPrank(admin);
        destAdapter.setChainIdMapping(SOURCE_CHAIN_ID, SOURCE_LZ_CHAIN_ID);
        destAdapter.setChainIdMapping(DEST_CHAIN_ID, DEST_LZ_CHAIN_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, SRC_POOL_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        destEscrow.authorizeAdapter(destAdapterProxy);
        vm.stopPrank();
        _registerCallbackModule(destEscrow, StargateBridgeAdapter.lzReceive.selector, destAdapterProxy);

        uint256 balanceBefore = usdc.balanceOf(account);
        uint64 msgId = destRouter.addSwapForDelivery(messagePayload);
        usdc.mint(address(destRouter), amount);
        destRouter.deliverMessage(msgId, address(destEscrow), address(usdc), amount);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account), balanceBefore + amount, "account received bridged amount");
    }

    /// @notice Stargate: calling lzReceive on the adapter directly reverts (must go via escrow)
    function test_stargate_callback_revertsWhenCalledDirectlyOnAdapter() public {
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000 * 10 ** usdc.decimals()
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        MockStargateRouter r = new MockStargateRouter();
        address adapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter()),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize, (admin, address(bridgeEscrow), address(r), address(r), "1.0.0")
                )
            )
        );
        _authorizeAdapter(adapterProxy);
        StargateBridgeAdapter adapter = StargateBridgeAdapter(payable(adapterProxy));

        vm.prank(address(r));
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.MessageReceiveFailed.selector));
        adapter.lzReceive(SOURCE_LZ_CHAIN_ID, "", 123, messagePayload);
    }

    // ============ Gnosis callback tests ============

    /// @notice Gnosis: callback via escrow fallback releases funds to account
    function test_gnosis_callback_releasesFundsWhenCalledViaEscrow() public {
        assertEq(
            GnosisBridgeAdapter.onTokenTransfer.selector,
            EXPECTED_GNOSIS_CALLBACK_SELECTOR,
            "Gnosis callback selector must match expected"
        );
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        MockOmnibridge destOmnibridge = new MockOmnibridge();
        MockAMB destAmb = new MockAMB();
        address destAdapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new GnosisBridgeAdapter()),
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destOmnibridge), address(destAmb), "1.0.0")
                )
            )
        );
        vm.prank(admin);
        destEscrow.authorizeAdapter(destAdapterProxy);
        _registerCallbackModule(destEscrow, GnosisBridgeAdapter.onTokenTransfer.selector, destAdapterProxy);

        uint256 balanceBefore = usdc.balanceOf(account);
        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destEscrow), amount, messagePayload);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account), balanceBefore + amount, "account received bridged amount");
    }

    /// @notice Gnosis: calling onTokenTransfer on the adapter directly reverts (must go via escrow)
    function test_gnosis_callback_revertsWhenCalledDirectlyOnAdapter() public {
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000 * 10 ** usdc.decimals()
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 valueBytes32 = bytes32(invoiceData.amount);

        MockOmnibridge omnibridge = new MockOmnibridge();
        MockAMB amb = new MockAMB();
        address payable adapterProxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    address(new GnosisBridgeAdapter()),
                    abi.encodeCall(
                        GnosisBridgeAdapter.initialize,
                        (admin, address(bridgeEscrow), address(omnibridge), address(amb), "1.0.0")
                    )
                )
            ));
        _authorizeAdapter(adapterProxy);
        GnosisBridgeAdapter adapter = GnosisBridgeAdapter(adapterProxy);

        vm.prank(address(omnibridge));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.onTokenTransfer(address(usdc), valueBytes32, messagePayload);
    }
}
