"""Tests of the builds of a query of scripts/custom_build.py (the FIFO
beam.com: GET /beam.com?QUERY). Run: python3 -I tests/custom_build_test.py"""

import contextlib
import datetime
import hashlib
import io
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
        self.saved = (cb.upload, cb.asset_name, cb.assets, cb.keep, os.environ.get("URL"),
                      os.environ.get("GITHUB_OUTPUT"))
        self.uploads = []
        self.kept = []
        cb.upload = lambda name, data, kind: self.uploads.append((name, data, kind))
        cb.keep = lambda data, digest: self.kept.append((data, digest)) or "https://kept/x"
        cb.asset_name = lambda: "beam-0123456789abcdef.com"
        os.environ.pop("URL", None)

    def tearDown(self):
        cb.upload, cb.asset_name, cb.assets, cb.keep, url, output = self.saved
        if url is not None:
            os.environ["URL"] = url
        if output is None:
            os.environ.pop("GITHUB_OUTPUT", None)
        else:
            os.environ["GITHUB_OUTPUT"] = output

    def test_put_keeps_the_file_then_gives_the_sha256_first_and_the_outputs(self):
        name = "beam-0123456789abcdef.com"
        with tempfile.TemporaryDirectory() as tmp:
            file, output = os.path.join(tmp, "beam.com"), os.path.join(tmp, "out")
            with open(file, "wb") as f:
                f.write(b"the file")
            os.environ["GITHUB_OUTPUT"] = output
            cb.put(file)
            digest = hashlib.sha256(b"the file").hexdigest()
            self.assertEqual(self.kept, [(b"the file", digest)])
            self.assertEqual(self.uploads[:2], [
                (f"{name}.sha256", f"{digest}  {name}\n".encode(), "text/plain"),
                (name, b"the file", "application/octet-stream"),
            ])
            self.assertEqual(self.uploads[2][0::2], (f"{name}.json", "application/json"))
            info = cb.json.loads(self.uploads[2][1])
            self.assertEqual((info["sha256"], info["kept"]), (digest, "https://kept/x"))
            with open(output) as f:
                self.assertEqual(f.read(), f"name={name}\nsha256={digest}\n")
            # The line of the .sha256 file passes sha256sum -c.
            check = subprocess.run(["sha256sum", "-c", "-"], cwd=tmp, capture_output=True,
                                   input=self.uploads[0][1].replace(name.encode(), b"beam.com"))
            self.assertEqual(check.returncode, 0)

    def test_put_with_no_github_output(self):
        os.environ.pop("GITHUB_OUTPUT", None)
        with tempfile.NamedTemporaryFile() as f:
            cb.put(f.name)
        self.assertEqual([u[0] for u in self.uploads], [
            "beam-0123456789abcdef.com.sha256", "beam-0123456789abcdef.com",
            "beam-0123456789abcdef.com.json"])

    def test_today_does_not_count_a_sha256_file(self):
        now = datetime.datetime(2026, 11, 6, 12, tzinfo=datetime.timezone.utc)
        cb.assets = lambda: [
            {"name": "beam-u.q.0123.com", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.0123.com.sha256", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.0123.com.json", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.0123.com.new", "created_at": "2026-11-06T01:00:00Z"},
            {"name": "beam-u.q.4567.20261106.txt", "created_at": "2026-11-06T02:00:00Z"},
            {"name": "beam-u.q.89ab.com", "created_at": "2026-11-05T23:00:00Z"},
        ]
        self.assertEqual(cb.today(now), 2)


def asset(name, number, created="2026-11-06T01:00:00Z"):
    return {"name": name, "id": number, "created_at": created,
            "browser_download_url": f"https://example.invalid/{name}"}


class Saved(unittest.TestCase):
    """Keeps the functions and the variables that a test changes."""
    NAMES = ("upload", "replace", "asset_name", "assets", "release", "github", "facts",
             "today", "source", "url_key", "stale_urls", "keep")
    VARIABLES = ("GITHUB_OUTPUT", "GITHUB_REPOSITORY", "GITHUB_SHA", "URL", "KEY",
                 "INPUT_QUERY", "GITHUB_SERVER_URL")

    def setUp(self):
        self.saved = {n: getattr(cb, n) for n in self.NAMES}
        self.variables = {n: os.environ.get(n) for n in self.VARIABLES}
        os.environ["GITHUB_REPOSITORY"] = "o/r"
        self.out = io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.out))
        self.calls = []
        cb.github = lambda path, method="GET", data=None, content_type=None, base=None: (
            self.calls.append((method, path, data)) or self.answer(method, path))

    def answer(self, method, path):
        return {"id": 99} if method == "POST" else None

    def tearDown(self):
        for n, f in self.saved.items():
            setattr(cb, n, f)
        for n, v in self.variables.items():
            if v is None:
                os.environ.pop(n, None)
            else:
                os.environ[n] = v


