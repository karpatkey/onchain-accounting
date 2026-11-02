"""Offline tests for seed_assisted.py (no network). Reference encodings were produced with `cast calldata` /
`cast abi-encode` and are pinned here so the hand-rolled encoder is checked against an independent one."""
import unittest

import seed_assisted as s

A1 = "0x1111111111111111111111111111111111111111"
A2 = "0x2222222222222222222222222222222222222222"
CAST_SUBMIT_FOR_BATCH = "0xb74e4c50000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000111111111111111111111111111111111111111100000000000000000000000022222222222222222222222222222222222222220000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000000410000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000aab00000000000000000000000000000000000000000000000000000000000000"
CAST_PREVIEW = "0x9461d46c0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000007"
CAST_BYTES_ARRAY_RET = "0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000006"


class Encoding(unittest.TestCase):
    def test_submit_for_batch_matches_cast(self):
        coords = [s.coord_token(7), bytes.fromhex(s._word(9) + s._word(10) + "ab")]
        self.assertEqual(s.encode_submit_for_batch([A1, A2], coords), CAST_SUBMIT_FOR_BATCH)

    def test_preview_matches_cast(self):
        self.assertEqual(s.encode_preview(A1, [s.coord_token(7)]), CAST_PREVIEW)

    def test_decode_bytes_array_roundtrip(self):
        self.assertEqual(s.decode_bytes_array(CAST_BYTES_ARRAY_RET), [s.coord_token(5), s.coord_token(6)])

    def test_decode_rejects_malformed(self):
        with self.assertRaises(s.SeedError):
            s.decode_bytes_array("0x" + "00" * 32)

    def test_stakewise_coord_is_96_bytes(self):
        self.assertEqual(len(s.coord_stakewise(A1, 3, 4)), 96)

    def test_length_mismatch_rejected(self):
        with self.assertRaises(s.SeedError):
            s.encode_submit_for_batch([A1], [])

    def test_bad_address_rejected(self):
        with self.assertRaises(s.SeedError):
            s.encode_submit_for_batch(["0x12"], [s.coord_token(1)])


class Planning(unittest.TestCase):
    def test_dedupe_is_case_insensitive_and_keeps_order(self):
        pairs = [(A1, s.coord_token(1)), (A1.upper().replace("0X", "0x"), s.coord_token(1)), (A2, s.coord_token(1))]
        self.assertEqual(s.dedupe(pairs), [(A1, s.coord_token(1)), (A2, s.coord_token(1))])

    def test_chunks_split_and_encode(self):
        pairs = [(A1, s.coord_token(i)) for i in range(5)]
        out = s.chunks(A2, pairs, 2)
        self.assertEqual([c["count"] for c in out], [2, 2, 1])
        self.assertTrue(all(c["data"].startswith("0xb74e4c50") and c["to"] == A2 for c in out))

    def test_over_headroom_flags_only_crowded_accounts(self):
        pairs = [(A1, s.coord_token(i)) for i in range(3)] + [(A2, s.coord_token(1))]
        self.assertEqual(s.over_headroom(pairs, 2), {A1: 3})
        self.assertEqual(s.over_headroom(pairs, 3), {})

    def test_over_headroom_counts_the_union(self):
        pairs = [(A1, s.coord_token(1)), (A1, s.coord_token(2))]
        cached = {A1: {s.coord_token(1), s.coord_token(2)}}
        self.assertEqual(s.over_headroom(pairs, 2, cached), {}, "a re-run must not double count")
        self.assertEqual(s.over_headroom(pairs + [(A1, s.coord_token(3))], 2, cached), {A1: 3})

    def test_rerun_sends_only_missing(self):
        pairs = [(A1, s.coord_token(1)), (A1, s.coord_token(2)), (A2, s.coord_token(1))]
        self.assertEqual(s.not_yet_cached(pairs, {A1: {s.coord_token(1)}}), [(A1, s.coord_token(2)), (A2, s.coord_token(1))])

    def test_chunk_size_must_be_positive(self):
        with self.assertRaises(s.SeedError):
            s.chunks(A2, [(A1, s.coord_token(1))], 0)


SAFE = A1
ROLES = "0x3333333333333333333333333333333333333333"
EOA = "0x5555555555555555555555555555555555555555"
PROTO = "0x6666666666666666666666666666666666666666"


def _log(data):
    return {"address": PROTO, "topics": [s.TOPIC_EXIT_ENTERED], "data": data}


def _frame(frm, to, logs=(), calls=(), sel="0x12345678", typ="CALL"):
    return {"type": typ, "from": frm, "to": to, "input": sel + "00" * 4, "logs": list(logs), "calls": list(calls)}


EXEC_MODULE = "0x468721a7"
EXEC_OWNER = "0x6a761202"


