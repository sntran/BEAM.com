#!/usr/bin/env python3
"""The choices of a custom build (.github/workflows/custom-build.yml).

The choices come from the text of an issue of the form "A custom build of
beam.com" (the variable BODY), or from the inputs of workflow_dispatch
(the variables INPUT_*), which the FIFO beam.com of mkfifo.com sends.
Both are input of a user: they only select known values, and the names of
applications must be names of OTP.

Usage:

  custom_build.py issue|dispatch COMMIT
    The settings of the Makefile, OUT_NAME, KEY and REPLY go
    to the file of GITHUB_ENV, and a table to the file of
    GITHUB_STEP_SUMMARY (when these variables are set). KEY is the SHA-256
    of the settings and of the source of the build at COMMIT (source()).
    Two requests with the same choices have the same KEY and the same
    file, also on a later commit that changes only the documents, the
    tests or the workflows.
  custom_build.py versions   The versions that a build can use, as JSON: the
    tables, the defaults, and "pairs", each pair of an OTP version and an
    Elixir version except the pair of the defaults (the matrix of
    custom-build-versions.yml).
  custom_build.py exists     Status 0 when the release has the file of KEY.
  custom_build.py current    Status 0 when the release has the file of a
                             build of a URL, and its NAME.json names KEY.
  custom_build.py today      The number of new builds of the release of today
                             (UTC): no .sha256, .json or .new file.
  custom_build.py put FILE   Puts FILE in the release of kept files of the
    month, as beam-SHA256.com (keep()). Then it puts FILE in the release,
    as asset_name(), with NAME.sha256 before it (the line of sha256sum),
    and NAME.json after it, with KEY, the query, the SHA-256 and the kept
    URL. For a build of a URL, the new files replace the old ones. With
    GITHUB_OUTPUT, it writes name= and sha256= for the job that attests
    the file.
  custom_build.py cleanup    Deletes the files that are older than 30 days.
  custom_build.py queue      Waits for the turn of this run (see queue()).
  custom_build.py notify STATUS [REASON]
    Sends the result to the FIFO beam.com: ready, failed or refused.
  custom_build.py mark REASON
    For a build of a URL (the input url): puts a text with the reason in
    the release, so the FIFO stops its waits for the day (url_mark()).
  custom_build.py rebuild-urls COMMIT
    For each file of a build of a URL whose KEY at COMMIT is not the KEY
    of its NAME.json: starts a new build of the URL, and waits for its
    end. The old file stays until the new one replaces it
    (rebuild_urls()).
  custom_build.py delete-marks
    Deletes each mark of a build of a URL (url_mark()): after a push, a
    build that did not run can run again.

The files are the assets of the prerelease RELEASE of the repository: a
person with no GitHub account can download them. The requests to GitHub
use GH_TOKEN (the token of the workflow). The FIFO: BEAM_FIFO_URL and
BEAM_FIFO_SECRET.
"""

import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# The limits of the builds of beam.com: one build at a time, at most
# QUEUE runs that wait, and at most DAILY new builds each day (UTC).
QUEUE = 3
DAILY = 10
WAIT_SECONDS = 180 * 60
# A new build of the URLs after a change of the source starts only while
# the release has fewer than REBUILD_DAILY new builds of today. Thus the
# requests of people always have DAILY - REBUILD_DAILY new builds or more.
REBUILD_DAILY = 5
# The wait of rebuild_urls() for one build: the queue and the timeout of
# the job build of custom-build.yml. NEW_RUN_SECONDS is the wait for the
# run of a dispatch to show in the list of the runs.
REBUILD_SECONDS = 250 * 60
NEW_RUN_SECONDS = 10 * 60
# The files next to the file of a build: its SHA-256, the facts of a
# build of a URL, and a file that is not in its place yet (replace()).
SIDE_FILES = (".sha256", ".json", ".new")
# The prerelease of the files. The check of the newest release of BEAM.com
# takes only the tags v0.1.0 and later, as the prerelease edge.
RELEASE = "custom-builds"
# The prereleases of the kept files: each new build also goes to the
# prerelease of its month (UTC), kept-YYYYMM, as beam-SHA256.com. No job
# deletes them, so a lock that names the bytes always finds them. One
# release for each month: GitHub permits 1,000 files in one release, and
# a month has at most 31 * DAILY new builds.
KEPT = "kept-"

NIFS = ("picosat_elixir", "vix", "rusty_csv", "ex_pdfium")
# The NIFs of the default build (with Elixir; exqlite also needs SQLite),
# which a build can leave out (NIFS_OMIT of scripts/steps.sh). The form
# sends the word "default" and the names of the default NIFs to keep.
DEFAULT_NIFS = ("exqlite", "bcrypt_elixir", "argon2_elixir")
# The parts of the libvips of vix (VIX_PARTS of scripts/steps.sh), as
# words of the NIFs. Each one also selects vix.
VIX_PARTS = {"vix-icc": "icc", "vix-gif": "gif", "vix-avif": "avif", "vix-svg": "svg"}
# The versions of Erlang/OTP and Elixir that a build can use, with the
# commit of each tag (a tag can move). The patches of patches/otp and
# patches/elixir apply to each. The workflow custom-build-versions.yml
# builds and tests each pair. The default versions are the versions of
# scripts/steps.sh (defaults()), and they must be in these tables.
OTP_VERSIONS = {
    "29.1.2": "d199a49a01a2079afb6f2c5c9ae047cd4555e68d",
    "29.1.1": "ad05823719d77c8faee87348ea39513d4e2f99c5",
    "29.0.6": "e07fd07837e5aa845657f5fa340637121e451d47",
}
# Elixir 1.19 does not support OTP 29.
ELIXIR_VERSIONS = {
    "1.20.5": "4a28692668bef879029291b7ff329a84a1f933bb",
    "1.20.4": "759443e724f55bf58e71c0603644e99058918d52",
}
# The paths of the repository that do not change the file of a build:
# the documents, the tests, the workflows, the Mix project of the tests,
# and the envelopes of the FIFO. A change of another path makes a new
# KEY. The paths-ignore of custom-build-caches.yml has the same paths,
# except this file.
NOT_SOURCE = (".github", ".formatter.exs", ".gitignore", "docs", "examples", "js", "lib",
              "mix.exs", "mix.lock", "package.json", "priv/seeds", "specs", "tests")
