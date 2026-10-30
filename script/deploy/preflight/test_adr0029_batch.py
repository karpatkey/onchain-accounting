#!/usr/bin/env python3
"""Pins adr0029_batch.py and council_fork_exec.py offline (no network, no anvil). Run with `python3 -m unittest`
and under `python3 -O` (the CI flag).

The property most worth pinning: the removal batch is DERIVED from live state vs config, so the builder must refuse
unless what it derives equals what the operator expected — an accidental unregistration must be impossible.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import adr0029_batch as ab  # noqa: E402
import importlib.util  # noqa: E402

# The Transaction-Builder checksum is keccak(abi.encode(...)) via eth_abi/eth_utils, which the CI preflight job
# (requests only) does not install; the tests that compute one are skipped there and run wherever they exist.
HAS_ETH_ABI = importlib.util.find_spec("eth_abi") is not None and importlib.util.find_spec("eth_utils") is not None
needs_eth_abi = unittest.skipUnless(HAS_ETH_ABI, "eth_abi/eth_utils not installed (CI preflight job)")
import adr0029_census as ac  # noqa: E402
import council_fork_exec as cfe  # noqa: E402
from test_adr0029_census import enc_assets  # noqa: E402

EZETH = "0x" + "e1" * 20
EIGEN = "0x" + "e2" * 20
WETH = "0x" + "aa" * 20
RENZO = "0x" + "91" * 20
OTHER = "0x" + "92" * 20
AKR = "0x" + "f6" * 20


def _w(x: int) -> str:
    return x.to_bytes(32, "big").hex()


def enc_addrs(addrs):
    return "0x" + _w(32) + _w(len(addrs)) + "".join(a[2:].rjust(64, "0") for a in addrs)


class Fake:
    def __init__(self, assets, adapters):
        self.assets, self.adapters = assets, adapters

    def call(self, to, data):
        if data == ac.SEL_GET_REGISTERED_ASSETS:
            return enc_assets(self.assets)
        if data == ab.SEL_GET_ALL_ADAPTERS:
            return enc_addrs(self.adapters)
        if data == ab.SEL_DEFAULT_ADAPTER:
            return "0x" + "00" * 32  # no default adapter in these fixtures
        raise AssertionError(data)


class Derivation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = Path(self.tmp.name)
        for d in ("nav-config/assets-and-price-feeds", "nav-config/meta-balance-adapters", "deployments", "chains"):
            (r / d).mkdir(parents=True)
        (r / "nav-config/assets-and-price-feeds/1.json").write_text(json.dumps({"WETH": {"address": WETH}}))
        (r / "nav-config/meta-balance-adapters/1.json").write_text(json.dumps(
            {"RenzoMeta": {"enabled": False}, "OtherMeta": {"enabled": True}}))
        (r / "deployments/1.json").write_text(json.dumps(
            {"AssetKindRegistry": AKR, "balanceAdapters": {"RenzoMeta": RENZO, "OtherMeta": OTHER}}))
        (r / "chains/1.json").write_text(json.dumps({"addresses": {"securityCouncil": "0x" + "c0" * 20}}))
        self.saved = (ab.c.NAV_CONFIG_DIR, ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR)
        ab.c.NAV_CONFIG_DIR, ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR = r / "nav-config", r / "deployments", r / "chains"

    def tearDown(self):
        ab.c.NAV_CONFIG_DIR, ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR = self.saved
        self.tmp.cleanup()

    def test_derives_assets_missing_from_config_and_disabled_registered_adapters(self):
        adapters, assets = ab.derive_removals(1, Fake([WETH, EZETH, EIGEN], [OTHER, RENZO]))
        self.assertEqual(adapters, [RENZO])
        self.assertEqual(assets, sorted([EZETH, EIGEN]))

    def test_native_placeholder_is_never_a_removal(self):
        # Registered by NAVCalculator.initialize on every chain; chains with no assets have no asset config at all.
        _, assets = ab.derive_removals(1, Fake([WETH, ab.NATIVE_ADDRESS], [OTHER]))
        self.assertEqual(assets, [])

    def test_disabled_but_unregistered_adapter_is_not_removed(self):
        adapters, _ = ab.derive_removals(1, Fake([WETH], [OTHER]))
        self.assertEqual(adapters, [])

    def test_removal_calls_adapters_first_then_registry(self):
        txs = ab.removal_transactions(1, [RENZO], [EIGEN, EZETH])
        self.assertEqual([t["to"] for t in txs], [ac.NAV_PROXY, AKR, AKR])
        self.assertTrue(txs[0]["data"].startswith("0x3aecc485"))  # removeBalanceAdapters(address[])
        self.assertTrue(all(t["data"].startswith("0xc906d2cf") for t in txs[1:]))  # unregisterAsset(address)

    def test_refuses_when_derived_differs_from_expected(self):
        class A:
            chain, rpc_url, rpc_env, out = 1, "http://127.0.0.1:1", None, "/dev/null"
            expect_assets, expect_adapters = EZETH, RENZO  # EIGEN missing from the expectation
        saved = ab._reader
        ab._reader = lambda a: Fake([WETH, EZETH, EIGEN], [OTHER, RENZO])
        try:
            with self.assertRaises(ab.BatchError):
                ab.cmd_removals(A)
        finally:
            ab._reader = saved

    def test_the_navs_erc20_default_adapter_is_exempt(self):
        default = "0x" + "4b" * 20  # registered, never listed in config

        class WithDefault(Fake):
            def call(self, to, data):
                if data == ab.SEL_DEFAULT_ADAPTER:
                    return "0x" + default[2:].rjust(64, "0")
                return super().call(to, data)
        adapters, _ = ab.derive_removals(1, WithDefault([WETH], [default, OTHER, RENZO]))
        self.assertEqual(adapters, [RENZO])

    def test_unexplained_registered_adapter_is_refused(self):
        stray = "0x" + "93" * 20  # registered, but neither enabled nor disabled in config
        with self.assertRaises(ab.BatchError):
            ab.derive_removals(1, Fake([WETH], [OTHER, RENZO, stray]))

    def _assemble(self, parts):
        class A:
            chain, upgrade_impl = 1, OTHER
        A.parts = parts
        A.out = str(Path(self.tmp.name) / "out.json")
        return ab.cmd_assemble(A)

    def test_assemble_refuses_an_absent_part(self):
        with self.assertRaises(ab.BatchError):
            self._assemble([str(Path(self.tmp.name) / "missing.json")])

    @needs_eth_abi
    def test_assemble_refuses_a_part_whose_checksum_does_not_match(self):
        part = str(Path(self.tmp.name) / "p.json")
        ab.write_batch(part, 1, "0x" + "c0" * 20, "n", "d",
                       [{"to": AKR, "value": "0", "data": ab.enc_unregister_asset(EZETH), "operation": 0}])
        d = json.loads(Path(part).read_text())
        d["transactions"][0]["data"] = ab.enc_unregister_asset(EIGEN)  # edited by hand
        Path(part).write_text(json.dumps(d))
        with self.assertRaises(ab.BatchError):
            self._assemble([part])

    @needs_eth_abi
    def test_assemble_accepts_an_empty_part_and_puts_the_upgrade_last(self):
        empty = str(Path(self.tmp.name) / "e.json")
        ab.write_batch(empty, 1, "0x" + "c0" * 20, "n", "d", [])
        part = str(Path(self.tmp.name) / "p.json")
        ab.write_batch(part, 1, "0x" + "c0" * 20, "n", "d",
                       [{"to": AKR, "value": "0", "data": ab.enc_unregister_asset(EZETH), "operation": 0}])
        self.assertEqual(self._assemble([empty, part]), 0)
        out = json.loads((Path(self.tmp.name) / "out.json").read_text())
        self.assertEqual(len(out["transactions"]), 2)
        self.assertTrue(out["transactions"][-1]["data"].startswith(ab.SEL_UPGRADE_TO_AND_CALL))
        self.assertEqual(out["meta"]["checksum"], ab.checksum(out["transactions"]))

    @needs_eth_abi
    def test_assemble_refuses_a_part_emptied_by_hand(self):
        part = str(Path(self.tmp.name) / "p.json")
        ab.write_batch(part, 1, "0x" + "c0" * 20, "n", "d",
                       [{"to": AKR, "value": "0", "data": ab.enc_unregister_asset(EZETH), "operation": 0}])
        for edit in (lambda d: d.update(transactions=[]), lambda d: d.pop("transactions")):
            d = json.loads(Path(part).read_text())
            edit(d)
            emptied = str(Path(self.tmp.name) / "emptied.json")
            Path(emptied).write_text(json.dumps(d))
            with self.assertRaises(ab.BatchError):
                self._assemble([emptied])

    def test_assemble_refuses_an_unstamped_empty_part(self):
        part = Path(self.tmp.name) / "u.json"
        part.write_text(json.dumps({"chainId": "1", "meta": {"createdFromSafeAddress": "0x" + "c0" * 20},
                                    "transactions": []}))
        with self.assertRaises(ab.BatchError):
            self._assemble([str(part)])

    def test_reader_refuses_an_endpoint_for_another_chain(self):
        class A:
            chain, rpc_url, rpc_env = 42161, "http://127.0.0.1:1", None
        saved = ab.ac.LiveReader.chain_id
        ab.ac.LiveReader.chain_id = lambda self: 10
        try:
            with self.assertRaises(ab.BatchError):
                ab._reader(A)
        finally:
            ab.ac.LiveReader.chain_id = saved

    def _ui_file(self, **over):
        tx = {"to": AKR, "value": "0", "data": None, "operation": 0,
              "contractMethod": {"name": "scheduleBatch", "inputs": [
                  {"name": "targets", "type": "address[]"}, {"name": "values", "type": "uint256[]"},
                  {"name": "payloads", "type": "bytes[]"}, {"name": "predecessor", "type": "bytes32"},
                  {"name": "salt", "type": "bytes32"}, {"name": "delay", "type": "uint256"}]},
              "contractInputsValues": {"targets": json.dumps([OTHER]), "values": json.dumps(["0"]),
                                       "payloads": json.dumps(["0x1234"]), "predecessor": "0x" + "00" * 32,
                                       "salt": "0x" + "00" * 32, "delay": "259200"}}
        tx.update(over.pop("tx", {}))
        doc = {"chainId": "1", "meta": {"createdFromSafeAddress": "0x" + "c0" * 20, "checksum": ""},
               "transactions": [tx]}
        doc.update(over)
        self._n = getattr(self, "_n", 0) + 1
        f = Path(self.tmp.name) / f"ui{self._n}.json"  # one file per fixture: a shared path made the refusals vacuous
        f.write_text(json.dumps(doc))
        return f

    def _import(self, f):
        class A:
            chain = 1
        A.input, A.out = str(f), str(Path(self.tmp.name) / "imported.json")
        return ab.cmd_import(A)

    @needs_eth_abi
    def test_import_encodes_the_ui_method_form_and_stamps_it(self):
        self.assertEqual(self._import(self._ui_file()), 0)
        out = json.loads((Path(self.tmp.name) / "imported.json").read_text())
        data = out["transactions"][0]["data"]
        self.assertTrue(data.startswith("0x8f2a0bb0"))  # scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)
        self.assertEqual(out["meta"]["checksum"], ab.checksum(out["transactions"]))
        self.assertIn("sha256", out["meta"]["description"])
        self.assertEqual(self._assemble([str(Path(self.tmp.name) / "imported.json")]), 0)

    @needs_eth_abi
    @unittest.skipUnless(shutil.which("cast"), "cast not installed")
    def test_import_matches_cast(self):
        self._import(self._ui_file())
        data = json.loads((Path(self.tmp.name) / "imported.json").read_text())["transactions"][0]["data"]
        want = subprocess.run(["cast", "calldata", "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
                               f"[{OTHER}]", "[0]", "[0x1234]", "0x" + "00" * 32, "0x" + "00" * 32, "259200"],
                              capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(data, want)

    def test_import_refuses_another_safe_chain_value_delegatecall_tuples_or_no_call(self):
        bad = {"another Safe": self._ui_file(meta={"createdFromSafeAddress": "0x" + "5d" * 20}),
               "another chain": self._ui_file(chainId="10"),
               "value": self._ui_file(tx={"value": "1"}),
               "delegatecall": self._ui_file(tx={"operation": 1}),
               "tuple": self._ui_file(tx={"contractMethod": {"name": "f", "inputs": [{"name": "x", "type": "tuple[]"}]},
                                          "contractInputsValues": {"x": "[]"}}),
               "no transactions": self._ui_file(transactions=[]),
               "zero to": self._ui_file(tx={"to": "0x" + "00" * 20}),
               "empty call": self._ui_file(tx={"data": "0x", "contractMethod": None})}
        self.assertEqual(len({str(f) for f in bad.values()}), len(bad), "every fixture is its own file")
        for why, f in bad.items():
            with self.assertRaises(ab.BatchError, msg=why):
                self._import(f)

    def test_abi_values_are_strict(self):
        for typ, v in (("bool", "1"), ("bool", "yes"), ("bytes32", "0x12"), ("uint256", " 1"), ("uint256", "1e3"),
                       ("uint256", "-1"), ("address", "0x" + "00" * 20), ("bytes", "0x123")):
            with self.assertRaises(ab.BatchError, msg=f"{typ} {v!r}"):
                ab._abi_value(typ, v)
        self.assertEqual(ab._abi_value("uint256", "0x10"), 16)
        self.assertEqual(ab._abi_value("bool", "TRUE"), True)
        self.assertEqual(ab._abi_value("address[]", json.dumps([OTHER])), [OTHER])

    @needs_eth_abi
    def test_bad_eip55_checksum_is_refused(self):
        good = "0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537"
        self.assertEqual(ab._strict_address(good), good)
        with self.assertRaises(ab.BatchError):
            ab._strict_address(good.replace("B3B8", "b3B8"))

    @needs_eth_abi
    def test_assembled_description_carries_the_import_provenance(self):
        self._import(self._ui_file())
        self._assemble([str(Path(self.tmp.name) / "imported.json")])
        out = json.loads((Path(self.tmp.name) / "out.json").read_text())
        self.assertIn("sha256", out["meta"]["description"])

    def test_real_endpoint_must_come_from_env(self):
        class A:
            rpc_url, rpc_env = "https://example.invalid/v2/key", None
        with self.assertRaises(ab.BatchError):
            ab._reader(A)



class Encoding(unittest.TestCase):
    def test_hand_encoded_calldata_matches_pinned_vectors(self):
        # Vectors computed once with `cast calldata`, so CI (no Foundry) still pins the encoders.
        self.assertEqual(ab.enc_remove_balance_adapters([RENZO, OTHER]), "0x3aecc4850000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000091919191919191919191919191919191919191910000000000000000000000009292929292929292929292929292929292929292")
        self.assertEqual(ab.enc_unregister_asset(EZETH), "0xc906d2cf000000000000000000000000e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1")
        self.assertEqual(ab.enc_upgrade_to_and_call(OTHER), "0x4f1ef286000000000000000000000000929292929292929292929292929292929292929200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000")

    @unittest.skipUnless(shutil.which("cast"), "cast not installed (CI preflight job has no Foundry)")
    def test_hand_encoded_calldata_matches_cast(self):
        def cast(*a):
            return subprocess.run(["cast", "calldata", *a], capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(ab.enc_remove_balance_adapters([RENZO, OTHER]),
                         cast("removeBalanceAdapters(address[])", f"[{RENZO},{OTHER}]"))
        self.assertEqual(ab.enc_unregister_asset(EZETH), cast("unregisterAsset(address)", EZETH))
        self.assertEqual(ab.enc_upgrade_to_and_call(OTHER), cast("upgradeToAndCall(address,bytes)", OTHER, "0x"))

    def test_decode_addresses(self):
        self.assertEqual(ab.decode_addresses(enc_addrs([RENZO, OTHER])), [RENZO, OTHER])

    def test_approved_signatures_are_sorted_v1_and_unique(self):
        lo, hi = "0x" + "01" * 20, "0x" + "ff" * 20
        sig = cfe.approved_signatures([hi, lo])
        self.assertEqual(len(sig), 2 + 2 * 65 * 2)
        first, second = sig[2:132], sig[132:]
        self.assertEqual(first[24:64], lo[2:])
        self.assertEqual(second[24:64], hi[2:])
        self.assertTrue(first.endswith("01") and second.endswith("01"))
        with self.assertRaises(cfe.CouncilForkError):
            cfe.approved_signatures([lo, lo.upper().replace("0X", "0x")])

    def test_fork_executor_refuses_a_real_endpoint(self):
        with self.assertRaises(cfe.CouncilForkError):
            cfe._loopback("https://eth-mainnet.example/v2/key")


class Governance(unittest.TestCase):
    """The timelock handover (`governance`): order, and every refusal that guards against an admin-less NAV."""
    TL, COUNCIL, NAV = "0x" + "ab" * 20, "0x" + "c0" * 20, "0x54ead2a1db7456ca917675ea8908ec8a997c6214"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = Path(self.tmp.name)
        for d in ("deployments", "chains"):
            (r / d).mkdir(parents=True)
        (r / "deployments/1.json").write_text(json.dumps({"TimelockController": self.TL}))
        (r / "chains/1.json").write_text(json.dumps({"addresses": {"securityCouncil": self.COUNCIL}}))
        self.saved = (ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR)
        ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR = r / "deployments", r / "chains"

    def tearDown(self):
        ab.c.DEPLOY_DIR, ab.c.CHAINS_DIR = self.saved
        self.tmp.cleanup()

    def reader(self, delay=0, roles=None):
        """roles: set of (contract, role_hex, account) that hold; default = today's live state on all 25 chains."""
        t, c_, n = self.TL, self.COUNCIL, self.NAV
        held = roles if roles is not None else {
            (n, ab.ROLE_DEFAULT_ADMIN, t), (n, ab.ROLE_MANAGER, t), (n, ab.ROLE_DEFAULT_ADMIN, c_),
            (n, ab.ROLE_MANAGER, c_), (t, ab.ROLE_DEFAULT_ADMIN, t), (t, ab.ROLE_TL_PROPOSER, c_),
            (t, ab.ROLE_TL_EXECUTOR, "0x" + "00" * 20)}

        class R:
            def call(_, to, data):
                if data == ab.SEL_TL_GET_MIN_DELAY:
                    return "0x" + f"{delay:064x}"
                assert data.startswith(ab.SEL_HAS_ROLE), data
                role, acct = data[10:74], "0x" + data[-40:]
                return "0x" + f"{int((to.lower(), role, acct.lower()) in held):064x}"
        return R()

    def test_order_is_schedule_execute_then_renounce_manager_then_admin(self):
        txs, _ = ab.governance_transactions(1, self.reader(), proxy=self.NAV)
        self.assertEqual([t["data"][:10] for t in txs],
                         [ab.SEL_TL_SCHEDULE, ab.SEL_TL_EXECUTE, ab.SEL_RENOUNCE_ROLE, ab.SEL_RENOUNCE_ROLE])
        self.assertEqual([t["to"].lower() for t in txs], [self.TL, self.TL, self.NAV, self.NAV])
        self.assertEqual(txs[2]["data"][10:74], ab.ROLE_MANAGER)
        self.assertEqual(txs[3]["data"][10:74], ab.ROLE_DEFAULT_ADMIN)
        self.assertTrue(all(t["operation"] == 0 and t["value"] == "0" for t in txs))
        # The exact operation: same data + salt in schedule and execute, delay 0, renounces for the Council itself.
        upd = ab.enc_update_delay(ab.TIMELOCK_DELAY_S)
        self.assertEqual(txs[0]["data"], ab.enc_tl_schedule(self.TL, upd, ab.UPDATE_DELAY_SALT, 0))
        self.assertEqual(txs[1]["data"], ab.enc_tl_execute(self.TL, upd, ab.UPDATE_DELAY_SALT))
        self.assertTrue(all(t["data"][-40:] == self.COUNCIL[2:] for t in txs[2:]))

    def test_no_contract_at_the_nav_is_a_clean_refusal(self):
        class Empty:
            def call(_, to, data):
                return "0x"
        with self.assertRaises(ab.BatchError):
            ab.governance_transactions(1, Empty(), proxy=self.NAV)

    def test_no_answer_from_get_min_delay_is_a_clean_refusal(self):
        inner = self.reader()

        class NoDelay:
            def call(_, to, data):
                return "0x" if data == ab.SEL_TL_GET_MIN_DELAY else inner.call(to, data)
        with self.assertRaises(ab.BatchError):
            ab.governance_transactions(1, NoDelay(), proxy=self.NAV)

    def test_refuses_when_renouncing_would_strand_the_nav(self):
        for missing in ((self.NAV, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.NAV, ab.ROLE_MANAGER, self.TL),
                        (self.TL, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.TL, ab.ROLE_TL_PROPOSER, self.COUNCIL)):
            roles = {(self.NAV, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.NAV, ab.ROLE_MANAGER, self.TL),
                     (self.TL, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.TL, ab.ROLE_TL_PROPOSER, self.COUNCIL),
                     (self.NAV, ab.ROLE_MANAGER, self.COUNCIL), (self.TL, ab.ROLE_TL_EXECUTOR, "0x" + "00" * 20)}
            roles.discard(missing)
            with self.assertRaises(ab.BatchError, msg=str(missing)):
                ab.governance_transactions(1, self.reader(roles=roles), proxy=self.NAV)

    def test_refuses_without_an_executor(self):
        roles = {(self.NAV, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.NAV, ab.ROLE_MANAGER, self.TL),
                 (self.TL, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.TL, ab.ROLE_TL_PROPOSER, self.COUNCIL)}
        with self.assertRaises(ab.BatchError):
            ab.governance_transactions(1, self.reader(roles=roles), proxy=self.NAV)

    def test_refuses_a_nonzero_delay_that_is_not_the_target(self):
        with self.assertRaises(ab.BatchError):
            ab.governance_transactions(1, self.reader(delay=60), proxy=self.NAV)

    def test_already_handed_over_yields_no_calls(self):
        roles = {(self.NAV, ab.ROLE_DEFAULT_ADMIN, self.TL), (self.NAV, ab.ROLE_MANAGER, self.TL),
                 (self.TL, ab.ROLE_DEFAULT_ADMIN, self.TL)}
        txs, _ = ab.governance_transactions(1, self.reader(delay=ab.TIMELOCK_DELAY_S, roles=roles), proxy=self.NAV)
        self.assertEqual(txs, [])

    def test_hand_encoding_matches_pinned_cast_vectors(self):
        tl = "0xAB92EA75D07792915eB1f29259354866B880dFC2"
        d = ab.enc_update_delay(259200)
        self.assertEqual(d, "0x64d62353000000000000000000000000000000000000000000000000000000000003f480")
        self.assertEqual(ab.enc_tl_schedule(tl, d, ab.UPDATE_DELAY_SALT, 0), "0x01d5062a000000000000000000000000ab92ea75d07792915eb1f29259354866b880dfc2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000008d5862e484f0cb25822eb596e2db031df6ab6e804ea496d2301f0169e5bc35350000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002464d62353000000000000000000000000000000000000000000000000000000000003f48000000000000000000000000000000000000000000000000000000000")
        self.assertEqual(ab.enc_tl_execute(tl, d, ab.UPDATE_DELAY_SALT), "0x134008d3000000000000000000000000ab92ea75d07792915eb1f29259354866b880dfc2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000008d5862e484f0cb25822eb596e2db031df6ab6e804ea496d2301f0169e5bc3535000000000000000000000000000000000000000000000000000000000000002464d62353000000000000000000000000000000000000000000000000000000000003f48000000000000000000000000000000000000000000000000000000000")
        self.assertEqual(ab.enc_renounce_role(ab.ROLE_MANAGER, "0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537"), "0x36568abeaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c0000000000000000000000008b884f80b3b839f52b6ce168f133e7a5d1f0a537")

    @unittest.skipUnless(shutil.which("cast"), "cast not installed (CI preflight job has no Foundry)")
    def test_role_and_salt_constants_match_keccak(self):
        def k(x):
            return subprocess.run(["cast", "keccak", x], capture_output=True, text=True, check=True).stdout.strip()[2:]
        self.assertEqual(ab.ROLE_MANAGER, k("MANAGER"))
        self.assertEqual(ab.ROLE_TL_PROPOSER, k("PROPOSER_ROLE"))
        self.assertEqual(ab.ROLE_TL_EXECUTOR, k("EXECUTOR_ROLE"))
        self.assertEqual(ab.UPDATE_DELAY_SALT, k("ADR0029 rollout: timelock updateDelay"))

    def test_the_target_delay_is_three_days(self):
        self.assertEqual(ab.TIMELOCK_DELAY_S, 3 * 24 * 3600)

    @needs_eth_abi
    def test_assemble_puts_final_parts_after_the_upgrade(self):
        gov = str(Path(self.tmp.name) / "g.json")
        txs, _ = ab.governance_transactions(1, self.reader(), proxy=self.NAV)
        ab.write_batch(gov, 1, self.COUNCIL, "g", "d", txs)
        empty = str(Path(self.tmp.name) / "e.json")
        ab.write_batch(empty, 1, self.COUNCIL, "e", "d", [])

        class A:
            chain, upgrade_impl, parts, final_parts = 1, "0x" + "92" * 20, [empty], [gov]
            out = str(Path(self.tmp.name) / "out.json")
        ab.cmd_assemble(A)
        out = json.loads(Path(A.out).read_text())["transactions"]
        self.assertEqual([t["data"][:10] for t in out],
                         [ab.SEL_UPGRADE_TO_AND_CALL, ab.SEL_TL_SCHEDULE, ab.SEL_TL_EXECUTE, ab.SEL_RENOUNCE_ROLE,
                          ab.SEL_RENOUNCE_ROLE])