class Provenance(unittest.TestCase):
    """ADR 0030 S13: keep a position only if its creating event was emitted inside a frame the account made."""

    def test_roles_module_execution_counts(self):
        # EOA -> Roles -> Safe (module exec) -> vault (emits)
        tr = _frame(EOA, ROLES, calls=[_frame(ROLES, SAFE, sel=EXEC_MODULE,
                                              calls=[_frame(SAFE, PROTO, logs=[_log("0x01")])])])
        self.assertTrue(s.emitted_inside_account_frame(tr, _log("0x01"), SAFE))

    def test_owner_exec_counts(self):
        tr = _frame(EOA, SAFE, sel=EXEC_OWNER, calls=[_frame(SAFE, PROTO, logs=[_log("0x01")])])
        self.assertTrue(s.emitted_inside_account_frame(tr, _log("0x01"), SAFE))

    def test_delegated_safe_code_does_not_count(self):
        # an attacker contract DELEGATECALLs / CALLCODEs the Safe's code with execTransaction: runs in ITS context
        for typ in ("DELEGATECALL", "CALLCODE"):
            tr = _frame(EOA, ROLES, calls=[_frame(ROLES, SAFE, sel=EXEC_OWNER, typ=typ,
                                                  calls=[_frame(ROLES, PROTO, logs=[_log("0x01")])])])
            self.assertFalse(s.emitted_inside_account_frame(tr, _log("0x01"), SAFE), typ)

    def test_fallback_handler_frame_does_not_count(self):
        # someone calls the Safe's fallback (no exec selector); the Safe forwards to its handler, which emits
        tr = _frame(EOA, SAFE, sel="0x150b7a02", calls=[_frame(SAFE, PROTO, logs=[_log("0x01")])])
        self.assertFalse(s.emitted_inside_account_frame(tr, _log("0x01"), SAFE))

    def test_bundled_third_party_deposit_does_not_count(self):
        # attacker contract executes an unrelated Safe tx AND, separately, creates a position naming the Safe
        tr = _frame(EOA, ROLES, calls=[_frame(ROLES, SAFE, sel=EXEC_MODULE,
                                              calls=[_frame(SAFE, PROTO, logs=[_log("0x01")])]),
                                       _frame(ROLES, PROTO, logs=[_log("0x02")])])
        self.assertFalse(s.emitted_inside_account_frame(tr, _log("0x02"), SAFE))

    def test_missing_log_or_trace_aborts(self):
        tr = _frame(EOA, SAFE, sel=EXEC_OWNER, calls=[_frame(SAFE, PROTO, logs=[_log("0x01")])])
        with self.assertRaises(s.SeedError):
            s.emitted_inside_account_frame(tr, _log("0x03"), SAFE)
        with self.assertRaises(s.SeedError):
            s.emitted_inside_account_frame(None, _log("0x01"), SAFE)

    def test_array_reply_check(self):
        self.assertTrue(s.is_abi_array_reply("0x" + s._word(32) + s._word(0)))
        self.assertFalse(s.is_abi_array_reply("0x"))
        self.assertFalse(s.is_abi_array_reply("0x" + s._word(64) + s._word(0)))

    def test_etherscan_zero_hex(self):
        self.assertEqual(s._hex("0x"), 0)
        self.assertEqual(s._hex("0x1f"), 31)