# This file only makes the settings of a build, and KEY has the settings.
# So a change of this file that does not change the settings keeps KEY,
# and keeps each file of a build of a URL.
NOT_SOURCE_FILES = ("scripts/custom_build.py",)
# The default OTP applications that a build can leave out (OTP_OMIT of
# scripts/steps.sh), and the applications that need them. The other
# default applications (kernel, stdlib, sasl, compiler and crypto) are
# for beam.com itself.
OMITTABLE = ("parsetools", "asn1", "public_key", "ssl", "inets", "ssh", "xmerl",
             "runtime_tools", "tools")
NEEDS = {
    "public_key": ("asn1",),
    "ssl": ("public_key",),
    "ssh": ("public_key",),
    "eldap": ("asn1",),
    "edoc": ("syntax_tools",),
    # Hex and rebar3 download packages with httpc and TLS.
    "hex": ("inets", "ssl"),
    "rebar3": ("inets", "ssl"),
}
APP = re.compile(r"[a-z][a-z0-9_]{0,63}")
FLAGS = ("hex", "rebar3", "elixir", "jit", "sqlite", "wasm")
# The encrypted address of the requester: Base64 of a secretbox of
# mkfifo.com (24 bytes of nonce, 16 of tag, and the address).
REPLY = re.compile(r"[A-Za-z0-9+/]{4,684}={0,2}")
# A build of a URL (the input url, from the FIFO beam.com): "plus" (the
# default NIFs and these NIFs) or "only" (only these NIFs), then the
# names of the NIFs in the sequence of sort, each one after a ".".
# The file is beam-u.URL.com, so the FIFO knows its name from the URL
# alone. A build of a URL has the defaults of the form for each other
# choice, and no email.
#
# A build of a query has the URL "q." and 32 hexadecimal characters: the
# start of the SHA-256 of the lines of the query (the input query), as
# the FIFO gives them (query_inputs()).
URL = re.compile(r"(plus|only)((?:\.[a-z0-9_-]{1,32}){1,16})|q\.([0-9a-f]{32})")
URL_PREFIX = "beam-u."
# The query of a build: the fields of the query of GET /beam.com, one
# "NAME: VALUE" for each field, with "&" after each one. The short names
# are for a person or a script; the other names are the fields of the
# form of the FIFO, so a GET of the form is also a query. The FIFO drops
# the fields email and website, and sorts the lines.
QUERY_SHORT = ("otp_version", "elixir_version", "apps", "omit", "hex", "rebar3", "jit",
               "sqlite", "wasm", "nifs", "nifs ", "nifs+")
QUERY_FORM = re.compile(r"otp|dnifs|dnif[1-3]|nif[1-8]|k_[a-z0-9_]{1,64}|a_[a-z0-9_]{1,64}")
QUERY_VALUE = re.compile(r"[a-z0-9_.,+ -]{0,200}")
QUERY_LINES = 60


def fail(message):
    raise SystemExit(message)


def issue(body):
    sections = {}
    for part in re.split(r"^### ", body, flags=re.M)[1:]:
        title, _, text = part.partition("\n")
        sections[title.strip()] = text.strip()

    def checked(title):
        return re.findall(r"^- \[[xX]\] (.+)$", sections.get(title, ""), flags=re.M)

    def choice(title, default):
        text = sections.get(title, "").strip()
        return default if text in ("", "_No response_") else text

    apps = [a.strip() for a in checked("More OTP applications")]
    apps += choice("Other OTP applications", "").split()
    tools = checked("Tools")
    return {
        "apps": apps,
        "omit": [a.split()[0] for a in checked("Leave out default OTP applications")],
        "nifs": [n.split()[0] for n in checked("More NIFs")],
        "nifs_omit": [n.split()[0] for n in checked("Leave out default NIFs")],
        "hex": any(t.startswith("Hex") for t in tools),
        "rebar3": any(t.startswith("rebar3") for t in tools),
        # "None" in the dropdown Elixir version, or "No" in the dropdown
        # Elixir of an older form.
        "elixir": choice("Elixir", "Yes") != "No"
                  and not choice("Elixir version", "").startswith("None"),
        "jit": not choice("Emulator", "").startswith("Interpreter"),
        "sqlite": choice("SQLite", "Yes") != "No",
        "wasm": choice("WebAssembly (WAMR)", "Yes") != "No",
        # "29.1.1 (default)": the first word.
        "otp_version": choice("Erlang/OTP version", "").split()[:1],
        "elixir_version": [] if choice("Elixir version", "").startswith("None")
                          else choice("Elixir version", "").split()[:1],
        "reply": "",
    }


# The inputs of a build of a URL or a query, before its choices: the
# defaults of the form, and no email.
URL_DEFAULTS = {
    "INPUT_APPS": "", "INPUT_KEEP": "", "INPUT_HEX": "0", "INPUT_REBAR3": "0",
    "INPUT_ELIXIR": "1", "INPUT_JIT": "1", "INPUT_SQLITE": "1", "INPUT_WASM": "1",
    "INPUT_NIFS": "", "INPUT_OTP_VERSION": "", "INPUT_ELIXIR_VERSION": "",
    "INPUT_REPLY": "",
}


