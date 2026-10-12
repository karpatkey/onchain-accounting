#!/usr/bin/env python3
"""Pins ops_safe's pure encoders: the MultiSend packing, the owner-approved signature, the batch checks.

Run with `python3 -m unittest` (also under `python3 -O`; the module guards with `raise`, not `assert`).
The on-chain half (deploy + one atomic execTransaction) is exercised end to end by
`rehearse_inplace_fork.sh`, which runs every swap batch through a real Safe on the fork.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ops_safe as o  # noqa: E402

A = "0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214"
B = "0x00000000000000000000000000000000000000Bb"


class PackMultiSendTest(unittest.TestCase):
    def test_layout_per_entry(self):
        packed = o.pack_multisend([{"to": A, "value": "0", "data": "0xdeadbeef", "operation": 0}])
        h = packed[2:]
        self.assertEqual(h[0:2], "00")                                   # operation: Call
        self.assertEqual(h[2:42], A[2:].lower())                         # to
        self.assertEqual(int(h[42:106], 16), 0)                          # value
        self.assertEqual(int(h[106:170], 16), 4)                         # data length in BYTES
        self.assertEqual(h[170:], "deadbeef")                            # data
        self.assertEqual(len(h), 2 + 40 + 64 + 64 + 8)

    def test_entries_concatenate_in_order(self):
        packed = o.pack_multisend([{"to": A, "value": "0", "data": "0x01"},
                                   {"to": B, "value": "7", "data": "0x"}])[2:]
        first = 2 + 40 + 64 + 64 + 2
        self.assertEqual(packed[2:42], A[2:].lower())
        second = packed[first:]
        self.assertEqual(second[2:42], B[2:].lower())
        self.assertEqual(int(second[42:106], 16), 7)
        self.assertEqual(int(second[106:170], 16), 0)
        self.assertEqual(len(second), 2 + 40 + 64 + 64)

    def test_delegatecall_refused(self):
        with self.assertRaises(o.OpsSafeError):
            o.pack_multisend([{"to": A, "value": "0", "data": "0x", "operation": 1}])

    def test_empty_and_malformed_refused(self):
        with self.assertRaises(o.OpsSafeError):
            o.pack_multisend([])
        with self.assertRaises(o.OpsSafeError):
            o.pack_multisend([{"to": "0x1234", "value": "0", "data": "0x"}])
        with self.assertRaises(o.OpsSafeError):
            o.pack_multisend([{"to": A, "value": "0", "data": "0xabc"}])  # odd-length hex


class SignatureTest(unittest.TestCase):
    def test_owner_approved_is_r_owner_s_zero_v_one(self):
        sig = o.owner_approved_signature(A)[2:]
        self.assertEqual(len(sig), 130)                                  # 65 bytes
        self.assertEqual(sig[0:64], "0" * 24 + A[2:].lower())            # r = owner
        self.assertEqual(sig[64:128], "0" * 64)                          # s = 0
        self.assertEqual(sig[128:], "01")                                # v = 1


class CheckBatchTest(unittest.TestCase):
    SAFE = "0x1111111111111111111111111111111111111111"

    def _batch(self, chain="1", safe=SAFE):
        return {"chainId": chain, "meta": {"createdFromSafeAddress": safe}, "transactions": [{"to": A}]}

    def test_accepts_matching_chain_and_safe(self):
        o.check_batch(self._batch(safe=self.SAFE.upper().replace("0X", "0x")), self.SAFE, 1)

    def test_wrong_chain_refused(self):
        with self.assertRaises(o.OpsSafeError):
            o.check_batch(self._batch(chain="10"), self.SAFE, 1)

    def test_batch_for_another_safe_refused(self):
        with self.assertRaises(o.OpsSafeError):
            o.check_batch(self._batch(safe="0x00000000000000000000000000000000000c5AFE"), self.SAFE, 1)


if __name__ == "__main__":
    unittest.main()
