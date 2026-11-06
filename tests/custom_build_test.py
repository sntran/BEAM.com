"""Tests of the builds of a query of scripts/custom_build.py (the FIFO
beam.com: GET /beam.com?QUERY). Run: python3 -I tests/custom_build_test.py"""

import datetime
import hashlib
import importlib.util
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "custom_build", os.path.join(HERE, "..", "scripts", "custom_build.py"))
cb = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cb)


def url(lines):
    """The URL and the input query of LINES, as the FIFO makes them."""
    return f"q.{cb.query_hash(lines)}", "".join(f"{line}&" for line in lines)


def inputs(lines):
    return cb.url_inputs(*url(lines))


def build_settings(lines):
    u, q = url(lines)
    return cb.settings(cb.dispatch({"INPUT_URL": u, "INPUT_QUERY": q}))


class QueryHash(unittest.TestCase):
    def test_the_hash_of_sort_and_sha256sum(self):
        # The FIFO: printf %s "$query" | sed ... | sort | sha256sum | cut -c1-32
        lines = ["hex: 1", "apps: mnesia", "nifs : vix"]
        text = "".join(f"{line}\n" for line in lines)
        out = subprocess.run(["sh", "-c", "LC_ALL=C sort | sha256sum | cut -c1-32"],
                             input=text, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), cb.query_hash(sorted(lines)))
        self.assertEqual(cb.query_hash(["a: 1"]),
                         hashlib.sha256(b"a: 1\n").hexdigest()[:32])

    def test_a_query_with_another_hash_fails(self):
        _, q = url(["hex: 1"])
        with self.assertRaisesRegex(SystemExit, "hash"):
            cb.url_inputs("q." + "0" * 32, q)

    def test_the_url_names_the_kind(self):
        with self.assertRaisesRegex(SystemExit, "Only a URL q.HASH"):
            cb.url_inputs("plus.vix", "hex: 1&")
        with self.assertRaisesRegex(SystemExit, "1 to 60 fields"):
            cb.url_inputs("q." + "0" * 32, "")


class ShortNames(unittest.TestCase):
    def test_a_field_that_is_not_there_keeps_its_default(self):
        env = inputs(["hex: 1"])
        self.assertEqual(env, dict(cb.URL_DEFAULTS, INPUT_HEX="1"))

    def test_each_short_field(self):
        env = inputs(["apps: mnesia,os_mon", "elixir_version: 1.20.5", "jit: 0",
                      "nifs : vix,rusty_csv", "omit: ssh", "otp_version: 29.1.2",
                      "rebar3: 1", "sqlite: 0", "wasm: 0"])
        self.assertEqual(env["INPUT_APPS"], "mnesia os_mon")
        self.assertEqual((env["INPUT_ELIXIR"], env["INPUT_ELIXIR_VERSION"]), ("", "1.20.5"))
        self.assertEqual(env["INPUT_JIT"], "0")
        self.assertEqual(env["INPUT_NIFS"], "vix rusty_csv")
        self.assertEqual(env["INPUT_KEEP"].split(),
                         ["keep"] + [a for a in cb.OMITTABLE if a != "ssh"])
        self.assertEqual(env["INPUT_OTP_VERSION"], "29.1.2")
        self.assertEqual((env["INPUT_REBAR3"], env["INPUT_SQLITE"], env["INPUT_WASM"]),
                         ("1", "0", "0"))

    def test_nifs_plus_and_nifs_only(self):
        self.assertEqual(inputs(["nifs+: vix"])["INPUT_NIFS"], "vix")
        self.assertEqual(inputs(["nifs : vix-gif"])["INPUT_NIFS"], "vix-gif vix")
        self.assertEqual(inputs(["nifs: vix,exqlite"])["INPUT_NIFS"], "default vix exqlite")
        with self.assertRaisesRegex(SystemExit, "not both"):
            inputs(["nifs : vix", "nifs: rusty_csv"])

    def test_no_elixir(self):
        for value in ("", "none"):
            env = build_settings([f"elixir_version: {value}"])
            self.assertEqual((env["ELIXIR"], env["EXTRA_NIFS"]), ("0", ""))

    def test_the_settings_of_a_query(self):
        env = build_settings(["apps: mnesia", "hex: 1", "nifs : vix-svg"])
        self.assertEqual(env["OTP_APPS"], "mnesia")
        self.assertEqual(env["HEX"], "1")
        self.assertEqual((env["EXTRA_NIFS"], env["VIX_PARTS"]), ("vix", "svg"))

    def test_bad_fields(self):
        cases = [
            (["email: jo@example.com"], "Not a field"),
            (["form: "], "Not a field"),
            (["hex: 1", "hex: 0"], "more than one time"),
            (["hex: ;"], "Not a value"),
            (["omit: kernel"], "leave out"),
            (["otp: keep", "omit: ssh"], "no field omit"),
            (["k_ssl: ssh", "otp: keep"], "Not a value of the field k_ssl"),
            (["dnif1: exqlite"], "need dnifs=default"),
        ]
        for lines, message in cases:
            with self.subTest(lines=lines), self.assertRaisesRegex(SystemExit, message):
                inputs(lines)

    def test_a_bad_choice_fails_in_settings(self):
        with self.assertRaisesRegex(SystemExit, "Not a version of OTP"):
            build_settings(["otp_version: 28.0"])
        with self.assertRaisesRegex(SystemExit, "Not names of applications"):
            build_settings(["apps: 9bad"])