class TimelockFileChecks(unittest.TestCase):
    """timelock_batch_fork_check reads the BTC Carry files; it must refuse one aimed at another contract/function."""
    TL = "0x" + "a4" * 20

    def setUp(self):
        import timelock_batch_fork_check as t
        self.t = t
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def _file(self, name, chain="1", **tx):
        inputs = [{"name": n, "type": ty} for n, ty in (("targets", "address[]"), ("values", "uint256[]"),
                  ("payloads", "bytes[]"), ("predecessor", "bytes32"), ("salt", "bytes32"))]
        base = {"to": self.TL, "value": "0", "operation": 0, "data": None,
                "contractMethod": {"name": "executeBatch", "inputs": inputs},
                "contractInputsValues": {"targets": json.dumps([OTHER]), "values": "[0]", "payloads": '["0x12"]',
                                         "predecessor": "0x" + "00" * 32, "salt": "0x" + "00" * 32}}
        base.update(tx)
        f = Path(self.tmp.name) / name
        f.write_text(json.dumps({"chainId": chain, "transactions": [base]}))
        return str(f)

    def test_refuses_a_file_made_for_another_chain_than_the_fork(self):
        # The Safe UI sends a file to the chain it names: a Base-stamped file must not pass a mainnet rehearsal.
        self.assertEqual(self.t._batch_args(self._file("c1.json"), self.TL, "executeBatch", 1)[1], "[0]")
        with self.assertRaises(self.t.CheckError):
            self.t._batch_args(self._file("c8453.json", chain="8453"), self.TL, "executeBatch", 1)
        with self.assertRaises(self.t.CheckError):  # no chainId at all: refused, never treated as a match
            self.t._batch_args(self._file("nochain.json", chain=None), self.TL, "executeBatch", 1)

    def test_accepts_the_right_target_and_method(self):
        self.assertEqual(self.t._batch_args(self._file("ok.json"), self.TL.upper().replace("0X", "0x"), "executeBatch", 1)[1],
                         "[0]")

    def test_refuses_another_target_method_value_or_count(self):
        bad = [self._file("to.json", to="0x" + "bb" * 20),
               self._file("m.json", contractMethod={"name": "scheduleBatch"}),
               self._file("v.json", value="1"),
               self._file("op.json", operation=1),
               self._file("data.json", data="0x1234"),
               self._file("data0x.json", data="0x"),
               self._file("dataempty.json", data=""),
               self._file("types.json", contractMethod={"name": "executeBatch", "inputs": [
                   {"name": "targets", "type": "address[]"}, {"name": "values", "type": "uint128[]"},
                   {"name": "payloads", "type": "bytes[]"}, {"name": "predecessor", "type": "bytes32"},
                   {"name": "salt", "type": "bytes32"}]})]
        two = Path(self.tmp.name) / "two.json"  # built from a VALID entry, so only the count guard can refuse it
        two.write_text(json.dumps({"transactions": [json.loads(Path(self._file("ok2.json")).read_text())["transactions"][0]] * 2}))
        bad.append(str(two))
        for f in bad:
            with self.assertRaises(self.t.CheckError, msg=f):
                self.t._batch_args(f, self.TL, "executeBatch", 1)


