// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Vm} from "forge-std/Vm.sol";
import {ConditionFlat, ExecutionOptions, IRolesV2, Op, ParameterType} from "poc/fundconfig/vendor/RolesV2.sol";
import {FundConfig} from "poc/fundconfig/FundConfig.sol";
import {PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {FundConfigDerivationForkTest} from "test/poc/fundconfig/FundConfigDerivation.fork.t.sol";

/// @notice Behavioural validation of the Roles v2 permissions FundConfig derives, against the live mastercopy on a fork.
/// @dev Reuses the derivation fixture (fork, modules, `_newFund`, `_fundPositions`, `_signatureOf`, JSON helpers).
///      Every check is a real `execTransactionWithRole` on the Roles clone, reverted with `vm.snapshotState` /
///      `vm.revertToState` so checks do not leak state into each other. Outcome classification:
///      - `Accepted`: Roles did not revert (`shouldRevert=false`, so an inner protocol failure still counts as accepted).
///      - `<Status>`: Roles reverted with `ConditionViolation(uint8,bytes32)`; the raw status code is recorded.
///      - `OtherRevert`: any other revert (not a condition violation), with the selector recorded.
///      Expected statuses come from an oracle over the derived leaf set, not from the protocol's own behaviour.
///      Each suite writes `out/permission-validation/<suite>.json`; the docs JSON is assembled from those files.
contract FundConfigPermissionValidationForkTest is FundConfigDerivationForkTest {
    uint8 internal constant ACCEPTED = 255;
    uint8 internal constant OTHER_REVERT = 254;
    uint8 internal constant SHAPE_MISMATCH = 253;

    uint8 internal constant ST_DELEGATECALL = 1;
    uint8 internal constant ST_TARGET = 2;
    uint8 internal constant ST_FUNCTION = 3;
    uint8 internal constant ST_SEND = 4;
    uint8 internal constant ST_OR = 5;
    uint8 internal constant ST_PARAM = 7;
    uint8 internal constant ST_CUSTOM = 16;

    uint8 internal constant OP_CUSTOM = 22;
    bytes4 internal constant CONDITION_VIOLATION = bytes4(keccak256("ConditionViolation(uint8,bytes32)"));
    bytes4 internal constant UNDECLARED_SELECTOR = 0xdeadbeef;
    bytes4 internal constant APPROVE = 0x095ea7b3;
    address internal constant DEAD = address(uint160(0xdead));
    uint256 internal constant NONEXISTENT_TOKEN = type(uint64).max;

    struct Plan {
        uint256[] words;
        uint256[] nodes;
        bool shapeOk;
    }

    uint256 internal _lpTokenId;
    uint256 internal _total;
    uint256 internal _fails;
    string internal _rows;
    bytes4 internal _lastOther;

    // ---------------------------------------------------------------- suites

    /// @notice Every derived leaf, crafted from its own condition tree, is accepted by Roles.
    function test_derivedLeavesAccepted() public {
        (address safe,, IRolesV2 roles, PermissionLeaf[] memory set) = _fundedSet();
        _checkPositives(roles, safe, set);
        _emit("positive");
        assertEq(_fails, 0, "positive mismatches");
    }

    /// @notice Each constrained word rejects a value outside its condition (xor-1, a sentinel address, or a non-owned token).
    function test_constrainedWordsEnforced() public {
        (address safe,, IRolesV2 roles, PermissionLeaf[] memory set) = _fundedSet();
        for (uint256 i; i < set.length; ++i) {
            _wordChecks(roles, safe, set, i);
        }
        _emit("words");
        assertEq(_fails, 0, "word mismatches");
    }

    /// @notice Options are enforced: Send-only leaves reject DelegateCall, DelegateCall-only leaves reject value, Send leaves accept value.
    function test_optionsEnforced() public {
        (address safe,, IRolesV2 roles, PermissionLeaf[] memory set) = _fundedSet();
        for (uint256 i; i < set.length; ++i) {
            _optionChecks(roles, safe, set[i], _leafId(i, set[i]));
        }
        _emit("options");
        assertEq(_fails, 0, "option mismatches");
    }

    /// @notice Undeclared selectors on declared targets and declared selectors on undeclared targets are rejected.
    function test_undeclaredCallsRejected() public {
        (address safe,, IRolesV2 roles, PermissionLeaf[] memory set) = _fundedSet();
        for (uint256 i; i < set.length; ++i) {
            _undeclaredChecks(roles, safe, set, i);
        }
        _emit("undeclared");
        assertEq(_fails, 0, "undeclared mismatches");
    }

    /// @notice Removing an unfunded position revokes exactly its leaves; a shared merged key shrinks to the remaining leaf.
    function test_removalRevokesOnlyRemovedLeaves() public {
        Decl[] memory all = _declarations();
        Decl[] memory two = new Decl[](2);
        two[0] = all[0]; // Morpho vault (USDC approve to the vault)
        two[1] = all[5]; // Curve 3pool (USDC approve to the pool, add/remove liquidity)
        (address safe, FundConfig fc, IRolesV2 roles) = _buildFund(two, false);

        PermissionLeaf[] memory pre = fc.permissionSet();
        _checkPositives(roles, safe, pre);
        _recordApproveDead(roles, pre, "USDC approve(DEAD) before removal");

        bytes32 id = curvePool.moduleId();
        vm.prank(curator);
        fc.removePosition(id, _addr(THREE_POOL));

        PermissionLeaf[] memory post = fc.permissionSet();
        _checkPositives(roles, safe, post);
        _checkRemoved(roles, safe, pre, post);
        _recordApproveDead(roles, post, "USDC approve(DEAD) after removal");

        _emit("removal");
        assertEq(_fails, 0, "removal mismatches");
    }

    /// @notice A funded position cannot be removed.
    function test_removeFundedPositionReverts() public {
        (, FundConfig fc,) = _buildFund(_declarations(), true);
        bytes32 id = morpho.moduleId();
        vm.expectRevert(abi.encodeWithSelector(FundConfig.PositionNotEmpty.selector, id, _addr(MORPHO_VAULT)));
        vm.prank(curator);
        fc.removePosition(id, _addr(MORPHO_VAULT));
    }

    // ---------------------------------------------------------------- per-leaf checks

    function _wordChecks(IRolesV2 roles, address safe, PermissionLeaf[] memory set, uint256 i) internal {
        PermissionLeaf memory leaf = set[i];
        string memory id = _leafId(i, leaf);
        Plan memory p = _plan(leaf, safe);
        if (!p.shapeOk) {
            _record(id, "shape", ACCEPTED, SHAPE_MISMATCH);
            return;
        }
        for (uint256 k; k < p.nodes.length; ++k) {
            _wordCheck(roles, set, leaf, id, p, k);
        }
    }

    function _wordCheck(
        IRolesV2 roles,
        PermissionLeaf[] memory set,
        PermissionLeaf memory leaf,
        string memory id,
        Plan memory p,
        uint256 k
    ) internal {
        ConditionFlat memory node = leaf.conditions[p.nodes[k]];
        if (node.operator == Op.PASS) return;
        string memory check = string.concat("word ", vm.toString(k));
        if (node.operator == Op.EQUAL_TO) {
            uint8 exp = _expectedRejection(set, leaf.target, leaf.selector, Op.EQUAL_TO);
            bytes memory xor1 = _encode(leaf.selector, _with(p.words, k, p.words[k] ^ 1));
            _recordAttempt(roles, id, string.concat(check, " xor1"), exp, leaf.target, xor1, _opOf(leaf.options));
            bytes memory sentinel = _encode(leaf.selector, _with(p.words, k, uint256(uint160(DEAD))));
            _recordAttempt(roles, id, string.concat(check, " sentinel"), exp, leaf.target, sentinel, _opOf(leaf.options));
        } else if (node.operator == Op.EQUAL_TO_AVATAR) {
            uint8 exp = _expectedRejection(set, leaf.target, leaf.selector, Op.EQUAL_TO_AVATAR);
            bytes memory sentinel = _encode(leaf.selector, _with(p.words, k, uint256(uint160(DEAD))));
            _recordAttempt(roles, id, string.concat(check, " sentinel"), exp, leaf.target, sentinel, _opOf(leaf.options));
        } else if (node.operator == OP_CUSTOM) {
            uint8 exp = _expectedRejection(set, leaf.target, leaf.selector, OP_CUSTOM);
            bytes memory nonexistent = _encode(leaf.selector, _with(p.words, k, NONEXISTENT_TOKEN));
            _recordAttempt(roles, id, string.concat(check, " nonexistent token"), exp, leaf.target, nonexistent, _opOf(leaf.options));
        } else {
            revert("unsupported operator");
        }
    }

    function _optionChecks(IRolesV2 roles, address safe, PermissionLeaf memory leaf, string memory id) internal {
        Plan memory p = _plan(leaf, safe);
        if (!p.shapeOk) return;
        bytes memory data = _encode(leaf.selector, p.words);
        if (leaf.options == ExecutionOptions.Send) {
            _recordAttempt(roles, id, "delegatecall on send-only", ST_DELEGATECALL, leaf.target, data, 1);
            _recordAttempt(roles, id, "value on send", ACCEPTED, leaf.target, data, 0, 1);
        } else if (leaf.options == ExecutionOptions.DelegateCall) {
            _recordAttempt(roles, id, "value on delegatecall-only", ST_SEND, leaf.target, data, 0, 1);
        }
    }

    function _undeclaredChecks(IRolesV2 roles, address safe, PermissionLeaf[] memory set, uint256 i) internal {
        PermissionLeaf memory leaf = set[i];
        string memory id = _leafId(i, leaf);
        _recordAttempt(
            roles,
            id,
            "undeclared selector on declared target",
            _expectedRejection(set, leaf.target, UNDECLARED_SELECTOR, 0),
            leaf.target,
            abi.encodePacked(UNDECLARED_SELECTOR),
            0
        );
        Plan memory p = _plan(leaf, safe);
        if (!p.shapeOk) return;
        _recordAttempt(
            roles,
            id,
            "declared selector on undeclared target",
            _expectedRejection(set, DEAD, leaf.selector, 0),
            DEAD,
            _encode(leaf.selector, p.words),
            0
        );
    }

    function _checkRemoved(IRolesV2 roles, address safe, PermissionLeaf[] memory pre, PermissionLeaf[] memory post)
        internal
    {
        PermissionLeaf[] memory removed = curvePool.permissions(_addr(THREE_POOL));
        for (uint256 i; i < removed.length; ++i) {
            PermissionLeaf memory leaf = removed[i];
            string memory id = string.concat("removed ", _leafId(i, leaf));
            Plan memory p = _plan(leaf, safe);
            if (!p.shapeOk) {
                _record(id, "shape", ACCEPTED, SHAPE_MISMATCH);
                continue;
            }
            uint8 exp = _expectedRejection(post, leaf.target, leaf.selector, Op.PASS);
            _recordAttempt(roles, id, "removed leaf rejected", exp, leaf.target, _encode(leaf.selector, p.words), _opOf(leaf.options));
        }
        // `pre` is kept for symmetry with the removal assertion: the removed leaves must have been in the pre-removal set.
        assertGt(pre.length, post.length, "removal did not shrink the set");
    }

    function _recordApproveDead(IRolesV2 roles, PermissionLeaf[] memory set, string memory check) internal {
        uint8 exp = _expectedRejection(set, USDC, APPROVE, Op.EQUAL_TO);
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", DEAD, uint256(1));
        _recordAttempt(roles, "USDC approve", check, exp, USDC, data, 0);
    }

    function _checkPositives(IRolesV2 roles, address safe, PermissionLeaf[] memory set) internal {
        for (uint256 i; i < set.length; ++i) {
            PermissionLeaf memory leaf = set[i];
            string memory id = _leafId(i, leaf);
            Plan memory p = _plan(leaf, safe);
            if (!p.shapeOk) {
                _record(id, "shape", ACCEPTED, SHAPE_MISMATCH);
                continue;
            }
            _recordAttempt(roles, id, "positive", ACCEPTED, leaf.target, _encode(leaf.selector, p.words), _opOf(leaf.options));
        }
    }

    // ---------------------------------------------------------------- fund setup

    function _fundedSet() internal returns (address safe, FundConfig fc, IRolesV2 roles, PermissionLeaf[] memory set) {
        (safe, fc, roles) = _buildFund(_declarations(), true);
        set = fc.permissionSet();
    }

    function _buildFund(Decl[] memory decls, bool funded)
        internal
        returns (address safe, FundConfig fc, IRolesV2 roles)
    {
        (safe, fc, roles) = _newFund(77);
        for (uint256 i; i < decls.length; ++i) {
            _addPosition(fc, decls[i].module, decls[i].instance);
        }
        _manager(fc);
        deal(USDC, safe, 10_000e6);
        deal(WETH, safe, 3 ether);
        if (funded) {
            vm.recordLogs();
            _fundPositions(safe, roles);
            _lpTokenId = _mintedLpToken(safe);
        }
    }

    /// @dev The Safe-owned LP NFT minted during funding (NPM `Transfer(0, safe, tokenId)`), used for the Custom tokenId word.
    function _mintedLpToken(address safe) internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transfer = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == NPM && l.topics.length == 4 && l.topics[0] == transfer && l.topics[1] == bytes32(0)
                && l.topics[2] == _addr(safe)) {
                return uint256(l.topics[3]);
            }
        }
        revert("no LP mint to safe");
    }

    // ---------------------------------------------------------------- calldata

    function _plan(PermissionLeaf memory leaf, address safe) internal view returns (Plan memory p) {
        ConditionFlat[] memory c = leaf.conditions;
        uint256 abiWords = _abiWords(_signatureOf(leaf.selector));
        if (c.length == 0) {
            p.words = new uint256[](abiWords);
            p.shapeOk = true;
            return p;
        }
        require(c[0].paramType == ParameterType.Calldata && c[0].operator == Op.MATCHES, "root node");
        uint256[] memory tmp = new uint256[](c.length);
        uint256 n = _collect(c, 0, tmp, 0);
        p.nodes = new uint256[](n);
        p.words = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            p.nodes[k] = tmp[k];
            p.words[k] = _wordValue(c[tmp[k]], leaf.target, safe);
        }
        p.shapeOk = n == abiWords;
    }

    /// @dev Static nodes under `parent`, in head order; tuple nodes are inlined. Any other paramType is unsupported.
    function _collect(ConditionFlat[] memory c, uint256 parent, uint256[] memory out, uint256 n)
        internal
        pure
        returns (uint256)
    {
        for (uint256 j = 1; j < c.length; ++j) {
            if (c[j].parent != parent) continue;
            if (c[j].paramType == ParameterType.Static) {
                out[n++] = j;
            } else if (c[j].paramType == ParameterType.Tuple) {
                n = _collect(c, j, out, n);
            } else {
                revert("unsupported paramType");
            }
        }
        return n;
    }

    function _wordValue(ConditionFlat memory node, address target, address safe) internal view returns (uint256) {
        if (node.operator == Op.PASS) return 1;
        if (node.operator == Op.EQUAL_TO) {
            require(node.compValue.length == 32, "compValue width");
            return uint256(bytes32(node.compValue));
        }
        if (node.operator == Op.EQUAL_TO_AVATAR) return uint256(uint160(safe));
        if (node.operator == OP_CUSTOM) {
            require(target == NPM, "custom target");
            return _lpTokenId;
        }
        revert("unsupported operator");
    }

    function _encode(bytes4 sel, uint256[] memory words) internal pure returns (bytes memory out) {
        out = abi.encodePacked(sel);
        for (uint256 k; k < words.length; ++k) {
            out = bytes.concat(out, bytes32(words[k]));
        }
    }

    function _with(uint256[] memory words, uint256 k, uint256 v) internal pure returns (uint256[] memory w) {
        w = new uint256[](words.length);
        for (uint256 i; i < words.length; ++i) {
            w[i] = words[i];
        }
        w[k] = v;
    }

    /// @dev Number of 32-byte head words of a static signature; `T[k]` multiplies, tuples sum. Dynamic types revert.
    function _abiWords(string memory sig) internal pure returns (uint256 words) {
        bytes memory s = bytes(sig);
        uint256 i;
        while (s[i] != "(") ++i;
        (words,) = _typeWords(s, i);
    }

    function _typeWords(bytes memory s, uint256 i) internal pure returns (uint256 words, uint256 next) {
        if (s[i] == "(") {
            ++i;
            while (true) {
                (uint256 w, uint256 j) = _typeWords(s, i);
                words += w;
                i = j;
                if (s[i] == ",") {
                    ++i;
                    continue;
                }
                require(s[i] == ")", "malformed signature");
                ++i;
                break;
            }
        } else {
            uint256 start = i;
            while (s[i] != "," && s[i] != ")" && s[i] != "[") ++i;
            bytes32 name = keccak256(_slice(s, start, i));
            require(name != keccak256("bytes") && name != keccak256("string"), "dynamic type");
            words = 1;
        }
        while (i < s.length && s[i] == "[") {
            ++i;
            uint256 k;
            while (s[i] != "]") {
                k = k * 10 + (uint8(s[i]) - 48);
                ++i;
            }
            require(k > 0, "dynamic array");
            ++i;
            words *= k;
        }
        next = i;
    }

    function _slice(bytes memory s, uint256 a, uint256 b) internal pure returns (bytes memory out) {
        out = new bytes(b - a);
        for (uint256 i; i < out.length; ++i) {
            out[i] = s[a + i];
        }
    }

    // ---------------------------------------------------------------- execution

    function _opOf(ExecutionOptions o) internal pure returns (uint8) {
        return o == ExecutionOptions.DelegateCall ? 1 : 0;
    }

    /// @dev Runs one attempt, records it, and reverts state. Value is 0 unless `value` is passed via `_recordAttempt`.
    function _recordAttempt(
        IRolesV2 roles,
        string memory id,
        string memory check,
        uint8 expected,
        address to,
        bytes memory data,
        uint8 op
    ) internal {
        _record(id, check, expected, _attempt(roles, to, 0, data, op));
    }

    /// @dev Value-carrying variant used by the options suite.
    function _recordAttempt(
        IRolesV2 roles,
        string memory id,
        string memory check,
        uint8 expected,
        address to,
        bytes memory data,
        uint8 op,
        uint256 value
    ) internal {
        _record(id, check, expected, _attempt(roles, to, value, data, op));
    }

    /// @dev Runs one `execTransactionWithRole` and reverts its state. Returns `ACCEPTED`, a Roles `Status`, or `OTHER_REVERT`.
    function _attempt(IRolesV2 roles, address to, uint256 value, bytes memory data, uint8 op)
        internal
        returns (uint8 status)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(manager);
        try roles.execTransactionWithRole(to, value, data, op, ROLE_KEY, false) returns (bool) {
            status = ACCEPTED;
        } catch (bytes memory err) {
            status = _classify(err);
        }
        vm.revertToState(snap);
    }

    function _classify(bytes memory err) internal returns (uint8) {
        if (err.length == 68 && bytes4(err) == CONDITION_VIOLATION) {
            (uint8 s,) = abi.decode(_tail(err), (uint8, bytes32));
            return s;
        }
        if (err.length >= 4) _lastOther = bytes4(err);
        return OTHER_REVERT;
    }

    function _tail(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + 4];
        }
    }

    // ---------------------------------------------------------------- oracle

    function _keyLeaves(PermissionLeaf[] memory set, address target, bytes4 sel)
        internal
        pure
        returns (uint256 count, bool wildcard)
    {
        for (uint256 j; j < set.length; ++j) {
            if (set[j].target != target || set[j].selector != sel) continue;
            ++count;
            if (set[j].conditions.length == 0) wildcard = true;
        }
    }

    /// @dev Expected Roles outcome for a call on `(target, sel)` under the derived set, when the call violates the
    ///      constraint the caller is probing. `op` is the violated operator (used only for a single-leaf key).
    function _expectedRejection(PermissionLeaf[] memory set, address target, bytes4 sel, uint8 op)
        internal
        pure
        returns (uint8)
    {
        bool hasTarget;
        for (uint256 j; j < set.length; ++j) {
            if (set[j].target == target) {
                hasTarget = true;
                break;
            }
        }
        if (!hasTarget) return ST_TARGET;
        (uint256 count, bool wildcard) = _keyLeaves(set, target, sel);
        if (count == 0) return ST_FUNCTION;
        if (wildcard) return ACCEPTED;
        if (count > 1) return ST_OR;
        return op == OP_CUSTOM ? ST_CUSTOM : ST_PARAM;
    }

    // ---------------------------------------------------------------- recording

    function _leafId(uint256 i, PermissionLeaf memory leaf) internal view returns (string memory) {
        return string.concat(vm.toString(i), " ", _signatureOf(leaf.selector), " @ ", _label(leaf.target));
    }

    function _record(string memory leaf, string memory check, uint8 expected, uint8 actual) internal {
        bool pass = expected == actual;
        ++_total;
        if (!pass) ++_fails;
        _rows = _add(_rows, _obj(_row(leaf, check, expected, actual, pass)));
    }

    function _row(string memory leaf, string memory check, uint8 expected, uint8 actual, bool pass)
        internal
        view
        returns (string memory r)
    {
        r = _kv("leaf", _q(leaf));
        r = _add(r, _kv("check", _q(check)));
        r = _add(r, _kv("expected", _q(_statusName(expected))));
        r = _add(r, _kv("actual", _q(_statusName(actual))));
        if (actual == OTHER_REVERT) {
            r = _add(r, _kv("revertSelector", _q(vm.toString(abi.encodePacked(_lastOther)))));
        }
        r = _add(r, _kv("pass", vm.toString(pass)));
    }

    function _emit(string memory suite) internal {
        string memory body = _kv("suite", _q(suite));
        body = _add(body, _kv("total", vm.toString(_total)));
        body = _add(body, _kv("failures", vm.toString(_fails)));
        body = _add(body, _kv("rows", _arr(_rows)));
        vm.createDir("out/permission-validation", true);
        vm.writeJson(_obj(body), string.concat("out/permission-validation/", suite, ".json"));
    }

    /// @dev Roles `Status` names from the pinned Roles v2 source (f55d00de). The live mastercopy's enum is not
    ///      re-verified here; the raw code is what the rows compare, names are labels only.
    function _statusName(uint8 s) internal pure returns (string memory) {
        if (s == ACCEPTED) return "Accepted";
        if (s == OTHER_REVERT) return "OtherRevert";
        if (s == SHAPE_MISMATCH) return "ShapeMismatch";
        string[20] memory names = [
            "Ok",
            "DelegateCallNotAllowed",
            "TargetAddressNotAllowed",
            "FunctionNotAllowed",
            "SendNotAllowed",
            "OrViolation",
            "NorViolation",
            "ParameterNotAllowed",
            "ParameterLessThanAllowed",
            "ParameterGreaterThanAllowed",
            "ParameterNotAMatch",
            "NotEveryArrayElementPasses",
            "NoArrayElementPasses",
            "ParameterNotSubsetOfAllowed",
            "BitmaskOverflow",
            "BitmaskNotAllowed",
            "CustomConditionViolation",
            "AllowanceExceeded",
            "CallAllowanceExceeded",
            "EtherAllowanceExceeded"
        ];
        return s < names.length ? names[s] : "Unknown";
    }
}
