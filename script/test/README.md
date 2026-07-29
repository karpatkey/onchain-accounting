# Deployment Script Tests

This directory contains comprehensive tests for the deployment infrastructure.

## Test Files

### DeploymentTest.fork.t.sol
Tests for core deployment functionality:
- ✅ Create2Deployer deployment and functionality
- ✅ CREATE2 address computation
- ✅ Deterministic proxy deployment
- ✅ Cross-chain address consistency
- ✅ UUPS upgradeability for NAVCalculator and BridgeEscrow
- ✅ Safe delegatecall simulation
- ✅ Event emission
- ✅ Multiple sequential deployments
- ✅ Duplicate salt prevention
- ✅ Initialization protection

### Test02_DeployProxies.t.sol

> **⚠️ Known coverage hole — `Test02a_DeployProxies` does not run locally.**
> Its `setUp()` reverts `RpcUrlNotSet()` without an RPC URL in the environment, and forge reports the whole
> contract as a single failing "test". **All 19 test functions in it are therefore skipped**, not run and passed.
> CI supplies the URL (see `getAlchemyUrl`, which prefers the `*_URL` env vars) so they do execute there — but on
> a developer machine a local `forge test --no-match-path "*fork*"` reports **three** failures, not the two
> by-design `LibraryPinConsistency` ones, and the third is this.
>
> Consequences, stated so nobody re-derives them:
> - A local green run is not evidence these 19 tests pass. Check CI.
> - The mutation sweep that produced `AUDIT-mutation-sweep.md` could not reach any guard these tests cover; that
>   is recorded there as an explicit hole in the sweep rather than a clean result.
> - If you are counting expected local failures while working through the hardening wave, the count is 3.

Tests for the `02_DeployProxies` deploy script:
- ✅ CREATE2 determinism (canonical deployer yields the same proxy address regardless of caller)
- ✅ AtomicProxyDeployer behavior
- ✅ Proxy initialization flow
- ✅ Diverging addresses across different deployers

### UpgradeNAVCalculatorPins.t.sol
Tests the library-pin guard in `script/upgrade/UpgradeNAVCalculator`, which repoints a **live** proxy at the
implementation it deploys:
- ✅ each source-vs-pin assertion, tripped individually through an injected pin, so both stay covered after the
  pin regeneration lands (they are the only checks that catch a pin gone stale against current source)
- ✅ the impl bytecode is linked against both pins (each pin isolated in its own test)
- ✅ both pinned addresses hold code on this chain (each isolated)
- ✅ the deploy path actually goes through the guard — fails if the guard call is deleted, which blanking the
  guard body does not catch. (The suite can prove the call exists, not that it precedes the broadcast: relocating
  it below `new` reverts the same external call. `forge script` broadcasts nothing when the run reverts.)
- ✅ the composite guard invokes the source-match family, constructed so only that family can object
- ✅ the harness is inert as a script: its `setUp()` reverts, and `forge script` calls `setUp()` before any entry
  point, so `--sig deployGuardedNavImplementation()` is closed too. Scope: this covers the *harness*-rooted paths.
  The test contract's own `setUp()` cannot revert (`forge test` needs it), so running a deploying test function
  via `forge script --broadcast` remains possible — a generic property of any test contract that constructs a
  broadcasting helper, with a blast radius of one orphan implementation (no address recorded, no Safe TX, no proxy
  repointed)
- ✅ the deploy wrapper can still succeed when the guard permits — so "the guard rejects correctly" is
  distinguishable from "the deploy path always reverts", which a reviewer mutation showed nothing else caught
- ✅ the two weaker families still pass on a stale pin, so they cannot substitute for the source check

Every negative test is written to fail if its `require` is removed; the drift tests assert that the guard *tracks*
the pin state, so they stay meaningful both during a pin regeneration and after it.

### DeployImplementationsPins.t.sol
Tests the library-pin guards in `01_DeployImplementations` and `01_2_DeployNAVImplementation`, which broadcast the
implementations the 24-chain deploy runs on:
- ✅ each source-vs-pin assertion, tripped individually through an injected pin, so both stay covered after the
  pin regeneration lands (they are the only checks that catch a pin gone stale against current source)
- ✅ each impl-linkage assertion — PriceFeedLib and NAVRegistryLib, per script — tripped individually and
  **unconditionally, in any pin state**. These inject the bytecode as well as the pins: a matched
  (pin, plan-address) pair satisfies the source-vs-pin pair by construction, so synthetic bytecode alone decides
  the linkage pair. An earlier revision injected only the pins and `vm.skip`-ed when the tree's pins matched
  source; two review gates showed that could not work — the NAVRegistryLib assertion was unreachable on a drifted
  tree and both tests self-skipped into vacuity on a regenerated one. There is no `vm.skip` in this file
- ✅ **the deploy path actually goes through the guard** — fails if the guard call is deleted, which blanking the
  guard body does not catch. This is the family that was missing: the assertions existed and were correct, but a
  `revert()` as the first statement of either `run()` failed no test at all
