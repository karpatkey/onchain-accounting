// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {IERC165, ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {BridgeAware} from "src/nav/BridgeAware.sol";

import {Mock_ERC20} from "test/mocks/tokens.sol";
import "src/errors.sol";

contract BridgeAwareHarness is BridgeAware {
    bool allowed;

    constructor() {
        allowed = true;
    }

    function setAllowed(bool _allowed) external {
        allowed = _allowed;
    }

    function _bridgeAware_ensureCanCall(bytes4 /* selector */ ) internal view override(BridgeAware) {
        require(allowed);
    }
}

contract BridgeAwareTest is Test {
    BridgeAwareHarness bridgeAware;
    Mock_ERC20 usdc;

    function setUp() public {
        usdc = new Mock_ERC20("USDC", 6);
        bridgeAware = new BridgeAwareHarness();
    }

    function test_permissions() public {
        bridgeAware.setAllowed(true);
        bridgeAware.bridgeStart(address(0x1));

        bridgeAware.setAllowed(false);
        vm.expectRevert();
        bridgeAware.bridgeStart(address(0x1));
    }

    function test_duplicateOperations() public {
        bridgeAware.bridgeStart(address(0x1));
        vm.expectRevert();
        bridgeAware.bridgeStart(address(0x1));
    }

    function test_nonDuplicateOperations() public {
        bridgeAware.bridgeStart(address(0x1));
        bridgeAware.bridgeStart(address(0x2));
    }

    function test_duplicateOperationsDifferentBlock() public {
        vm.roll(1);
        bridgeAware.bridgeStart(address(0x1));
        vm.roll(2);
        bridgeAware.bridgeStart(address(0x1));
    }

    function test_finalize() public {
        bytes32 id = bridgeAware.bridgeStart(address(0x1));
        vm.roll(10);
        bridgeAware.bridgeFinalize(id);
    }

    function test_finalize_sameBlock() public {
        bytes32 id = bridgeAware.bridgeStart(address(0x1));
        vm.expectRevert();
        bridgeAware.bridgeFinalize(id);
    }

    function test_finalize_disallowed() public {
        bytes32 id = bridgeAware.bridgeStart(address(0x1));
        vm.roll(10);
        bridgeAware.setAllowed(false);
        vm.expectRevert();
        bridgeAware.bridgeFinalize(id);
    }

    function test_counts() public {
        address asset = address(0x1);

        vm.roll(1);
        bytes32 id1 = bridgeAware.bridgeStart(asset);
        assert(bridgeAware.assetBridgingCounts(asset) == 1);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(2);
        bytes32 id2 = bridgeAware.bridgeStart(asset);
        assert(bridgeAware.assetBridgingCounts(asset) == 2);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(3);
        bridgeAware.bridgeFinalize(id2);
        assert(bridgeAware.assetBridgingCounts(asset) == 1);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(4);
        bytes32 id3 = bridgeAware.bridgeStart(asset);
        assert(bridgeAware.assetBridgingCounts(asset) == 2);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(5);
        bytes32 id4 = bridgeAware.bridgeStart(asset);
        assert(bridgeAware.assetBridgingCounts(asset) == 3);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(6);
        bridgeAware.bridgeFinalize(id1);
        assert(bridgeAware.assetBridgingCounts(asset) == 2);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(7);
        bridgeAware.bridgeFinalize(id3);
        assert(bridgeAware.assetBridgingCounts(asset) == 1);
        assert(bridgeAware.isAssetBridging(asset));

        vm.roll(8);
        bridgeAware.bridgeFinalize(id4);
        assert(bridgeAware.assetBridgingCounts(asset) == 0);
        assert(!bridgeAware.isAssetBridging(asset));
    }

    function test_isBridgeAware() public {
        address asset1 = address(0x1);
        address asset2 = address(0x2);

        vm.roll(1);
        bytes32 id1 = bridgeAware.bridgeStart(asset1);
        assert(bridgeAware.isAssetBridging(asset1));
        assert(!bridgeAware.isAssetBridging(asset2));

        bytes32 id2 = bridgeAware.bridgeStart(asset2);
        assert(bridgeAware.isAssetBridging(asset1));
        assert(bridgeAware.isAssetBridging(asset2));

        vm.roll(2);

        bridgeAware.bridgeFinalize(id1);
        assert(!bridgeAware.isAssetBridging(asset1));
        assert(bridgeAware.isAssetBridging(asset2));

        bridgeAware.bridgeFinalize(id2);
        assert(!bridgeAware.isAssetBridging(asset1));
        assert(!bridgeAware.isAssetBridging(asset2));
    }

    function test_bridgeOperations() public {
        address asset1 = address(0x1);

        bytes32 id1 = bridgeAware.bridgeStart(asset1);
        (bytes32 id, address asset, uint96 blockNumber) = bridgeAware.bridgeOperations(id1);
        assert(id == keccak256(abi.encodePacked(blockNumber, asset)));
        assert(asset == asset1);
        assert(blockNumber == block.number);

        vm.roll(2);
        bridgeAware.bridgeFinalize(id1);
        (id, asset, blockNumber) = bridgeAware.bridgeOperations(id1);
        assert(id == 0);
        assert(asset == address(0));
        assert(blockNumber == 0);
    }
}
