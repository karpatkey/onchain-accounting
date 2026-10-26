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


if __name__ == "__main__":
    unittest.main()