class LoopbackGuard(unittest.TestCase):
    """The fork-only tools must refuse anything but a plain local endpoint: a prefix check passed
    `http://127.0.0.1:1@evil.example/`, which connects to evil.example."""

    def test_accepts_plain_loopback_only(self):
        import chainlib
        for ok in ("http://127.0.0.1:8546", "http://localhost:8545", "http://127.0.0.1:8546/"):
            self.assertTrue(chainlib.is_loopback_rpc(ok), ok)
        for bad in ("http://127.0.0.1:1@evil.example/", "http://user:pw@127.0.0.1:8546", "http://127.0.0.1.evil.example:8546",
                    "https://127.0.0.1:8546", "http://127.0.0.1", "http://localhost:abc", "http://127.0.0.1:8546/x",
                    "http://127.0.0.1:8546?x=1", "http://10.0.0.1:8546", "http://evil.example/127.0.0.1:8546", "", None):
            self.assertFalse(chainlib.is_loopback_rpc(bad), bad)

    def test_fork_executor_refuses_the_bypass(self):
        with self.assertRaises(cfe.CouncilForkError):
            cfe._loopback("http://127.0.0.1:1@evil.example/")

    def test_batch_reader_and_timelock_check_refuse_the_bypass(self):
        class A:
            chain, rpc_url, rpc_env = 1, "http://127.0.0.1:1@evil.example/", None
        with self.assertRaises(ab.BatchError):
            ab._reader(A())
        import os
        import timelock_batch_fork_check as tbf
        old = os.environ.get("ADR0029_FORK_RPC")
        os.environ["ADR0029_FORK_RPC"] = "http://127.0.0.1:1@evil.example/"
        try:
            with self.assertRaises(tbf.CheckError):
                tbf.main(["--timelock", "0x" + "a4" * 20, "--schedule", "x", "--execute", "y"])
        finally:
            if old is None:
                os.environ.pop("ADR0029_FORK_RPC", None)
            else:
                os.environ["ADR0029_FORK_RPC"] = old

    def test_whitespace_query_and_fragment_are_refused(self):
        import chainlib
        for bad in (" http://127.0.0.1:8546", "http://127.0.0.1:8546\n", "http://127.0.0.1\t:8546",
                    "http://127.0.0.1:8546#", "http://127.0.0.1:8546?", 123):
            self.assertFalse(chainlib.is_loopback_rpc(bad), repr(bad))


if __name__ == "__main__":
    unittest.main()