def query_hash(lines):
    """The name of a query in its URL: the first 32 characters of the
    SHA-256 of its lines, each one with a line break after it, in the
    sequence of the FIFO."""
    text = "".join(f"{line}\n" for line in lines)
    return hashlib.sha256(text.encode()).hexdigest()[:32]


def query_inputs(digest, query):
    """The inputs of workflow_dispatch of the build of a query (the input
    query, with the hash DIGEST of its URL): the defaults of the form, and
    the fields of the query. A field that is not there keeps its default."""
    lines = [line for line in query.split("&") if line]
    if not lines or len(lines) > QUERY_LINES:
        fail(f"A query has 1 to {QUERY_LINES} fields")
    if query_hash(lines) != digest:
        fail("The query does not have the hash of its URL")
    fields = []
    for line in lines:
        name, sep, value = line.partition(":")
        value = value[1:] if value.startswith(" ") else value
        if not sep or not (name in QUERY_SHORT or QUERY_FORM.fullmatch(name)):
            fail(f"Not a field of a query: {name[:40]!r}")
        if not QUERY_VALUE.fullmatch(value):
            fail(f"Not a value of the field {name}")
        fields.append((name, value.strip()))

    def values(name):
        return [v for n, v in fields if n == name]

    def one(name):
        found = values(name)
        if len(found) > 1:
            fail(f"The field {name} is in the query more than one time")
        return found[0] if found else None

    def words(*names):
        return " ".join(v for name in names for v in values(name)).replace(",", " ").split()

    def checks(prefix, allowed=None):
        """The values of the check boxes PREFIX_NAME of the form: each
        one is NAME, or empty."""
        out = []
        for name, value in fields:
            if name.startswith(prefix) and value:
                if value != name[len(prefix):] or (allowed is not None and value not in allowed):
                    fail(f"Not a value of the field {name}")
                out.append(value)
        return out

    env = dict(URL_DEFAULTS)
    for flag in ("hex", "rebar3", "jit", "sqlite", "wasm"):
        value = one(flag)
        if value is not None:
            env["INPUT_" + flag.upper()] = value
    otp = one("otp_version")
    if otp:
        env["INPUT_OTP_VERSION"] = otp
    # As in the form: an empty elixir_version (or "none") is no Elixir.
    elixir = one("elixir_version")
    if elixir is not None:
        env["INPUT_ELIXIR"] = ""
        env["INPUT_ELIXIR_VERSION"] = "" if elixir == "none" else elixir
    env["INPUT_APPS"] = " ".join(words("apps") + checks("a_"))
    # The default applications: "otp=keep" and the check boxes k_NAME of
    # the form, or the short field omit.
    omit = words("omit")
    if one("otp") is not None:
        if one("otp") != "keep" or omit:
            fail("The field otp is keep, with the fields k_NAME, and no field omit")
        env["INPUT_KEEP"] = " ".join(["keep"] + checks("k_", OMITTABLE))
    elif omit:
        bad = [a for a in omit if a not in OMITTABLE]
        if bad:
            fail(f"Not default applications that a build can leave out: {', '.join(bad)}")
        env["INPUT_KEEP"] = " ".join(["keep"] + [a for a in OMITTABLE if a not in omit])
    # The NIFs: nifs= gives only these, and nifs+= adds them to the default
    # NIFs. The form sends dnifs=default, the default NIFs to keep, and
    # the others.
    only, plus = words("nifs"), words("nifs ", "nifs+")
    chosen = [v for n, v in fields if re.fullmatch(r"nif[1-8]", n) and v]
    kept = [v for n, v in fields if re.fullmatch(r"dnif[1-3]", n) and v]
    if only and plus:
        fail("A query has nifs= or nifs+=, not both")
    # In the short fields, a part of vix also chooses vix, as in an issue.
    # The form hides the parts when vix is off, so its fields do not.
    for short in (only, plus):
        if "vix" not in short and any(n in VIX_PARTS for n in short):
            short.append("vix")
    if one("dnifs") is not None:
        if one("dnifs") != "default":
            fail("Not a value of the field dnifs")
        env["INPUT_NIFS"] = " ".join(["default"] + kept + chosen + only + plus)
    elif kept:
        fail("The fields dnif1 to dnif3 need dnifs=default")
    elif only:
        env["INPUT_NIFS"] = " ".join(["default"] + only + chosen)
    else:
        env["INPUT_NIFS"] = " ".join(plus + chosen)
    return env


def url_inputs(url, query=""):
    """The inputs of workflow_dispatch of the build of URL: the defaults
    of the form, and the NIFs of URL, or the fields of QUERY."""
    found = URL.fullmatch(url)
    if not found:
        fail(f"Not the choices of a URL: {url[:100]!r}")
    if found.group(3):
        return query_inputs(found.group(3), query)
    if query:
        fail("Only a URL q.HASH has a query")
    names = found.group(2)[1:].split(".")
    if names != sorted(set(names)):
        fail("The names of the NIFs of a URL must be in the sequence of sort, each one time")
    known = set(NIFS) | set(DEFAULT_NIFS) | set(VIX_PARTS)
    bad = [n for n in names if n not in known]
    if bad:
        fail(f"Not NIFs that a build can use: {', '.join(bad)}")
    # The form drops a part of vix without vix. A URL names its file, so
    # the build refuses it.
    if "vix" not in names and any(n in VIX_PARTS for n in names):
        fail("A part of vix needs vix")
    words = (["default"] if found.group(1) == "only" else []) + names
    return dict(URL_DEFAULTS, INPUT_NIFS=" ".join(words))


