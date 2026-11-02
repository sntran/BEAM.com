#!/usr/bin/env python3
"""The choices of a custom build (.github/workflows/custom-build.yml).

The choices come from the text of an issue of the form "A custom build of
beam.com" (the variable BODY), or from the inputs of workflow_dispatch
(the variables INPUT_*), which the FIFO beam.com of mkfifo.com sends.
Both are input of a user: they only select known values, and the names of
applications must be names of OTP.

Usage:

  custom_build.py issue|dispatch COMMIT
    The settings of the Makefile, OUT_NAME, KEY, RUNTIME_KEY and REPLY go
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
  custom_build.py today      The number of files of the release of today (UTC).
  custom_build.py put FILE   Puts FILE in the release, as asset_name().
  custom_build.py cleanup    Deletes the files that are older than 30 days.
  custom_build.py queue      Waits for the turn of this run (see queue()).
  custom_build.py notify STATUS [REASON]
    Sends the result to the FIFO beam.com: ready, failed or refused.

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
# The prerelease of the files. The check of the newest release of BEAM.com
# takes only the tags v0.1.0 and later, as the prerelease edge.
RELEASE = "custom-builds"

NIFS = ("picosat_elixir", "vix", "rusty_csv", "ex_pdfium")
# The NIFs of the default build (with Elixir; exqlite also needs SQLite),
# which a build can leave out (NIFS_OMIT of scripts/steps.sh). The form
# sends the word "default" and the names of the default NIFs to keep.
DEFAULT_NIFS = ("exqlite", "bcrypt_elixir", "argon2_elixir")
# The parts of the libvips of vix (VIX_PARTS of scripts/steps.sh), as
# words of the NIFs. Each one also selects vix.
VIX_PARTS = {"vix-icc": "icc", "vix-gif": "gif", "vix-avif": "avif"}
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
# KEY.
NOT_SOURCE = (".github", ".formatter.exs", ".gitignore", "docs", "examples", "js", "lib",
              "mix.exs", "mix.lock", "package.json", "priv/seeds", "specs", "tests")
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


def dispatch(env):
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
            if name in NOT_SOURCE or ("/" not in name and name.endswith(".md")):
                continue
            if any(n.startswith(name + "/") for n in NOT_SOURCE):
                yield from walk(name)
            else:
                yield f"{meta.split()[2]} {name}"

    lines = list(walk(""))
    if not any(line.endswith(" scripts") for line in lines):
        fail(f"No source at the commit {commit}")
    return "".join(f"{line}\n" for line in lines)


def key(env, source_text):
    text = "".join(f"{k}={env[k]}\n" for k in sorted(env)) + source_text
    return hashlib.sha256(text.encode()).hexdigest()


def runtime_key(env):
    """The part of the cache key of the WebAssembly runtime that comes
    from the choices: the hex.pm NIFs of the runtime (see
    wasm_runtime_inputs of scripts/steps.sh). Empty for the NIFs of the
    default build, so a custom build can use the cache of build.yml."""
    nifs = []
    omit = env.get("NIFS_OMIT", "").split()
    if env["ELIXIR"] == "1":
        nifs = [n for n in ("bcrypt_elixir", "argon2_elixir") if n not in omit]
        nifs += [n for n in env["EXTRA_NIFS"].split() if n == "picosat_elixir"]
        if env["SQLITE"] == "1" and "exqlite" not in omit:
            nifs.append("exqlite")
    if nifs == ["bcrypt_elixir", "argon2_elixir", "exqlite"]:
        return ""
    return "-" + "-".join(nifs or ["none"])


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
    beam-emu-KEY16.com, with the first 16 characters of KEY."""
    if not re.fullmatch(r"[0-9a-f]{64}", os.environ.get("KEY", "")):
        fail("No KEY")
    stem = {"beam.com": "beam", "beam-emu.com": "beam-emu"}.get(os.environ.get("OUT_NAME"))
    if not stem:
        fail("No OUT_NAME")
    return f"{stem}-{os.environ['KEY'][:16]}.com"


def release(create=False):
    """The prerelease RELEASE of the custom builds, or None. With create,
    a new one when it is not there."""
    repo = os.environ["GITHUB_REPOSITORY"]
    try:
        return github(f"/repos/{repo}/releases/tags/{RELEASE}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    if not create:
        return None
    body = {
        "tag_name": RELEASE,
        "target_commitish": os.environ.get("GITHUB_SHA", "main"),
        "name": "Custom builds",
        "prerelease": True,
        "body": (
            "The files of the custom builds of the FIFO beam.com of mkfifo.com "
            "(docs/BUILDING.md). Each file is beam-KEY.com or beam-emu-KEY.com, "
            "and goes away after 30 days. This is not a release of BEAM.com."
        ),
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
    return sum(1 for a in assets() if a["created_at"].startswith(day))


def cleanup(now=None, days=30):
    """Deletes the files of the release that are older than DAYS days."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    repo = os.environ["GITHUB_REPOSITORY"]
    for a in assets():
        made = datetime.datetime.fromisoformat(a["created_at"].replace("Z", "+00:00"))
        if now - made > datetime.timedelta(days=days):
            github(f"/repos/{repo}/releases/assets/{a['id']}", "DELETE")
            print(f"deleted {a['name']}")


def put(file):
    """Puts FILE in the release with the name of asset_name()."""
    found = release(create=True)
    name = asset_name()
    for a in found["assets"]:
        if a["name"] == name:
            return
    with open(file, "rb") as f:
        data = f.read()
    upload = found["upload_url"].split("{", 1)[0]
    github(
        "?name=" + urllib.parse.quote(name),
        "POST",
        data,
        "application/octet-stream",
        base=upload,
    )


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
    out = dict(env, KEY=key(env, source(commit)), RUNTIME_KEY=runtime_key(env))
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
