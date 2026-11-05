"""Offline tests for assisted_monitor.py (no network). Calldata / return-value vectors were produced with
`cast calldata` / `cast abi-encode` and are pinned so the hand-rolled ABI is checked against an independent encoder."""
import unittest

import assisted_monitor as m
import chainlib as c

A1 = "0x1111111111111111111111111111111111111111"
A2 = "0x2222222222222222222222222222222222222222"
COUNCIL = "0x8b884f80b3b839f52b6ce168f133e7a5d1f0a537"
KEEPER = "0x3333333333333333333333333333333333333333"
NAV = "0x4444444444444444444444444444444444444444"
ADAPTER = "0x5555555555555555555555555555555555555555"
CAST_HAS_ROLE = "0x91d1485412b80c3c1a8f58857e0e80e1961585f574502e089ca974eb9fcf05cf904fe0120000000000000000000000001111111111111111111111111111111111111111"
CAST_COORDS_OF = "0x197c3a510000000000000000000000002222222222222222222222222222222222222222"
CAST_ADDRESS_ARRAY = "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000011111111111111111111111111111111111111110000000000000000000000002222222222222222222222222222222222222222"
CAST_BYTES_ARRAY = "0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000001010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020203000000000000000000000000000000000000000000000000000000000000"


def word(n):
    return "0x" + format(n, "064x")


def empty_array():
    return "0x" + format(32, "064x") + format(0, "064x")


def bytes_array_of(n):
    """A `coordsOf` reply with n one-word coordinates."""
    head = format(32, "064x") + format(n, "064x")
    offs = "".join(format(32 * n + 64 * i, "064x") for i in range(n))
    tails = "".join(format(32, "064x") + format(i, "064x") for i in range(n))
    return "0x" + head + offs + tails


def addr_array(xs):
    return "0x" + format(32, "064x") + format(len(xs), "064x") + "".join("0" * 24 + x[2:] for x in xs)


def granted(account):
    return {"topics": [m.TOPIC_ROLE_GRANTED, "0x00", "0x" + "0" * 24 + account[2:], "0x00"]}


class Chain:
    """A stub adapter + NAV answering by selector."""

    def __init__(self, cap_sel="696ef305", cap=256, reserve=32, used=None, admins=(COUNCIL,), submitters=(),
                 granted_admins=None, granted_submitters=None, nav_adapters=()):
        self.cap_sel, self.cap, self.reserve = cap_sel, cap, reserve
        self.used = used or {}
        self.admins, self.submitters = {x.lower() for x in admins}, {x.lower() for x in submitters}
        self.granted = {m.DEFAULT_ADMIN_ROLE: list(granted_admins if granted_admins is not None else admins),
                        m.SUBMITTER_ROLE: list(granted_submitters if granted_submitters is not None else submitters)}
        self.nav_adapters = list(nav_adapters)

    def call(self, to, data):
        sel = data[2:10]
        if to == NAV:
            if sel != m.SEL_GET_ALL_ADAPTERS:
                raise AssertionError(sel)
            return addr_array(self.nav_adapters)
        if sel in m.SEL_CAP:
            if sel != self.cap_sel:
                raise c.RpcError("eth_call: {'message': 'execution reverted'}")
            return word(self.cap)
        if sel == m.SEL_OWNER_RESERVE:
            return word(self.reserve)
        if sel == m.SEL_SUBMITTER_ROLE:
            return m.SUBMITTER_ROLE
        if sel == "197c3a51":
            return bytes_array_of(self.used.get("0x" + data[-40:], 0))
        if sel == m.SEL_HAS_ROLE:
            role, who = "0x" + data[10:74], "0x" + data[-40:]
            held = self.admins if role == m.DEFAULT_ADMIN_ROLE else self.submitters
            return word(1 if who in held else 0)
        raise AssertionError(f"unexpected call {data[:10]}")

    def logs(self, chain, address, topics, from_block):
        if topics["topic0"] != m.TOPIC_ROLE_GRANTED:
            raise AssertionError(topics)
        return [granted(x.lower()) for x in self.granted[topics["topic1"]]]