class Source(unittest.TestCase):
    def git(self, *args):
        trees = {
            "": "040000 tree aa\tscripts\n040000 tree bb\tdocs\n100644 blob cc\tREADME.md\n"
                "100644 blob dd\tMakefile\n",
            "scripts/": "100644 blob ee\tscripts/steps.sh\n100644 blob ff\tscripts/custom_build.py\n",
        }
        return trees[args[-1] if args[-1] != "commit" else ""]

    def test_custom_build_py_is_not_in_the_source(self):
        self.assertEqual(cb.source("commit", self.git), "ee scripts/steps.sh\ndd Makefile\n")

    def test_no_scripts_is_no_source(self):
        with self.assertRaises(SystemExit):
            cb.source("commit", lambda *args: "100644 blob dd\tMakefile\n")

    def test_the_paths_of_the_workflow_of_the_caches(self):
        """A push starts custom-build-caches.yml when it changes a path of
        source(), or custom_build.py."""
        with open(os.path.join(HERE, "..", ".github", "workflows", "custom-build-caches.yml")) as f:
            text = f.read()
        block = text.split("    paths-ignore:\n", 1)[1].split("  schedule:", 1)[0]
        found = [line.strip()[2:].strip('"') for line in block.splitlines()]
        want = ["*.md"] + [p for n in cb.NOT_SOURCE for p in (n, n + "/**")]
        self.assertEqual(found, want)


class Put(Saved):
    def test_a_url_replaces_its_files_and_puts_its_facts_last(self):
        stored = []
        cb.replace = lambda name, data, kind: stored.append((name, data, kind))
        cb.keep = lambda data, digest: "https://kept/x"
        cb.upload = lambda *args: self.fail("upload for a URL")
        cb.asset_name = lambda: "beam-u.q.0123.com"
        os.environ.update(URL="q.0123", KEY="k" * 64, GITHUB_SHA="c" * 40, INPUT_QUERY="jit: 0&")
        os.environ.pop("GITHUB_OUTPUT", None)
        with tempfile.NamedTemporaryFile() as f:
            cb.put(f.name)
        self.assertEqual([s[0] for s in stored], [
            "beam-u.q.0123.com.sha256", "beam-u.q.0123.com", "beam-u.q.0123.com.json"])
        self.assertEqual(stored[2][2], "application/json")
        self.assertEqual(cb.json.loads(stored[2][1]),
                         {"key": "k" * 64, "commit": "c" * 40, "query": "jit: 0&", "kept": "https://kept/x",
                          "sha256": hashlib.sha256(b"").hexdigest()})


class Replace(Saved):
    def release_with(self, *names):
        cb.release = lambda create=False: {
            "assets": [asset(n, i) for i, n in enumerate(names, 1)],
            "upload_url": "https://uploads.invalid/assets{?name,label}"}

    def test_the_new_file_goes_in_before_the_delete_of_the_old_one(self):
        self.release_with("a.com")
        cb.replace("a.com", b"new", "text/plain")
        self.assertEqual(self.calls, [
            ("POST", "?name=a.com.new", b"new"),
            ("DELETE", "/repos/o/r/releases/assets/1", None),
            ("PATCH", "/repos/o/r/releases/assets/99", b'{"name": "a.com"}'),
        ])

    def test_an_old_new_file_goes_first(self):
        self.release_with("a.com", "a.com.new")
        cb.replace("a.com", b"new", "text/plain")
        self.assertEqual(self.calls[0], ("DELETE", "/repos/o/r/releases/assets/2", None))
        self.assertEqual(len(self.calls), 4)

    def test_no_old_file_is_an_upload(self):
        self.release_with("b.com")
        uploads = []
        cb.upload = lambda *args: uploads.append(args)
        cb.replace("a.com", b"new", "text/plain")
        self.assertEqual((uploads, self.calls), ([("a.com", b"new", "text/plain")], []))