def dispatch(env):
    # A build of a URL: its inputs come only from the URL.
    if env.get("INPUT_URL", ""):
        env = dict(env, **url_inputs(env["INPUT_URL"], env.get("INPUT_QUERY", "")))

    def flag(name):
        value = env.get("INPUT_" + name.upper(), "")
        if value not in ("0", "1"):
            fail(f"The input {name} must be 0 or 1, not {value!r}")
        return value == "1"

    reply = env.get("INPUT_REPLY", "")
    if reply and not REPLY.fullmatch(reply):
        fail("The input reply is not an encrypted address")
    choices = {name: flag(name) for name in FLAGS if name != "elixir"}
    # Elixir: 0 or 1 from an older form. The form of now has one list,
    # elixir_version, with an empty value for no Elixir, and sends elixir
    # empty.
    if env.get("INPUT_ELIXIR", "") == "":
        choices["elixir"] = env.get("INPUT_ELIXIR_VERSION", "").strip() != ""
    else:
        choices["elixir"] = flag("elixir")
    choices["apps"] = env.get("INPUT_APPS", "").replace(",", " ").split()
    choices["omit"] = omitted(env.get("INPUT_KEEP", ""))
    words = env.get("INPUT_NIFS", "").replace(",", " ").split()
    # "default" and the default NIFs to keep; without the word (an older
    # form), the build keeps each one.
    if "default" in words:
        choices["nifs_omit"] = [n for n in DEFAULT_NIFS if n not in words]
    else:
        choices["nifs_omit"] = []
    choices["nifs"] = [w for w in words if w != "default" and w not in DEFAULT_NIFS]
    choices["otp_version"] = env.get("INPUT_OTP_VERSION", "").split()
    choices["elixir_version"] = env.get("INPUT_ELIXIR_VERSION", "").split()
    choices["reply"] = reply
    # Without Elixir, the form of mkfifo.com hides Hex and the NIFs (a rule
    # of CSS), but their fields still send their values. So the build
    # ignores them. An issue shows each choice, and settings() refuses.
    if not choices["elixir"]:
        choices["hex"] = False
        choices["nifs"] = []
    # In the same way, the form hides the parts of vix without vix. In an
    # issue, a part also selects vix (settings()).
    if "vix" not in choices["nifs"]:
        choices["nifs"] = [n for n in choices["nifs"] if n not in VIX_PARTS]
    return choices


def omitted(keep):
    """The default applications to leave out, from the input keep of the
    form: "keep" and the names of the default applications to keep. An
    empty input keeps each one (an older form)."""
    words = keep.replace(",", " ").split()
    if not words:
        return []
    if words[0] != "keep":
        fail("The input keep must start with the word keep")
    bad = [w for w in words[1:] if w not in OMITTABLE]
    if bad:
        fail(f"Not default applications that a build can leave out: {', '.join(bad)}")
    return [a for a in OMITTABLE if a not in words[1:]]


def needed(names):
    """The names, with the applications that they need (NEEDS), again
    and again."""
    out = set(names)
    todo = list(names)
    while todo:
        for need in NEEDS.get(todo.pop(), ()):
            if need not in out:
                out.add(need)
                todo.append(need)
    return out


def defaults(root=None):
    """The default versions of scripts/steps.sh: {"OTP_VERSION": ...,
    "OTP_COMMIT": ..., "ELIXIR_VERSION": ..., "ELIXIR_COMMIT": ...}. Each
    must be in OTP_VERSIONS or ELIXIR_VERSIONS, with the same commit."""
    root = root or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    with open(os.path.join(root, "scripts", "steps.sh")) as f:
        text = f.read()
    out = {}
    for name in ("OTP_VERSION", "OTP_COMMIT", "ELIXIR_VERSION", "ELIXIR_COMMIT"):
        found = re.search(rf"^{name}=\${{{name}:-([0-9a-f.]+)}}$", text, flags=re.M)
        if not found:
            fail(f"No default {name} in scripts/steps.sh")
        out[name] = found.group(1)
    for kind, table in (("OTP", OTP_VERSIONS), ("ELIXIR", ELIXIR_VERSIONS)):
        if table.get(out[f"{kind}_VERSION"]) != out[f"{kind}_COMMIT"]:
            fail(f"The default {kind}_VERSION of scripts/steps.sh is not in the table, "
                 "or has another commit")
    return out


def version(words, table, default, name):
    """The version of WORDS (no word: DEFAULT), when TABLE has it."""
    if not words:
        return default
    if len(words) > 1 or words[0] not in table:
        fail(f"Not a version of {name} that a build can use: {' '.join(words)[:20]}. "
             f"The versions: {', '.join(table)}")
    return words[0]