RECORD = {"NAVCalculatorProxy": NAV, "balanceAdapters": {"FooAssisted": ADAPTER, "BarMeta": A2, "Empty": ""}}


def run(chain, accounts=(A1,), expect_submitter=(), record=RECORD):
    return m.run_chain(1, chain.call, chain.logs, record, list(accounts), {COUNCIL}, set(expect_submitter))


class Encoding(unittest.TestCase):
    def test_has_role_matches_cast(self):
        self.assertEqual(m.encode_has_role(m.SUBMITTER_ROLE, A1), CAST_HAS_ROLE)

    def test_coords_of_matches_cast(self):
        self.assertEqual(m.encode_coords_of(A2), CAST_COORDS_OF)

    def test_address_array_decodes_cast(self):
        self.assertEqual(m.decode_address_array(CAST_ADDRESS_ARRAY), [A1, A2])

    def test_coords_count_on_cast_bytes_array(self):
        self.assertEqual(m.coords_count(CAST_BYTES_ARRAY), 2)

    def test_coords_count_rejects_non_array(self):
        with self.assertRaises(m.MonitorError):
            m.coords_count(word(5))

    def test_bool_rejects_garbage(self):
        with self.assertRaises(m.MonitorError):
            m.decode_bool(word(2))

    def test_bad_role_rejected(self):
        with self.assertRaises(m.MonitorError):
            m.encode_has_role("0x12", A1)


class Thresholds(unittest.TestCase):
    def test_keeper_limit_mirrors_contract(self):
        self.assertEqual(m.keeper_limit(256, 32), 224)
        self.assertEqual(m.keeper_limit(32, 32), 0)
        self.assertEqual(m.keeper_limit(10, 32), 0)

    def test_status_bands(self):
        self.assertEqual(m.slot_status(0, 224), "OK")
        self.assertEqual(m.slot_status(179, 224), "OK")
        self.assertEqual(m.slot_status(180, 224), "WARN")  # 0.8 * 224 = 179.2
        self.assertEqual(m.slot_status(223, 224), "WARN")
        self.assertEqual(m.slot_status(224, 224), "ALERT")
        self.assertEqual(m.slot_status(256, 224), "ALERT")

    def test_disabled_keeper_path_alerts(self):
        self.assertEqual(m.slot_status(0, 0), "ALERT")


class Report(unittest.TestCase):
    def test_clean_chain(self):
        r = run(Chain())
        self.assertEqual(len(r["adapters"]), 1, "only *Assisted keys with an address")
        ad = r["adapters"][0]
        self.assertEqual((ad["cap"], ad["ownerReserve"], ad["keeperLimit"]), (256, 32, 224))
        self.assertEqual(ad["accounts"][0]["used"], 0)
        self.assertEqual(ad["admins"], [COUNCIL])
        self.assertEqual(ad["submitters"], [])
        self.assertFalse(ad["registeredOnNav"])
        self.assertEqual(ad["problems"], [])
        self.assertEqual(m.verdict([r]), 0)

    def test_stakewise_cap_getter(self):
        sw = {"NAVCalculatorProxy": NAV, "balanceAdapters": {"StakeWiseV3ExitQueueAssisted": ADAPTER}}
        ad = run(Chain(cap_sel="f7b24e08", cap=256), record=sw)["adapters"][0]
        self.assertEqual(ad["keeperLimit"], 224)

    def test_registered_on_nav(self):
        self.assertTrue(run(Chain(nav_adapters=[ADAPTER]))["adapters"][0]["registeredOnNav"])

    def test_warn_does_not_fail(self):
        r = run(Chain(used={A1: 200}))
        self.assertEqual(r["adapters"][0]["accounts"][0]["status"], "WARN")
        self.assertEqual(m.verdict([r]), 0)

    def test_alert_fails(self):
        r = run(Chain(used={A1: 224}), accounts=(A1, A2))
        rows = r["adapters"][0]["accounts"]
        self.assertEqual([x["status"] for x in rows], ["ALERT", "OK"])
        self.assertEqual((rows[0]["keeperFree"], rows[0]["ownerFree"]), (0, 32))
        self.assertEqual(m.verdict([r]), 1)

    def test_unexpected_submitter_fails(self):
        r = run(Chain(submitters=[KEEPER]))
        self.assertEqual(r["adapters"][0]["submitters"], [KEEPER])
        self.assertEqual(m.verdict([r]), 1)

    def test_expected_submitter_passes(self):
        self.assertEqual(m.verdict([run(Chain(submitters=[KEEPER]), expect_submitter=[KEEPER])]), 0)

    def test_revoked_grant_is_not_a_holder(self):
        r = run(Chain(submitters=[], granted_submitters=[KEEPER]))
        self.assertEqual(r["adapters"][0]["submitters"], [])
        self.assertEqual(m.verdict([r]), 0)

    def test_extra_admin_fails(self):
        r = run(Chain(admins=[COUNCIL, A2]))
        self.assertIn(f"unexpected DEFAULT_ADMIN_ROLE holder {A2}", r["adapters"][0]["problems"])
        self.assertEqual(m.verdict([r]), 1)

    def test_missing_council_admin_fails(self):
        r = run(Chain(admins=[A2]))
        self.assertTrue(any("does not hold" in p for p in r["adapters"][0]["problems"]))
        self.assertEqual(m.verdict([r]), 1)

    def test_read_error_is_exit_2(self):
        self.assertEqual(m.verdict([{"chain": 1, "error": "x", "adapters": []}]), 2)

    def test_render_mentions_status(self):
        out = m.render([run(Chain(used={A1: 224}))])
        self.assertIn("ALERT", out)
        self.assertIn("keeper limit 224", out)