class Facts(Saved):
    def test_the_facts_of_a_file(self):
        read = lambda data: (lambda url: data)
        self.assertEqual(cb.facts(None), {})
        self.assertEqual(cb.facts(asset("a.json", 1), read(b'{"key": "k"}')), {"key": "k"})
        self.assertEqual(cb.facts(asset("a.json", 1), read(b"[1]")), {})
        self.assertEqual(cb.facts(asset("a.json", 1), read(b"{no")), {})
        self.assertEqual(cb.facts(asset("a.json", 1), read(b" " * 65537)), {})

    def test_current(self):
        cb.asset_name = lambda: "beam-u.q.0123.com"
        os.environ["KEY"] = "k1"
        cb.facts = lambda a: {"key": "k1"} if a else {}
        cb.assets = lambda: []
        self.assertFalse(cb.current())
        cb.assets = lambda: [asset("beam-u.q.0123.com", 1)]
        self.assertFalse(cb.current())
        cb.assets = lambda: [asset("beam-u.q.0123.com", 1), asset("beam-u.q.0123.com.json", 2)]
        self.assertTrue(cb.current())
        os.environ["KEY"] = "k2"
        self.assertFalse(cb.current())


Q0, Q4 = "0" * 32, "4" * 32


class Urls(Saved):
    FILES = ["beam-u.plus.vix.com", "beam-u.plus.vix.com.json", f"beam-u.q.{Q0}.com",
             f"beam-u.q.{Q4}.com", f"beam-u.q.{Q4}.com.json", "beam-u.only.zzz.com",
             "beam-u.plus.vix.20261106.txt", "beam-0123456789abcdef.com", "beam-u.only.zzz.com.new"]
    FACTS = {"beam-u.plus.vix.com.json": {"key": "old"},
             f"beam-u.q.{Q4}.com.json": {"key": f"new-q.{Q4}", "query": "jit: 0&"}}

    def setUp(self):
        super().setUp()
        cb.facts = lambda a, read=None: self.FACTS.get(a["name"], {}) if a else {}

        def url_key(url, query, text):
            if url == "only.zzz":
                cb.fail("Not NIFs that a build can use: zzz")
            return f"new-{url}"
        cb.url_key = url_key

    def test_the_stale_urls(self):
        found = [asset(n, i) for i, n in enumerate(self.FILES, 1)]
        self.assertEqual(cb.stale_urls(found, "text"), [("plus.vix", "")])
        self.assertEqual(self.out.getvalue(), (
            f"beam-u.only.zzz.com: no new build (Not NIFs that a build can use: zzz)\n"
            f"beam-u.q.{Q0}.com: no query in beam-u.q.{Q0}.com.json, so no new build\n"))

    def test_a_stale_query(self):
        self.FACTS = dict(self.FACTS, **{f"beam-u.q.{Q4}.com.json": {"key": "x", "query": "jit: 0&"}})
        found = [asset(f"beam-u.q.{Q4}.com", 1), asset(f"beam-u.q.{Q4}.com.json", 2)]
        self.assertEqual(cb.stale_urls(found, "text"), [(f"q.{Q4}", "jit: 0&")])

    def test_the_key_of_a_url(self):
        lines = ["jit: 0"]
        u, q = url(lines)
        env = cb.settings(cb.dispatch({"INPUT_URL": u, "INPUT_QUERY": q}))
        self.assertEqual(self.saved["url_key"](u, q, "text"), cb.key(env, "text"))

    def test_delete_marks(self):
        cb.assets = lambda: [asset(n, i) for i, n in enumerate(self.FILES, 1)]
        cb.delete_marks()
        self.assertEqual(self.calls, [("DELETE", "/repos/o/r/releases/assets/7", None)])

    def test_run_of(self):
        runs = [
            {"display_title": "Rebuild of the URL plus.vix", "created_at": "2026-11-06T01:00:00Z",
             "run_number": 5},
            {"display_title": "Rebuild of the URL plus.vix", "created_at": "2026-11-06T03:00:00Z",
             "run_number": 8},
            {"display_title": "Rebuild of the URL plus.vix", "created_at": "2026-11-06T02:00:00Z",
             "run_number": 7},
            {"display_title": "Custom build of the URL plus.vix",
             "created_at": "2026-11-06T02:00:00Z", "run_number": 6},
        ]
        self.assertEqual(cb.run_of(runs, "Rebuild of the URL plus.vix", "2026-11-06T02:00:00Z")
                         ["run_number"], 7)
        self.assertIsNone(cb.run_of(runs, "Rebuild of the URL q.0", "2026-11-06T00:00:00Z"))