def settings(choices, default=None):
    # An application that a chosen application needs, and that is not a
    # default application, goes in too (syntax_tools for edoc).
    apps = sorted(needed(choices["apps"]) - set(OMITTABLE))
    bad = [a for a in apps if not APP.fullmatch(a)]
    if bad:
        fail(f"Not names of applications: {', '.join(bad)}")
    if len(apps) > 40:
        fail("More than 40 applications")
    words = set(choices["nifs"])
    bad = sorted(n for n in words if n not in NIFS and n not in VIX_PARTS)
    if bad:
        fail(f"Not NIFs of the list: {', '.join(bad)}")
    nifs_omit = set(choices.get("nifs_omit", []))
    bad = sorted(n for n in nifs_omit if n not in DEFAULT_NIFS)
    if bad:
        fail(f"Not default NIFs: {', '.join(bad)}")
    # Only the default NIFs that the build would link: none without
    # Elixir, and exqlite only with SQLite.
    if not choices["elixir"]:
        nifs_omit = set()
    if not choices["sqlite"]:
        nifs_omit.discard("exqlite")
    parts = sorted(VIX_PARTS[n] for n in words if n in VIX_PARTS)
    nifs = sorted({n for n in words if n in NIFS} | ({"vix"} if parts else set()))
    if choices["hex"] and not choices["elixir"]:
        fail("Hex needs Elixir")
    if nifs and not choices["elixir"]:
        fail("The NIFs of hex.pm packages need Elixir")
    omit = sorted(set(choices.get("omit", [])))
    bad = [a for a in omit if a not in OMITTABLE]
    if bad:
        fail(f"Not default applications that a build can leave out: {', '.join(bad)}")
    both = [a for a in omit if a in choices["apps"]]
    if both:
        fail(f"Applications to add and to leave out: {', '.join(both)}")
    users = [a for a in OMITTABLE if a not in omit] + apps
    users += [t for t in ("hex", "rebar3") if choices[t]]
    for user in users:
        missing = sorted((needed([user]) - {user}) & set(omit))
        if missing:
            names = ", ".join(missing)
            other = {"hex": "choose No for Hex", "rebar3": "choose No for rebar3"}
            fail(f"{user} needs {names}. Keep {names}, or {other.get(user, 'leave out ' + user)}.")
    default = default or defaults()
    otp = version(choices.get("otp_version", []), OTP_VERSIONS, default["OTP_VERSION"], "OTP")
    elixir = version(choices.get("elixir_version", []), ELIXIR_VERSIONS,
                     default["ELIXIR_VERSION"], "Elixir")
    # Without Elixir, the version of Elixir changes nothing (the form has
    # no script that turns off its list). The default keeps one KEY.
    if not choices["elixir"]:
        elixir = default["ELIXIR_VERSION"]
    one = lambda b: "1" if b else "0"
    env = {
        "OTP_VERSION": otp,
        "OTP_COMMIT": OTP_VERSIONS[otp],
        "ELIXIR_VERSION": elixir,
        "ELIXIR_COMMIT": ELIXIR_VERSIONS[elixir],
        "OTP_APPS": " ".join(apps),
        "OTP_OMIT": " ".join(omit),
        "HEX": one(choices["hex"]),
        "REBAR3": one(choices["rebar3"]),
        "ELIXIR": one(choices["elixir"]),
        "JIT": one(choices["jit"]),
        "SQLITE": one(choices["sqlite"]),
        "WASM": one(choices["wasm"]),
        "EXTRA_NIFS": " ".join(nifs),
    }
    # Only with a part: the KEY of a build with no part stays the same.
    if parts:
        env["VIX_PARTS"] = " ".join(parts)
    # The same for the default NIFs.
    if nifs_omit:
        env["NIFS_OMIT"] = " ".join(n for n in DEFAULT_NIFS if n in nifs_omit)
    env["OUT_NAME"] = "beam.com" if env["JIT"] == "1" else "beam-emu.com"
    return env


def source(commit, git=None):
    """The source of the build at COMMIT: the git object of each path
    that is not in NOT_SOURCE (and not a Markdown file at the top), one
    line for each path. A folder with a path of NOT_SOURCE in it gives its
    entries."""
    git = git or (lambda *args: subprocess.run(
        ("git",) + args, check=True, capture_output=True, text=True).stdout)

    def walk(folder):
        listing = git("ls-tree", commit, "--", folder + "/") if folder else git("ls-tree", commit)
        for line in listing.splitlines():
            meta, _, name = line.partition("\t")
            if (name in NOT_SOURCE or name in NOT_SOURCE_FILES
                    or ("/" not in name and name.endswith(".md"))):
                continue
            if any(n.startswith(name + "/") for n in NOT_SOURCE + NOT_SOURCE_FILES):
                yield from walk(name)
            else:
                yield f"{meta.split()[2]} {name}"

    lines = list(walk(""))
    if not any(line.endswith(" scripts") or " scripts/" in line for line in lines):
        fail(f"No source at the commit {commit}")
    return "".join(f"{line}\n" for line in lines)


def key(env, source_text):
    text = "".join(f"{k}={env[k]}\n" for k in sorted(env)) + source_text
    return hashlib.sha256(text.encode()).hexdigest()


def github(path, method="GET", data=None, content_type=None, base=None):
    """A request to the API of GitHub with GH_TOKEN (the token of the
    workflow). Gives the decoded JSON, or None for an empty answer."""
    url = (base or os.environ.get("GITHUB_API_URL", "https://api.github.com")) + path
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(request, timeout=600) as response:
        body = response.read()
        return json.loads(body) if body else None


def asset_name():
    """The name of the file in the release: beam-KEY16.com or
    beam-emu-KEY16.com, with the first 16 characters of KEY. The file of
    a build of a URL is beam-u.URL.com."""
    url = os.environ.get("URL", "")
    if url:
        if not URL.fullmatch(url):
            fail("Not the choices of a URL")
        return f"{URL_PREFIX}{url}.com"
    if not re.fullmatch(r"[0-9a-f]{64}", os.environ.get("KEY", "")):
        fail("No KEY")
    stem = {"beam.com": "beam", "beam-emu.com": "beam-emu"}.get(os.environ.get("OUT_NAME"))
    if not stem:
        fail("No OUT_NAME")
    return f"{stem}-{os.environ['KEY'][:16]}.com"


