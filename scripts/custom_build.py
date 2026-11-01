#!/usr/bin/env python3
"""The choices of a custom build (.github/workflows/custom-build.yml).

The choices come from the text of an issue of the form "A custom build of
beam.com" (the variable BODY), or from the inputs of workflow_dispatch
(the variables INPUT_*), which the FIFO build-a-beam of mkfifo.com sends.
Both are input of a user: they only select known values, and the names of
applications must be names of OTP.

Usage:

  custom_build.py issue|dispatch COMMIT
    The settings of the Makefile, OUT_NAME, KEY and REPLY go to the file
    of GITHUB_ENV, and a table to the file of GITHUB_STEP_SUMMARY (when
    these variables are set). KEY is the SHA-256 of the settings and of
    the commit: two requests with the same choices on the same commit
    have the same KEY, and the same file.
  custom_build.py exists     Status 0 when R2 has builds/KEY/OUT_NAME.
  custom_build.py today      The number of builds that R2 got today (UTC).
  custom_build.py put FILE   Writes FILE to builds/KEY/OUT_NAME in R2.
  custom_build.py queue      Waits for the turn of this run (see queue()).
  custom_build.py notify STATUS [REASON]
    Sends the result to the FIFO build-a-beam: ready, failed or refused.

R2: R2_ENDPOINT (https://ACCOUNT_ID.r2.cloudflarestorage.com), R2_BUCKET,
R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY. The FIFO: BUILD_A_BEAM_URL and
BUILD_A_BEAM_SECRET.
"""

import datetime
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# The limits of the builds of build-a-beam: one build at a time, at most
# QUEUE runs that wait, and at most DAILY new builds each day (UTC).
QUEUE = 3
DAILY = 10
WAIT_SECONDS = 180 * 60

NIFS = ("picosat_elixir", "vix")
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


def r2_request(method, path, params=None, data=None, now=None):
    """A request to R2 with AWS Signature Version 4 (region auto)."""
    query = "&".join(
        f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
        for k, v in sorted((params or {}).items())
    )
    endpoint = os.environ["R2_ENDPOINT"].rstrip("/")
    host = urllib.parse.urlsplit(endpoint).netloc
    now = now or datetime.datetime.now(datetime.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    day = stamp[:8]
    payload = "UNSIGNED-PAYLOAD"
    headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": stamp}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(
        [
            method,
            urllib.parse.quote(path),
            query,
            "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
            signed,
            payload,
        ]
    )
    scope = f"{day}/auto/s3/aws4_request"
    to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    k = ("AWS4" + os.environ["R2_SECRET_ACCESS_KEY"]).encode()
    for part in (day, "auto", "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={os.environ['R2_ACCESS_KEY_ID']}/{scope}, "
        f"SignedHeaders={signed}, Signature={signature}"
    )
    del headers["host"]
    url = endpoint + urllib.parse.quote(path) + ("?" + query if query else "")
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def object_path():
    if not re.fullmatch(r"[0-9a-f]{64}", os.environ.get("KEY", "")):
        fail("No KEY")
    if os.environ.get("OUT_NAME") not in ("beam.com", "beam-emu.com"):
        fail("No OUT_NAME")
    return f"/{os.environ['R2_BUCKET']}/builds/{os.environ['KEY']}/{os.environ['OUT_NAME']}"


def exists():
    status, _body = r2_request("HEAD", object_path())
    if status not in (200, 404):
        fail(f"R2 answered {status} to HEAD")
    return status == 200


def today(now=None):
    """The objects under builds/ that R2 got today (UTC): the new builds."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    day = now.strftime("%Y-%m-%d")
    count, token = 0, None
    while True:
        params = {"list-type": "2", "prefix": "builds/"}
        if token:
            params["continuation-token"] = token
        status, body = r2_request("GET", f"/{os.environ['R2_BUCKET']}", params)
        if status != 200:
            fail(f"R2 answered {status} to the list")
        text = body.decode()
        count += len(re.findall(rf"<LastModified>{day}T", text))
        match = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", text)
        if not match:
            return count
        token = match.group(1)


def put(file):
    with open(file, "rb") as f:
        data = f.read()
    status, body = r2_request("PUT", object_path(), data=data)
    if status != 200:
        fail(f"R2 answered {status} to PUT: {body[:200]!r}")


def github(path):
    url = f"{os.environ.get('GITHUB_API_URL', 'https://api.github.com')}{path}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def ahead(runs, number):
    """The runs of build-a-beam before the run NUMBER that did not end."""
    return [r for r in runs if r["run_number"] < number and r["status"] != "completed"]


def queue(sleep=time.sleep, clock=time.monotonic):
    """Waits until each older run of build-a-beam ends: a FIFO of the
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
    """Sends the result to the FIFO build-a-beam, which emails the
    requester at the address of REPLY."""
    url, secret = os.environ.get("BUILD_A_BEAM_URL"), os.environ.get("BUILD_A_BEAM_SECRET")
    if not (url and secret and os.environ.get("REPLY")):
        print("No FIFO to notify")
        return
    run = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    names = ("OTP_APPS", "HEX", "REBAR3", "ELIXIR", "JIT", "SQLITE", "WASM", "EXTRA_NIFS")
    body = {
        "status": status,
        "reason": reason,
        "key": os.environ.get("KEY", ""),
        "file": os.environ.get("OUT_NAME", ""),
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
    # (for example a wrong BUILD_A_BEAM_SECRET). 502: the email failed.
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    if status != 200:
        fail(f"build-a-beam answered {status}")
    print("build-a-beam answered 200")


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
