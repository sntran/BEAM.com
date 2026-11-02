#!/usr/bin/env python3
"""The choices of a custom build (.github/workflows/custom-build.yml).

The choices come from the text of an issue of the form "A custom build of
beam.com" (the variable BODY), or from the inputs of workflow_dispatch
(the variables INPUT_*), which the FIFO beam.com of mkfifo.com sends.
Both are input of a user: they only select known values, and the names of
applications must be names of OTP.

Usage:

  custom_build.py issue|dispatch COMMIT
    The settings of the Makefile, OUT_NAME, KEY and REPLY go to the file
    of GITHUB_ENV, and a table to the file of GITHUB_STEP_SUMMARY (when
    these variables are set). KEY is the SHA-256 of the settings and of
    the commit: two requests with the same choices on the same commit
    have the same KEY, and the same file.
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

NIFS = ("picosat_elixir", "vix", "rusty_csv")
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
        "nifs": [n.split()[0] for n in checked("More NIFs")],
        "hex": any(t.startswith("Hex") for t in tools),
        "rebar3": any(t.startswith("rebar3") for t in tools),
        "elixir": choice("Elixir", "Yes") != "No",
        "jit": not choice("Emulator", "").startswith("Interpreter"),
        "sqlite": choice("SQLite", "Yes") != "No",
        "wasm": choice("WebAssembly (WAMR)", "Yes") != "No",
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
    choices = {name: flag(name) for name in FLAGS}
    choices["apps"] = env.get("INPUT_APPS", "").replace(",", " ").split()
    choices["nifs"] = env.get("INPUT_NIFS", "").replace(",", " ").split()
    choices["reply"] = reply
    return choices


def settings(choices):
    apps = sorted(set(choices["apps"]))
    bad = [a for a in apps if not APP.fullmatch(a)]
    if bad:
        fail(f"Not names of applications: {bad}")
    if len(apps) > 40:
        fail("More than 40 applications")
    nifs = sorted(set(choices["nifs"]))
    bad = [n for n in nifs if n not in NIFS]
    if bad:
        fail(f"Not NIFs of the list: {bad}")
    if choices["hex"] and not choices["elixir"]:
        fail("Hex needs Elixir")
    if nifs and not choices["elixir"]:
        fail("The NIFs of hex.pm packages need Elixir")
    one = lambda b: "1" if b else "0"
    env = {
        "OTP_APPS": " ".join(apps),
        "HEX": one(choices["hex"]),
        "REBAR3": one(choices["rebar3"]),
        "ELIXIR": one(choices["elixir"]),
        "JIT": one(choices["jit"]),
        "SQLITE": one(choices["sqlite"]),
        "WASM": one(choices["wasm"]),
        "EXTRA_NIFS": " ".join(nifs),
    }
    env["OUT_NAME"] = "beam.com" if env["JIT"] == "1" else "beam-emu.com"
    return env


def key(env, commit):
    text = "".join(f"{k}={env[k]}\n" for k in sorted(env)) + f"COMMIT={commit}\n"
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
    names = ("OTP_APPS", "HEX", "REBAR3", "ELIXIR", "JIT", "SQLITE", "WASM", "EXTRA_NIFS")
    body = {
        "status": status,
        "reason": reason,
        "file": asset_name() if status == "ready" else "",
        "reply": os.environ["REPLY"],
        "run": run,
        "settings": ", ".join(f"{n}={os.environ.get(n) or '(none)'}" for n in names),
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
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
        choices = dispatch(os.environ)
    env = settings(choices)
    out = dict(env, KEY=key(env, commit))
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
