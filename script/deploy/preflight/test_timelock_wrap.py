#!/usr/bin/env python3
"""Pins timelock_wrap.py offline (no network, no anvil). Run with `python3 -m unittest` and under `python3 -O`.

The properties most worth pinning: the schedule and execute files carry the wrapped batch byte for byte and name the
same operation; anything that could make the operation do something other than the batch (value, DELEGATECALL, a
batch edited after it was stamped, another chain) is refused; and the live checks refuse a delay below the timelock's
minimum, a Council that cannot propose, or an operation that already exists.
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import adr0029_batch as ab  # noqa: E402
import timelock_wrap as tw  # noqa: E402

HAS_ETH_ABI = importlib.util.find_spec("eth_abi") is not None and importlib.util.find_spec("eth_utils") is not None
needs_eth_abi = unittest.skipUnless(HAS_ETH_ABI, "eth_abi/eth_utils not installed (CI preflight job)")
HAS_CAST = shutil.which("cast") is not None

A1, A2 = "0x" + "11" * 20, "0x" + "22" * 20
P1, P2 = "0x12345678", "0xabcdef0011223344556677889900aabbccddeeff00112233445566778899aabbccddeeff0011"
SALT = "0x" + "00" * 31 + "aa"
# Pinned `cast calldata` outputs for these arguments (predecessor 0, delay 259200), so CI pins the encoder too.
CAST_SCHEDULE = "0x8f2a0bb000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000aa000000000000000000000000000000000000000000000000000000000003f480000000000000000000000000000000000000000000000000000000000000000200000000000000000000000011111111111111111111111111111111111111110000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000412345678000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000026abcdef0011223344556677889900aabbccddeeff00112233445566778899aabbccddeeff00110000000000000000000000000000000000000000000000000000"
CAST_EXECUTE = "0xe38335e500000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000aa000000000000000000000000000000000000000000000000000000000000000200000000000000000000000011111111111111111111111111111111111111110000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000412345678000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000026abcdef0011223344556677889900aabbccddeeff00112233445566778899aabbccddeeff00110000000000000000000000000000000000000000000000000000"
CAST_OPERATION = "0xc0bc26d0924768721ae2033b9c266085dca01b3da4bc2a366e69391fb0df7cc1"  # cast keccak of execute's body


class Encoding(unittest.TestCase):
    def test_matches_pinned_cast_vectors(self):
        self.assertEqual(tw.enc_schedule_batch([A1, A2], [0, 0], [P1, P2], tw.ZERO32, SALT, 259200), CAST_SCHEDULE)
        self.assertEqual(tw.enc_execute_batch([A1, A2], [0, 0], [P1, P2], tw.ZERO32, SALT), CAST_EXECUTE)

    @needs_eth_abi
    def test_operation_id_is_the_hash_of_the_execute_arguments(self):
        self.assertEqual(tw.operation_id([A1, A2], [0, 0], [P1, P2], tw.ZERO32, SALT), CAST_OPERATION)

    @unittest.skipUnless(HAS_CAST, "cast not installed")
    def test_live_cast_cross_check_varied_payloads(self):
        payloads = ["0x", "0x" + "ab" * 31, "0x" + "cd" * 32, "0x" + "ef" * 33, P2]
        targets = [A1, A2, A1, A2, A1]
        args = ["[" + ",".join(targets) + "]", "[" + ",".join("0" for _ in targets) + "]",
                "[" + ",".join(payloads) + "]", tw.ZERO32, SALT]
        run = lambda *a: subprocess.run(["cast", "calldata", *a], capture_output=True, text=True, check=True).stdout.strip()  # noqa: E731
        self.assertEqual(tw.enc_schedule_batch(targets, [0] * 5, payloads, tw.ZERO32, SALT, 300000),
                         run("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", *args, "300000"))
        self.assertEqual(tw.enc_execute_batch(targets, [0] * 5, payloads, tw.ZERO32, SALT),
                         run("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", *args))

    def test_bad_bytes32_refused(self):
        with self.assertRaises(tw.WrapError):
            tw.enc_execute_batch([A1], [0], [P1], "0x1234", SALT)


def _batch(tmp, txs, chain=1, stamp=True, tamper=False):
    for t in txs:
        t.setdefault("value", "0")
        t.setdefault("operation", 0)
    doc = {"version": "1.0", "chainId": str(chain), "meta": {"name": "x", "createdFromSafeAddress": A1},
           "transactions": [dict(t, contractMethod=None, contractInputsValues=None) for t in txs]}
    if stamp:
        try:  # a deliberately malformed entry cannot be stamped; it is refused before the checksum is compared
            doc["meta"]["checksum"] = ab.checksum([dict(t) for t in txs]) if HAS_ETH_ABI else "0x" + "00" * 32
        except Exception:
            doc["meta"]["checksum"] = "0x" + "00" * 32
    if tamper:
        doc["transactions"][0]["data"] = doc["transactions"][0]["data"][:-2] + "ff"
    p = Path(tmp) / f"b{len(list(Path(tmp).iterdir()))}.json"
    p.write_text(json.dumps(doc))
    return str(p)


class Inputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def _refused(self, path, chain=1):
        with self.assertRaises(tw.WrapError):
            tw.load_inner(path, chain)

    def test_refuses_value_delegatecall_missing_data_bad_target_empty_and_wrong_chain(self):
        t = self.tmp.name
        self._refused(_batch(t, [{"to": A1, "data": P1, "value": "1"}]))
        self._refused(_batch(t, [{"to": A1, "data": P1, "operation": 1}]))
        self._refused(_batch(t, [{"to": A1, "data": None}]))
        self._refused(_batch(t, [{"to": A1, "data": "0x"}]))
        self._refused(_batch(t, [{"to": "0x1234", "data": P1}]))
        self._refused(_batch(t, [{"to": A1, "data": "0x123"}]))
        self._refused(_batch(t, []))
        self._refused(_batch(t, [{"to": A1, "data": P1}], chain=10), chain=1)
        self._refused(_batch(t, [{"to": A1, "data": P1}], stamp=False))

    @needs_eth_abi
    def test_refuses_a_batch_edited_after_it_was_stamped(self):
        self._refused(_batch(self.tmp.name, [{"to": A1, "data": P2}], tamper=True))

    @needs_eth_abi
    def test_accepts_a_stamped_plain_batch(self):
        txs, sha = tw.load_inner(_batch(self.tmp.name, [{"to": A1, "data": P1}, {"to": A2, "data": P2}]), 1)
        self.assertEqual([t["data"] for t in txs], [P1, P2])
        self.assertEqual(len(sha), 64)


class Live:
    """A fake timelock: `min_delay`, whether the Council is a proposer, and whether the operation exists."""

    def __init__(self, min_delay=259200, proposer=True, exists=False, executor_open=True, predecessors=()):
        self.min_delay, self.proposer, self.exists = min_delay, proposer, exists
        self.executor_open, self.predecessors = executor_open, {p[2:].lower() for p in predecessors}

    def call(self, to, data):
        if data == tw.SEL_GET_MIN_DELAY:
            return "0x" + f"{self.min_delay:064x}"
        if data.startswith(ab.SEL_HAS_ROLE):
            role = data[10:74]
            ok = self.executor_open if role == ab.ROLE_TL_EXECUTOR else self.proposer
            return "0x" + f"{int(ok):064x}"
        if data.startswith(tw.SEL_IS_OPERATION):
            op = data[10:74]
            return "0x" + f"{int(op in self.predecessors or self.exists):064x}"
        raise AssertionError(data)


@needs_eth_abi
class Wrap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.src = _batch(self.tmp.name, [{"to": A1, "data": P1}, {"to": A2, "data": P2}])

    def tearDown(self):
        self.tmp.cleanup()

    def test_schedule_and_execute_carry_the_batch_byte_for_byte_and_name_one_operation(self):
        from eth_abi import decode
        sched, exe, s = tw.wrap(1, self.src, "test label", 259200, tw.ZERO32, Live())
        tl = ab.c.deployment(1)["TimelockController"]
        self.assertEqual(sched["tx"]["to"], tl)
        self.assertEqual(exe["tx"]["to"], tl)
        arr = ["address[]", "uint256[]", "bytes[]", "bytes32", "bytes32"]
        sa = decode(arr + ["uint256"], bytes.fromhex(sched["tx"]["data"][10:]))
        ea = decode(arr, bytes.fromhex(exe["tx"]["data"][10:]))
        self.assertEqual(tuple(sa[:5]), tuple(ea))
        self.assertEqual([a.lower() for a in ea[0]], [A1, A2])
        self.assertEqual(["0x" + p.hex() for p in ea[2]], [P1, P2])
        self.assertEqual(sa[5], 259200)
        self.assertEqual("0x" + ea[4].hex(), tw.label_salt("test label"))
        self.assertEqual(s["operation"], tw.operation_id([A1, A2], [0, 0], [P1, P2], tw.ZERO32, s["salt"]))
        self.assertIn(s["operation"], sched["desc"])

    def test_refuses_a_delay_below_the_nav_minimum_or_the_live_minimum(self):
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 3600, tw.ZERO32)
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 259200, tw.ZERO32, Live(min_delay=259201))

    def test_refuses_when_the_council_cannot_propose_or_the_operation_exists(self):
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 259200, tw.ZERO32, Live(proposer=False))
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 259200, tw.ZERO32, Live(exists=True))

    def test_refuses_closed_execution_and_a_predecessor_that_is_not_an_operation(self):
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 259200, tw.ZERO32, Live(executor_open=False))
        pred = "0x" + "77" * 32
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "x", 259200, pred, Live())
        _, _, s = tw.wrap(1, self.src, "x", 259200, pred, Live(predecessors=[pred]))
        self.assertEqual(s["predecessor"], pred)

    def test_refuses_an_empty_label(self):
        with self.assertRaises(tw.WrapError):
            tw.wrap(1, self.src, "  ", 259200, tw.ZERO32)

    def test_written_files_are_stamped_council_batches(self):
        out_s, out_e = Path(self.tmp.name) / "s.json", Path(self.tmp.name) / "e.json"
        class A: pass
        a = A()
        a.chain, a.input, a.label, a.delay, a.predecessor = 1, self.src, "files", 259200, tw.ZERO32
        a.out_schedule, a.out_execute, a.rpc_env, a.rpc_url = str(out_s), str(out_e), None, None
        self.assertEqual(tw.cmd_wrap(a), 0)
        for p in (out_s, out_e):
            d = json.loads(p.read_text())
            self.assertEqual(d["chainId"], "1")
            self.assertEqual(d["meta"]["createdFromSafeAddress"], ab._council(1))
            self.assertEqual(d["meta"]["checksum"], ab.checksum(d["transactions"]))
            self.assertEqual(len(d["transactions"]), 1)


if __name__ == "__main__":
    unittest.main()
