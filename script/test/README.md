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
Tests for the `02_DeployProxies` deploy script:
- ✅ CREATE2 determinism (canonical deployer yields the same proxy address regardless of caller)
- ✅ AtomicProxyDeployer behavior
- ✅ Proxy initialization flow
- ✅ Diverging addresses across different deployers

### UpgradeNAVCalculatorPins.t.sol
Tests the library-pin guard in `script/upgrade/UpgradeNAVCalculator`, which repoints a **live** proxy at the
implementation it deploys:
- ✅ the pins still match the library source in this tree (the only check that catches a stale pin)
- ✅ the impl bytecode is linked against both pins (each pin isolated in its own test)
- ✅ both pinned addresses hold code on this chain (each isolated)
- ✅ the deploy path actually goes through the guard — fails if the guard call is deleted or moved below the
  broadcast, which blanking the guard body does not catch
- ✅ the two weaker families still pass on a stale pin, so they cannot substitute for the source check

Every negative test is written to fail if its `require` is removed; the drift tests assert that the guard *tracks*
the pin state, so they stay meaningful both during a pin regeneration and after it.

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