class FormNames(unittest.TestCase):
    def test_a_get_of_the_form_gives_the_inputs_of_the_email_path(self):
        # The fields of 1-page.answer.eml, as a browser sends them, and the
        # inputs that 4-start.github.eml would send for them.
        lines = ["apps: ", "a_mnesia: mnesia", "a_os_mon: ", "dnifs: default",
                 "dnif1: exqlite", "dnif2: ", "dnif3: argon2_elixir", "elixir_version: 1.20.4",
                 "hex: 0", "jit: 1", "k_asn1: asn1", "k_ssl: ", "k_public_key: public_key",
                 "nif2: vix", "nif5: vix-icc", "otp: keep", "otp_version: 29.1.1",
                 "rebar3: 0", "sqlite: 1", "wasm: 1"]
        env = inputs(sorted(lines))
        self.assertEqual(env["INPUT_APPS"], "mnesia")
        self.assertEqual(env["INPUT_KEEP"], "keep asn1 public_key")
        self.assertEqual(env["INPUT_NIFS"], "default exqlite argon2_elixir vix vix-icc")
        self.assertEqual((env["INPUT_ELIXIR"], env["INPUT_ELIXIR_VERSION"]), ("", "1.20.4"))
        settings = build_settings(sorted(lines))
        self.assertEqual(settings["NIFS_OMIT"], "bcrypt_elixir")
        self.assertEqual(settings["OTP_OMIT"],
                         " ".join(a for a in sorted(cb.OMITTABLE) if a not in ("asn1", "public_key")))


class Release(unittest.TestCase):
    def setUp(self):
        self.saved = (cb.upload, cb.asset_name, cb.assets, os.environ.get("GITHUB_OUTPUT"))
        self.uploads = []
        cb.upload = lambda name, data, kind: self.uploads.append((name, data, kind))
        cb.asset_name = lambda: "beam-u.q.0123.com"

    def tearDown(self):
        cb.upload, cb.asset_name, cb.assets, output = self.saved
        if output is None:
            os.environ.pop("GITHUB_OUTPUT", None)
        else:
            os.environ["GITHUB_OUTPUT"] = output

    def test_put_gives_the_sha256_first_and_the_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            file, output = os.path.join(tmp, "beam.com"), os.path.join(tmp, "out")
            with open(file, "wb") as f:
                f.write(b"the file")
            os.environ["GITHUB_OUTPUT"] = output
            cb.put(file)
            digest = hashlib.sha256(b"the file").hexdigest()
            self.assertEqual(self.uploads, [
                ("beam-u.q.0123.com.sha256", f"{digest}  beam-u.q.0123.com\n".encode(), "text/plain"),
                ("beam-u.q.0123.com", b"the file", "application/octet-stream"),
            ])
            with open(output) as f:
                self.assertEqual(f.read(), f"name=beam-u.q.0123.com\nsha256={digest}\n")
            # The line of the .sha256 file passes sha256sum -c.
            check = subprocess.run(["sha256sum", "-c", "-"], cwd=tmp, capture_output=True,
                                   input=self.uploads[0][1].replace(b"beam-u.q.0123.com", b"beam.com"))
            self.assertEqual(check.returncode, 0)

    def test_put_with_no_github_output(self):
        os.environ.pop("GITHUB_OUTPUT", None)
        with tempfile.NamedTemporaryFile() as f:
            cb.put(f.name)
        self.assertEqual([u[0] for u in self.uploads], ["beam-u.q.0123.com.sha256", "beam-u.q.0123.com"])

    def test_today_does_not_count_a_sha256_file(self):
        now = datetime.datetime(2026, 11, 6, 12, tzinfo=datetime.timezone.utc)
        cb.assets = lambda: [
            {"name": "beam-u.q.0123.com", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.0123.com.sha256", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.4567.20261106.txt", "created_at": "2026-11-06T02:00:00Z"},
            {"name": "beam-u.q.89ab.com", "created_at": "2026-11-05T23:00:00Z"},
        ]
        self.assertEqual(cb.today(now), 2)


if __name__ == "__main__":
    unittest.main()
