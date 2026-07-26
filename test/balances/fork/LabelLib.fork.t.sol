// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";

/// @title LabelLibForkTest
/// @notice Exercises the hardened {LabelLib} through a REAL call site on a fork rather than a mock: the Fluid vaults
///         meta-adapter's `_assetSymbol` → `LabelLib.symbol(token, "?")`, against the real mainnet wstETH/USDC T1
///         vault and the real VaultResolver.
/// @dev Why this call site specifically. `FluidVaultsMetaBalanceAdapter.positionLabels` wraps its leaf derivation in
///      `try this.vaultPairSymbols(vault)` — an EXTERNAL self-call, so a revert anywhere in the chain (including a
///      return-data decode failure, which an in-frame `try`/`catch` cannot catch) is contained and the label collapses
///      to the category alone. So the LabelLib gap does not revert Fluid's labels read; it silently discards the whole
///      leaf, including the side that IS readable and Fluid's per-vault id.
///
///      That makes the hardening's effect here precise and observable: with a hostile/legacy token on one side, the
///      leaf goes from `["Vault"]` (everything lost) to `["Vault", "?/USDC #<id>"]` (readable side + id preserved),
///      which is exactly the `"?"`-placeholder convention LabelLib documents for a joined multi-token leaf.
contract LabelLibForkTest is BalanceAdapterTestBase {
    address public constant VAULT = 0x51197586F6A9e2571868b6ffaef308f3bdfEd3aE; // wstETH/USDC T1
    address public constant VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant FORK_BLOCK = 23_950_000;

    FluidVaultsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Registers only `registerWsteth`-selected assets so the token under test falls through the adapter's
    ///      registry-first lookup and actually reaches `LabelLib.symbol`. `_assetSymbol` prefers the NAV registry, so
    ///      a registered token never touches the library.
    function _deploy(bool registerWsteth, bool registerUsdc) internal {
        address[] memory assetsList = new address[](2);
        uint256 n;
        if (registerWsteth) assetsList[n++] = WSTETH;
        if (registerUsdc) assetsList[n++] = USDC;
        address[] memory trimmed = new address[](n);
        for (uint256 i; i < n; ++i) {
            trimmed[i] = assetsList[i];
        }
        balances = _deployBalancesForAdapter(trimmed);
        meta = new FluidVaultsMetaBalanceAdapter(VAULT_RESOLVER, "Fluid", address(balances));
    }

    function _leaf(address vault) internal view returns (string[] memory) {
        return meta.positionLabels(abi.encode(vault));
    }

    /// @notice Baseline: with neither side registered, both symbols come from `LabelLib.symbol` on the real tokens and
    ///         the real pair leaf still renders. Guards against the hardening breaking legitimate metadata.
    function test_realVault_pairLeafStillRendersThroughLabelLib() public {
        _deploy(false, false);
        string[] memory l = _leaf(VAULT);
        assertEq(l.length, 2, "real vault must still produce a leaf");
        assertEq(l[0], "Vault");
        assertEq(
            bytes(l[1])[0], bytes("w")[0], "leaf should start with the wstETH symbol read live via LabelLib.symbol"
        );
        // Neither side may degrade to the "?" placeholder for real, well-behaved tokens.
        for (uint256 i; i < bytes(l[1]).length; ++i) {
            assertTrue(bytes(l[1])[i] != bytes("?")[0], "no side should fall back for real tokens");
        }
    }

    /// @notice The regression: a legacy `bytes32`-returning `symbol()` on one side of a real vault.
    /// @dev This is the class of failure an in-frame `try`/`catch` cannot catch. Before the LabelLib hardening,
    ///      `LabelLib.symbol` propagated a decode failure out of `vaultPairSymbols`, Fluid's external-self-call
    ///      `try`/`catch` swallowed it, and the ENTIRE leaf — readable side and vault id included — was lost to
    ///      `["Vault"]`. Now the unreadable side degrades to `"?"` and everything else survives.
    ///      Fails (leaf collapses to length 1) if `LabelLib`'s ABI-head validation is removed.
    function test_bytes32SymbolOnOneSide_degradesToPlaceholderNotCollapse() public {
        _deploy(false, true); // USDC registered (symbol from the registry), wstETH must go through LabelLib
        vm.mockCall(WSTETH, abi.encodeWithSignature("symbol()"), abi.encode(bytes32("wstETH")));

        string[] memory l = _leaf(VAULT);
        assertEq(l.length, 2, "leaf must survive an undecodable symbol() on one side");
        assertEq(l[0], "Vault");
        assertEq(bytes(l[1])[0], bytes("?")[0], "unreadable side renders as the ? placeholder");
        assertTrue(_contains(l[1], "USDC"), "readable side must be preserved");
        assertTrue(_contains(l[1], "#"), "Fluid vault id must be preserved");
    }

    /// @notice Same, for a `symbol()` that succeeds with ZERO returndata — the ERC-1967-proxy-to-no-code shape.
    function test_emptyReturndataSymbolOnOneSide_degradesToPlaceholder() public {
        _deploy(false, true);
        vm.mockCall(WSTETH, abi.encodeWithSignature("symbol()"), "");

        string[] memory l = _leaf(VAULT);
        assertEq(l.length, 2, "leaf must survive empty returndata from symbol()");
        assertEq(bytes(l[1])[0], bytes("?")[0]);
        assertTrue(_contains(l[1], "USDC"), "readable side must be preserved");
    }

    /// @notice A `symbol()` returning an absurd declared length must also degrade rather than collapse the leaf.
    function test_absurdDeclaredLengthSymbol_degradesToPlaceholder() public {
        _deploy(false, true);
        // offset 0x20, length 2^40 — a valid-looking head whose payload cannot possibly be present.
        vm.mockCall(WSTETH, abi.encodeWithSignature("symbol()"), abi.encodePacked(uint256(0x20), uint256(1 << 40)));

        string[] memory l = _leaf(VAULT);
        assertEq(l.length, 2, "leaf must survive an absurd declared length");
        assertEq(bytes(l[1])[0], bytes("?")[0]);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