class Discovery(unittest.TestCase):
    VAULT = "0x4444444444444444444444444444444444444444"

    def setUp(self):
        self._orig = (s.etherscan_logs, s.c.rpc, s.c.eth_call, s.c.get_code)
        s.c.get_code = lambda url, addr: "0x60"

    def tearDown(self):
        s.etherscan_logs, s.c.rpc, s.c.eth_call, s.c.get_code = self._orig

    def _stub(self, logs_by_topic, executed_txs):
        s.etherscan_logs = lambda chain, addr, topics, fb: logs_by_topic.get(topics["topic0"], [])
        all_logs = [lg for v in logs_by_topic.values() for lg in v]

        def trace(url, m, params):
            mine = [lg for lg in all_logs if lg["transactionHash"] == params[0]]
            if params[0] in executed_txs:
                return _frame(EOA, ROLES, calls=[_frame(ROLES, SAFE, sel=EXEC_MODULE,
                                                        calls=[_frame(SAFE, PROTO, logs=mine)])])
            return _frame(EOA, ROLES, calls=[_frame(ROLES, PROTO, logs=mine)])
        s.c.rpc = trace

    def test_stakewise_entry_and_remainder_chain(self):
        entered = [
            {"transactionHash": "0xa", "data": "0x" + s._word(100) + s._word(5), "timeStamp": "0x10"},
            {"transactionHash": "0xb", "data": "0x" + s._word(200) + s._word(5), "timeStamp": "0x20"},  # third party
        ]
        claimed = [
            {"transactionHash": "0xc", "data": "0x" + s._word(100) + s._word(150) + s._word(1), "blockNumber": "0x2", "logIndex": "0x"},
            {"transactionHash": "0xd", "data": "0x" + s._word(150) + s._word(170) + s._word(1), "blockNumber": "0x3", "logIndex": "0x1"},
            {"transactionHash": "0xe", "data": "0x" + s._word(200) + s._word(250) + s._word(1), "blockNumber": "0x4", "logIndex": "0x0"},
        ]
        self._stub({s.TOPIC_EXIT_ENTERED: entered, s.TOPIC_EXITED_CLAIMED: claimed}, {"0xa"})
        found, skipped = s.discover(1, "stakewise", "u", [SAFE], 0, [self.VAULT])
        got = [c for _, c in found]
        self.assertEqual(got, [s.coord_stakewise(self.VAULT, t, 0x10) for t in (100, 150, 170)],
                         "remainders keep the ENTRY timestamp; the third-party ticket and its remainder are dropped")
        self.assertEqual(len(skipped), 1)

    def test_nft_mint_filtered_by_provenance(self):
        mints = [{"transactionHash": "0xa", "topics": [s.TOPIC_TRANSFER, "0x0", "0x0", "0x" + s._word(11)]},
                 {"transactionHash": "0xb", "topics": [s.TOPIC_TRANSFER, "0x0", "0x0", "0x" + s._word(12)]}]
        self._stub({s.TOPIC_TRANSFER: mints}, {"0xa"})
        found, skipped = s.discover(1, "etherfi", "u", [SAFE], 0, [])
        self.assertEqual(found, [(SAFE, s.coord_token(11))])
        self.assertEqual(len(skipped), 1)

    def test_validate_rejects_reverts_but_aborts_on_transport_errors(self):
        def call(url, to, data):
            if data.endswith(s._word(2)):
                raise s.c.RpcError("eth_call: {'message': 'execution reverted'}")
            if data.endswith(s._word(3)):
                raise s.c.RpcError("eth_call failed after 4 attempts: timeout")
            return "0x" + s._word(32) + s._word(0)
        s.c.eth_call = call
        ok, bad = s.validate("u", A2, [(SAFE, s.coord_token(1)), (SAFE, s.coord_token(2))])
        self.assertEqual(ok, [(SAFE, s.coord_token(1))])
        self.assertEqual(len(bad), 1)
        with self.assertRaises(s.SeedError):
            s.validate("u", A2, [(SAFE, s.coord_token(3))])
        def old_adapter(url, to, data):  # code-bearing, but no previewPositions → every call reverts
            raise s.c.RpcError("eth_call: {'message': 'execution reverted'}")
        s.c.eth_call = old_adapter
        with self.assertRaises(s.SeedError):
            s.validate("u", A2, [(SAFE, s.coord_token(1))])
        s.c.eth_call = lambda url, to, data: "0x"  # e.g. an EOA / undeployed address answers 0x
        with self.assertRaises(s.SeedError):
            s.validate("u", A2, [(SAFE, s.coord_token(1))])
        s.c.get_code = lambda url, addr: "0x"
        with self.assertRaises(s.SeedError):
            s.validate("u", A2, [(SAFE, s.coord_token(1))])

    def test_trace_rpc_failure_aborts(self):
        def boom(url, m, params):
            raise s.c.RpcError("debug_traceTransaction: method not found")
        s.c.rpc = boom
        with self.assertRaises(s.SeedError):
            s.created_by_account("u", {"transactionHash": "0xa"}, SAFE, {})

    def test_old_adapter_probe(self):
        s.c.eth_call = lambda url, to, data: "0x"
        with self.assertRaises(s.SeedError):
            s.probe_coords_of("u", A2, "--old")
        s.c.eth_call = lambda url, to, data: "0x" + s._word(32) + s._word(0)
        s.probe_coords_of("u", A2, "--old")  # an empty bytes[] is a valid answer

    def test_migrate_reads_live_cache_per_account(self):
        logs = [{"topics": [s.TOPIC_COORD_SUBMITTED, "0x" + s._addr_word(SAFE)]},
                {"topics": [s.TOPIC_COORD_SUBMITTED, "0x" + s._addr_word(SAFE)]}]
        s.etherscan_logs = lambda chain, addr, topics, fb: logs
        s.c.eth_call = lambda url, to, data: "0x" + s._word(32) + s.encode_bytes_array([s.coord_token(9)])
        self.assertEqual(s.migrate(1, "u", A2, 0), [(SAFE, s.coord_token(9))])


if __name__ == "__main__":
    unittest.main()