- ✅ the deploy wrapper can still succeed when the guard permits, so "the guard rejects correctly" stays
  distinguishable from "the deploy path always reverts" — and it asserts the deploy actually *landed*, via a
  `MockCreate2Factory` etched at the canonical `0x4e59…` (a raw call to a code-less address returns `ok == true`,
  so without it the control could not tell a working wrapper from one that silently deployed nothing). All four
  of `01`'s broadcasts are asserted, including the BridgeEscrow implementation `02_DeployProxies` depends on
- ✅ the harnesses are inert as scripts (`setUp()` reverts, which `forge script` calls before any `--sig` target)

### BaseDeployScriptTolerances.t.sol
Tests `BaseDeployScript._requireTolerancesPlannable`, the guard shared by `RegisterAssets` and
`MigrateToMonitorFeeds` that refuses to plan a batch containing a call certain to revert on-chain. It previously
had **no test at all** — blanking its body and deleting its call sites were equally invisible. Each of its three
arms is asserted with its exact revert string, plus both tolerance boundaries and a positive control.

### ConfigReaderTest.t.sol
Tests for configuration system:
- ✅ Reading chain configurations
- ✅ Per-chain settings (mainnet, Arbitrum, Gnosis)
- ✅ Salt generation (deterministic)
- ✅ Adapter enabled/disabled checks
- ✅ Constructor parameter reading
- ✅ Multi-chain adapter configuration
- ✅ JSON validation
- ✅ Address structure validation

## Running Tests

### Run All Deployment Tests
```bash
forge test --match-path "script/test/*.t.sol" -vv
```

### Run Specific Test File
```bash
# Deployment tests
forge test --match-path "script/test/DeploymentTest.fork.t.sol" -vv

# Proxy deployment tests
forge test --match-path "script/test/Test02_DeployProxies.t.sol" -vv

# Config reader tests
forge test --match-path "script/test/ConfigReaderTest.t.sol" -vv

# Upgrade-script library-pin guard
forge test --match-path "script/test/UpgradeNAVCalculatorPins.t.sol" -vv
```

### Run Specific Test
```bash
# Test CREATE2 deployment
forge test --match-test "test_Create2DeploymentViaDelegatecall" -vvv

# Test config reading
forge test --match-test "test_ReadChainConfig" -vvv
```

### Run with Gas Report
```bash
forge test --match-path "script/test/*.t.sol" --gas-report
```

### Run with Coverage
```bash
forge coverage --match-path "script/test/*.t.sol"
```

## Test Coverage

### Deployment Infrastructure
- [x] Create2Deployer stateless operation
- [x] CREATE2 address computation (standard and from hash)
- [x] Deterministic deployment across contexts
- [x] Proxy deployment and initialization
- [x] UUPS upgrade mechanism
- [x] Safe delegatecall pattern
- [x] Duplicate deployment prevention
- [x] Event emission

### Configuration System
- [x] Per-chain config file reading
- [x] Chain-specific parameters
- [x] Adapter enable/disable per chain
- [x] Constructor parameter extraction
- [x] Salt determinism
- [x] JSON validation
- [x] Multi-chain consistency

### Security
- [x] Initialization can only be called once
- [x] Only admin can upgrade
- [x] CREATE2 address cannot be squatted
- [x] Delegatecall uses correct context

## Adding New Tests

When adding new deployment scripts or utilities:

1. **Create test file** in `script/test/`
2. **Inherit from Test**: `contract MyTest is Test`
3. **Use descriptive names**: `test_SpecificBehavior()`
4. **Test edge cases**: invalid inputs, reverts, zero addresses
5. **Test happy path**: normal operation, expected behavior
6. **Document**: Add comments explaining what's being tested

### Example Test Template

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract MyDeploymentTest is Test {
    function setUp() public {
        // Setup test environment
    }

    function test_MyFeature() public {
        // Arrange
        // Act
        // Assert
    }

    function test_RevertWhen_InvalidInput() public {
        // Test failure cases with vm.expectRevert
        vm.expectRevert();
        // Act (the call expected to revert)
    }
}
```

## Continuous Integration

These tests should be run in CI/CD pipelines:

```yaml
# .github/workflows/foundry.yml
- name: Run deployment tests
  run: forge test --match-path "script/test/*.t.sol"
```

## Coverage Goals

Target coverage for deployment infrastructure:
- **Statements**: > 90%
- **Branches**: > 85%
- **Functions**: > 95%

## Troubleshooting

### Test fails with "file not found"
Ensure you're running from project root:
```bash
cd /path/to/onchain-accounting
forge test
```

### Config tests fail
Ensure config files exist in `script/config/chains/`:
```bash
ls script/config/chains/
# Should show: 1.json, 42161.json, 100.json, etc.
```

### Deployment tests fail
Ensure dependencies are installed:
```bash
forge install
```

## Best Practices

1. ✅ **Test in isolation**: Each test should be independent
2. ✅ **Use descriptive names**: `test_FeatureUnderTest_ExpectedBehavior`
3. ✅ **Test both success and failure**: Happy path and edge cases
4. ✅ **Use vm.prank for access control**: Simulate different callers
5. ✅ **Clean up state**: Each test starts fresh
6. ✅ **Document complex tests**: Explain what's being tested and why