class Misc(unittest.TestCase):
    def test_redact(self):
        self.assertEqual(m.redact("GET https://x/v2/SECRET?k=KEY failed", ["https://x/v2/SECRET", "KEY", ""]),
                         "GET ***?k=*** failed")

    def test_redact_path_only_transport_error(self):
        url = "https://mainnet.infura.io/v3/SECRETKEY123?x=QTOKEN"
        msg = ("RpcError: eth_call failed after 4 attempts: HTTPSConnectionPool(host='mainnet.infura.io', port=443): "
               "Max retries exceeded with url: /v3/SECRETKEY123?x=QTOKEN (Caused by NewConnectionError)")
        out = m.redact(msg, m.url_secrets(url))
        self.assertNotIn("SECRETKEY123", out)
        self.assertNotIn("QTOKEN", out)
        self.assertNotIn("SECRETKEY123", m.redact("GET " + url + " failed", m.url_secrets(url)))

    def test_redact_userinfo(self):
        self.assertNotIn("pw", m.redact("x https://user:pw@h/ y", m.url_secrets("https://user:pw@h/")))

    def test_alert_not_masked_by_other_chains_read_failure(self):
        ok = run(Chain(used={A1: 224}))
        failed = {"chain": 100, "error": "no RPC", "adapters": []}
        self.assertEqual(m.verdict([ok, failed]), 1)
        self.assertEqual(m.verdict([run(Chain()), failed]), 2)

    def test_cap_read_propagates_transport_errors(self):
        def call(to, data):
            raise c.RpcError("eth_call failed after 4 attempts: timeout")
        with self.assertRaises(c.RpcError):
            m.read_cap(call, ADAPTER, "EtherFiWithdrawalQueueAssisted")

    def test_empty_accounts_file_is_an_error(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# only a comment\n\n")
        with self.assertRaises(m.MonitorError):
            m.read_accounts(f.name)

    def test_chain_without_assisted_adapters_is_an_error(self):
        with self.assertRaises(m.MonitorError):
            run(Chain(), record={"NAVCalculatorProxy": NAV, "balanceAdapters": {"BarMeta": A2}})

    def test_expected_submitter_found_even_if_logs_miss_it(self):
        chain = Chain(submitters=(A2,))
        chain.logs = lambda *a, **k: []  # log index lagging: no RoleGranted at all
        ad = run(chain, expect_submitter=(A2,))["adapters"][0]
        self.assertEqual(ad["submitters"], [A2.lower()])


if __name__ == "__main__":
    unittest.main()