class Rebuild(Saved):
    NOW = datetime.datetime(2026, 11, 6, 12, tzinfo=datetime.timezone.utc)

    def setUp(self):
        super().setUp()
        cb.assets = lambda: []
        cb.source = lambda commit: "text"
        cb.stale_urls = lambda found, text: [("plus.vix", ""), ("q.0123", "jit: 0&")]
        cb.today = lambda: 0
        self.polls = []
        self.time = [0]

    def answer(self, method, path):
        if method != "GET":
            return None
        return {"workflow_runs": self.polls.pop(0) if self.polls else []}

    def rebuild(self):
        def sleep(seconds):
            self.time[0] += seconds
        cb.rebuild_urls("c" * 40, sleep=sleep, clock=lambda: self.time[0], now=lambda: self.NOW)

    def title(self, url, status, conclusion=None):
        return [{"display_title": f"Rebuild of the URL {url}", "created_at": "2026-11-06T12:00:05Z",
                 "run_number": 3, "status": status, "conclusion": conclusion,
                 "html_url": "https://example.invalid/run"}]

    def test_one_build_at_a_time(self):
        self.polls = [[], self.title("plus.vix", "in_progress"),
                      self.title("plus.vix", "completed", "success"),
                      self.title("q.0123", "completed", "success")]
        self.rebuild()
        dispatches = [cb.json.loads(c[2]) for c in self.calls if c[0] == "POST"]
        self.assertEqual(dispatches, [
            {"ref": "main", "inputs": {"url": "plus.vix", "query": "", "rebuild": "1"}},
            {"ref": "main", "inputs": {"url": "q.0123", "query": "jit: 0&", "rebuild": "1"}},
        ])
        self.assertEqual(self.polls, [])
        # The second dispatch comes after the end of the first run.
        methods = [c[0] for c in self.calls]
        self.assertEqual(methods, ["POST", "GET", "GET", "GET", "POST", "GET"])

    def test_the_limit_of_each_day(self):
        cb.today = lambda: cb.REBUILD_DAILY
        self.rebuild()
        self.assertEqual(self.calls, [])
        self.assertIn("the other URLs wait for the next run", self.out.getvalue())

    def test_a_run_that_does_not_show(self):
        self.rebuild()
        self.assertEqual([c[0] for c in self.calls].count("POST"), 2)
        self.assertGreater(self.time[0], 2 * cb.NEW_RUN_SECONDS)

    def test_a_run_that_does_not_end(self):
        self.polls = [self.title("plus.vix", "in_progress")] * 1000
        cb.stale_urls = lambda found, text: [("plus.vix", "")]
        self.rebuild()
        self.assertGreater(self.time[0], cb.REBUILD_SECONDS)
        self.assertLess(self.time[0], cb.REBUILD_SECONDS + 60)


class Keep(Saved):
    def test_keep_puts_the_bytes_in_the_release_of_the_month(self):
        uploads = []
        cb.upload = lambda name, data, kind, tag="": uploads.append((name, data, kind, tag))
        os.environ["GITHUB_SERVER_URL"] = "https://github.com"
        now = datetime.datetime(2026, 11, 8, 3, tzinfo=datetime.timezone.utc)
        url = cb.keep(b"x", "d" * 64, now)
        self.assertEqual(uploads, [(f"beam-{'d' * 64}.com", b"x", "application/octet-stream",
                                    "kept-202611")])
        self.assertEqual(url, f"https://github.com/o/r/releases/download/kept-202611/beam-{'d' * 64}.com")

    def test_a_new_release_of_kept_files(self):
        def answer(method, path):
            if method == "GET":
                raise cb.urllib.error.HTTPError(path, 404, "Not Found", {}, None)
            return {"assets": []}
        self.answer = answer
        cb.release(create=True, tag="kept-202611")
        method, path, data = self.calls[-1]
        body = cb.json.loads(data)
        self.assertEqual((method, path), ("POST", "/repos/o/r/releases"))
        self.assertEqual((body["tag_name"], body["name"], body["prerelease"], body["make_latest"]),
                         ("kept-202611", "Kept custom builds of 2026-11", True, "false"))
        self.assertIn("No job deletes these files", body["body"])

    def test_no_job_deletes_a_kept_file(self):
        """The cleanups read only the release RELEASE."""
        self.assertEqual(cb.release.__defaults__, (False, cb.RELEASE))
        for name in ("custom-build.yml", "custom-build-caches.yml"):
            with open(os.path.join(HERE, "..", ".github", "workflows", name)) as f:
                self.assertNotIn(cb.KEPT, f.read())


if __name__ == "__main__":
    unittest.main()