def release(create=False, tag=RELEASE):
    """The prerelease TAG (RELEASE, or a release of kept files), or None.
    With create, a new one when it is not there."""
    repo = os.environ["GITHUB_REPOSITORY"]
    try:
        return github(f"/repos/{repo}/releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    if not create:
        return None
    if tag == RELEASE:
        name = "Custom builds"
        text = ("The files of the custom builds of the FIFO beam.com of mkfifo.com "
                "(docs/BUILDING.md). Each file is beam-KEY.com, beam-emu-KEY.com or "
                "beam-u.URL.com, and goes away after 30 days. This is not a release of "
                "BEAM.com.")
    else:
        name = f"Kept custom builds of {tag[len(KEPT):len(KEPT) + 4]}-{tag[len(KEPT) + 4:]}"
        text = ("Each new custom build of this month (UTC), as beam-SHA256.com: SHA256 is "
                "the SHA-256 of the file. No job deletes these files, so a lock can name "
                "them (docs/BUILDING.md, \"A fixed version of a build\"). This is not a "
                "release of BEAM.com.")
    body = {
        "tag_name": tag,
        "target_commitish": os.environ.get("GITHUB_SHA", "main"),
        "name": name,
        "prerelease": True,
        "make_latest": "false",
        "body": text,
    }
    return github(
        f"/repos/{repo}/releases", "POST", json.dumps(body).encode(), "application/json"
    )


def assets():
    found = release()
    return found["assets"] if found else []


def exists():
    return any(a["name"] == asset_name() for a in assets())


def today(now=None):
    """The files that the release got today (UTC): the new builds."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    day = now.strftime("%Y-%m-%d")
    return sum(1 for a in assets()
               if a["created_at"].startswith(day) and not a["name"].endswith(SIDE_FILES))


def cleanup(now=None, days=30):
    """Deletes the files of the release that are older than DAYS days."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    repo = os.environ["GITHUB_REPOSITORY"]
    for a in assets():
        made = datetime.datetime.fromisoformat(a["created_at"].replace("Z", "+00:00"))
        if now - made > datetime.timedelta(days=days):
            github(f"/repos/{repo}/releases/assets/{a['id']}", "DELETE")
            print(f"deleted {a['name']}")


def keep(data, digest, now=None):
    """Puts DATA in the release of kept files of this month, as
    beam-DIGEST.com, when no file has that name. Gives its URL."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    tag = KEPT + now.strftime("%Y%m")
    name = f"beam-{digest}.com"
    upload(name, data, "application/octet-stream", tag=tag)
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    return f"{server}/{os.environ['GITHUB_REPOSITORY']}/releases/download/{tag}/{name}"


def put(file):
    """Puts FILE in the release with the name of asset_name(), and its
    SHA-256 first, as NAME.sha256 in the format of sha256sum. Thus a
    person can check the file, and see a new build after the cleanup.
    The name and the hash also go to GITHUB_OUTPUT, for the job that
    attests the file (custom-build.yml).

    The same bytes go first to the release of kept files (keep()), with a
    name that never changes. NAME.json names that URL.

    The file of a build of a URL replaces the old file of the URL, after
    a change of the source (rebuild_urls()). NAME.json comes last, with
    KEY, the commit, the query, the SHA-256 and the kept URL: a build that
    stops before it has the old KEY, so the next rebuild_urls() builds the
    URL again."""
    name = asset_name()
    with open(file, "rb") as f:
        data = f.read()
    digest = hashlib.sha256(data).hexdigest()
    kept = keep(data, digest)
    store = replace if os.environ.get("URL") else upload
    store(name + ".sha256", f"{digest}  {name}\n".encode(), "text/plain")
    store(name, data, "application/octet-stream")
    info = {"key": os.environ.get("KEY", ""), "commit": os.environ.get("GITHUB_SHA", ""),
            "query": os.environ.get("INPUT_QUERY", ""), "sha256": digest, "kept": kept}
    store(name + ".json", json.dumps(info, sort_keys=True).encode() + b"\n",
          "application/json")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as f:
            f.write(f"name={name}\nsha256={digest}\n")


def upload(name, data, content_type, tag=RELEASE):
    """Puts DATA in the release TAG as NAME, when no file has that name."""
    found = release(create=True, tag=tag)
    for a in found["assets"]:
        if a["name"] == name:
            return
    base = found["upload_url"].split("{", 1)[0]
    github("?name=" + urllib.parse.quote(name), "POST", data, content_type, base=base)


def replace(name, data, content_type):
    """Puts DATA in the release as NAME, in place of the file with that
    name. The new file goes in as NAME.new, and gets the name NAME after
    the delete of the old file. Thus the old file stays until the new file
    is in the release, and a request finds no file only for a moment."""
    found = release(create=True)
    by_name = {a["name"]: a for a in found["assets"]}
    if name not in by_name:
        upload(name, data, content_type)
        return
    repo = os.environ["GITHUB_REPOSITORY"]
    if name + ".new" in by_name:
        github(f"/repos/{repo}/releases/assets/{by_name[name + '.new']['id']}", "DELETE")
    base = found["upload_url"].split("{", 1)[0]
    new = github("?name=" + urllib.parse.quote(name + ".new"), "POST", data, content_type,
                 base=base)
    github(f"/repos/{repo}/releases/assets/{by_name[name]['id']}", "DELETE")
    github(f"/repos/{repo}/releases/assets/{new['id']}", "PATCH",
           json.dumps({"name": name}).encode(), "application/json")


def facts(asset, read=None):
    """The decoded NAME.json of ASSET (None: no file), or {} when it is
    not a JSON object. The release is public, so the request has no
    token: a redirect does not take the token to another host."""
    if not asset:
        return {}
    read = read or (lambda url: urllib.request.urlopen(url, timeout=60).read(65537))
    data = read(asset["browser_download_url"])
    try:
        found = json.loads(data) if len(data) <= 65536 else None
    except ValueError:
        found = None
    return found if isinstance(found, dict) else {}


def current():
    """True when the release has the file of asset_name(), and its
    NAME.json names KEY: the file of a build of a URL is of the source
    of now."""
    name = asset_name()
    by_name = {a["name"]: a for a in assets()}
    if name not in by_name:
        return False
    return facts(by_name.get(name + ".json")).get("key") == os.environ.get("KEY")


def url_key(url, query, source_text):
    """The KEY of a new build of URL (with QUERY for a URL q.HASH) of the
    source SOURCE_TEXT (source()), as the step "Read the choices" of
    custom-build.yml makes it."""
    env = settings(dispatch({"INPUT_URL": url, "INPUT_QUERY": query}))
    return key(env, source_text)


def url_mark(reason, now=None):
    """Puts beam-u.URL.DAY.txt in the release, with the reason why the
    build of the URL did not run, and the link of the run. DAY is the day
    of now (UTC), as the FIFO writes it with date -u +%Y%m%d: the FIFO
    gives this text to the client in place of a new build, until the
    next day."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    url = os.environ.get("URL", "")
    if not URL.fullmatch(url):
        fail("No URL")
    run = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    detail = os.environ.get("REFUSED_DETAIL", "")
    text = f"The build did not run ({reason}). {detail}\nThe log of the run: {run}\n"
    upload(f"{URL_PREFIX}{url}.{now.strftime('%Y%m%d')}.txt", text.encode(), "text/plain")


MARK = re.compile(re.escape(URL_PREFIX) + r"(?:" + URL.pattern + r")\.[0-9]{8}\.txt")


def delete_marks():
    """Deletes each mark of a build of a URL (url_mark()). The files of
    the builds stay."""
    repo = os.environ["GITHUB_REPOSITORY"]
    for a in assets():
        if MARK.fullmatch(a["name"]):
            github(f"/repos/{repo}/releases/assets/{a['id']}", "DELETE")
            print(f"deleted {a['name']}")


def stale_urls(found, source_text, read=None):
    """The URL and the query of each file of a build of a URL in FOUND
    (the files of the release) whose NAME.json does not name the KEY of a
    build of the source SOURCE_TEXT. A file of a URL q.HASH with no query
    in NAME.json (a build before NAME.json) stays as it is, until the
    cleanup of 30 days."""
    by_name = {a["name"]: a for a in found}
    out = []
    for name in sorted(by_name):
        url = name[len(URL_PREFIX):-len(".com")] if name.startswith(URL_PREFIX) else ""
        if not (name.endswith(".com") and URL.fullmatch(url)):
            continue
        known = facts(by_name.get(name + ".json"), read)
        query = known.get("query", "") if isinstance(known.get("query", ""), str) else ""
        if url.startswith("q.") and not query:
            print(f"{name}: no query in {name}.json, so no new build")
            continue
        try:
            new = url_key(url, query, source_text)
        except SystemExit as error:
            print(f"{name}: no new build ({str(error)[:200]})")
            continue
        if known.get("key") != new:
            out.append((url, query))
    return out


def run_of(runs, title, since):
    """The run with the title TITLE that started at SINCE or later, or
    None."""
    found = [r for r in runs if r["display_title"] == title and r["created_at"] >= since]
    return min(found, key=lambda r: r["run_number"]) if found else None


def rebuild_urls(commit, sleep=time.sleep, clock=time.monotonic, now=None):
    """Starts a new build of each URL of stale_urls(), one at a time, and
    waits for its end. The run has the input rebuild: it builds only when
    the file of the URL is not of its source, and its new file replaces
    the old one (put()). Thus a request of the URL gets the old file until
    the new one is there, and never waits. The loop stops at
    REBUILD_DAILY new builds of today: the next run of the workflow (each
    day) does the rest."""
    repo = os.environ["GITHUB_REPOSITORY"]
    now = now or (lambda: datetime.datetime.now(datetime.timezone.utc))
    runs = (f"/repos/{repo}/actions/workflows/custom-build.yml/runs"
            "?event=workflow_dispatch&per_page=100")
    for url, query in stale_urls(assets(), source(commit)):
        if today() >= REBUILD_DAILY:
            print(f"{REBUILD_DAILY} new builds today: the other URLs wait for the next run")
            return
        # One minute before now: the clock of GitHub can be a bit late.
        since = (now() - datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = {"ref": "main", "inputs": {"url": url, "query": query, "rebuild": "1"}}
        github(f"/repos/{repo}/actions/workflows/custom-build.yml/dispatches", "POST",
               json.dumps(body).encode(), "application/json")
        print(f"started a new build of {url}")
        title = f"Rebuild of the URL {url}"
        start = clock()
        while True:
            sleep(30)
            run = run_of(github(runs)["workflow_runs"], title, since)
            if run and run["status"] == "completed":
                print(f"{url}: {run['conclusion']} ({run['html_url']})")
                break
            limit = REBUILD_SECONDS if run else NEW_RUN_SECONDS
            if clock() - start > limit:
                print(f"{url}: no end of the run, so the next URL")
                break


def ahead(runs, number):
    """The runs of beam.com before the run NUMBER that did not end."""
    return [r for r in runs if r["run_number"] < number and r["status"] != "completed"]


def queue(sleep=time.sleep, clock=time.monotonic):
    """Waits until each older run of beam.com ends: a FIFO of the
    run numbers, with one build at a time. Gives None at the turn of this
    run, or the reason of a refusal: queue_full (QUEUE runs wait before
    it, after the build that runs), daily_limit or timeout."""
    repo = os.environ["GITHUB_REPOSITORY"]
    number = int(os.environ["GITHUB_RUN_NUMBER"])
    path = (
        f"/repos/{repo}/actions/workflows/custom-build.yml/runs"
        "?event=workflow_dispatch&per_page=100"
    )
    start = clock()
    first = True
    while True:
        before = ahead(github(path)["workflow_runs"], number)
        if first and len(before) > QUEUE:
            return "queue_full"
        first = False
        if not before:
            return "daily_limit" if today() >= DAILY else None
        if clock() - start > WAIT_SECONDS:
            return "timeout"
        sleep(60)


def notify(status, reason=""):
    """Sends the result to the FIFO beam.com, which emails the
    requester at the address of REPLY."""
    url, secret = os.environ.get("BEAM_FIFO_URL"), os.environ.get("BEAM_FIFO_SECRET")
    if not (url and secret and os.environ.get("REPLY")):
        print("No FIFO to notify")
        return
    run = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    names = ("OTP_VERSION", "OTP_APPS", "OTP_OMIT", "HEX", "REBAR3", "ELIXIR",
             "ELIXIR_VERSION", "JIT", "SQLITE", "WASM", "NIFS_OMIT", "EXTRA_NIFS", "VIX_PARTS")
    body = {
        "status": status,
        "reason": reason,
        "file": asset_name() if status == "ready" else "",
        "reply": os.environ["REPLY"],
        "run": run,
        "settings": ", ".join(f"{n}={os.environ.get(n) or '(none)'}" for n in names),
        "detail": os.environ.get("REFUSED_DETAIL", ""),
    }
    # Cloudflare in front of mkfifo.com refuses the User-Agent of urllib
    # (error 1010, status 403).
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {secret}",
            "Content-Type": "application/json",
            "User-Agent": "beam.com-custom-build",
        },
    )
    # 200: an envelope agreed, and the email went. 204: no envelope agreed
    # (for example a wrong BEAM_FIFO_SECRET). 502: the email failed.
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    if status != 200:
        fail(f"The FIFO beam.com answered {status}")
    print("The FIFO beam.com answered 200")


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "exists" and len(argv) == 2:
        sys.exit(0 if exists() else 1)
    if command == "versions" and len(argv) == 2:
        default = defaults()
        pairs = [{"otp": o, "otp_commit": oc, "elixir": e, "elixir_commit": ec}
                 for o, oc in OTP_VERSIONS.items() for e, ec in ELIXIR_VERSIONS.items()
                 if (o, e) != (default["OTP_VERSION"], default["ELIXIR_VERSION"])]
        print(json.dumps({"otp": OTP_VERSIONS, "elixir": ELIXIR_VERSIONS,
                          "default_otp": default["OTP_VERSION"],
                          "default_elixir": default["ELIXIR_VERSION"], "pairs": pairs}))
        return
    if command == "today" and len(argv) == 2:
        print(today())
        return
    if command == "put" and len(argv) == 3:
        put(argv[2])
        return
    if command == "cleanup" and len(argv) == 2:
        cleanup()
        return
    if command == "current" and len(argv) == 2:
        sys.exit(0 if current() else 1)
    if command == "delete-marks" and len(argv) == 2:
        delete_marks()
        return
    if command == "rebuild-urls" and len(argv) == 3:
        if not re.fullmatch(r"[0-9a-f]{40}", argv[2]):
            fail(f"Not a commit: {argv[2]!r}")
        rebuild_urls(argv[2])
        return
    if command == "mark" and len(argv) == 3:
        url_mark(argv[2])
        return
    if command == "queue" and len(argv) == 2:
        reason = queue()
        if reason:
            print(f"Refused: {reason}")
            with open(os.environ["GITHUB_ENV"], "a") as f:
                f.write(f"REFUSED={reason}\n")
        return
    if command == "notify" and len(argv) in (3, 4):
        if argv[2] not in ("ready", "failed", "refused"):
            fail(f"Not a status: {argv[2]!r}")
        notify(argv[2], argv[3] if len(argv) == 4 else "")
        return
    if len(argv) != 3 or command not in ("issue", "dispatch"):
        fail("usage: custom_build.py issue|dispatch COMMIT, or see the help of the file")
    commit = argv[2]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"Not a commit: {commit!r}")
    if argv[1] == "issue":
        choices = issue(os.environ.get("BODY") or "")
    else:
        # The address first: a later step tells the requester about an
        # error of the other inputs.
        reply = os.environ.get("INPUT_REPLY", "")
        if "GITHUB_ENV" in os.environ and REPLY.fullmatch(reply):
            with open(os.environ["GITHUB_ENV"], "a") as f:
                f.write(f"REPLY={reply}\n")
        # The URL first too: the mark of a refusal has its name.
        url = os.environ.get("INPUT_URL", "")
        if "GITHUB_ENV" in os.environ and URL.fullmatch(url):
            with open(os.environ["GITHUB_ENV"], "a") as f:
                f.write(f"URL={url}\n")
        # A choice that is not possible: the requester gets the reason
        # (REFUSED=choice, and REFUSED_DETAIL with only safe characters).
        try:
            choices = dispatch(os.environ)
            env = settings(choices)
        except SystemExit as error:
            if "GITHUB_ENV" not in os.environ:
                raise
            detail = re.sub(r"[^A-Za-z0-9_ ,.:()-]", "?", str(error))[:300]
            print(f"Refused: {detail}")
            with open(os.environ["GITHUB_ENV"], "a") as f:
                f.write(f"REFUSED=choice\nREFUSED_DETAIL={detail}\n")
            return
    if argv[1] == "issue":
        env = settings(choices)
    out = dict(env, KEY=key(env, source(commit)))
    if choices["reply"]:
        out["REPLY"] = choices["reply"]
    if "GITHUB_ENV" in os.environ:
        with open(os.environ["GITHUB_ENV"], "a") as f:
            for k, v in out.items():
                f.write(f"{k}={v}\n")
    else:
        for k, v in out.items():
            print(f"{k}={v}")
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("| Setting | Value |\n|---|---|\n")
            for k, v in env.items():
                f.write(f"| {k} | {v or '(none)'} |\n")


if __name__ == "__main__":
    main(sys.argv)
