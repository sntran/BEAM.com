#!/usr/bin/env python3
"""Saves the envelopes of the FIFO build-a-beam of mkfifo.com.

build-a-beam is a held FIFO: a form of a custom build of beam.com for a
person with no GitHub account (docs/BUILDING.md, "A custom build"). Its
envelopes are in priv/seeds/build-a-beam/, with the names of the seeds of
mkfifo.com:

  N-LABEL.eml        an ingress envelope
  N-LABEL.OTHER.eml  an egress envelope that replies to it
  N-LABEL.K.html     a note about it, in the sequence of K

The holder is a FIFO with a secret name: each person who knows the name
can change the envelopes. The envelopes have {{NAME}} for the values of
the variables BUILD_A_BEAM_NAME of the environment. A value in <seal:...>
is a secret: mkfifo.com seals it at the save, and nobody reads it again.
The repository has no value.

Usage: build-a-beam.py [--print]

  --print  Show the envelopes with the values, and the secrets as ****.
           Save nothing.

The variables:

  BUILD_A_BEAM_HOLDER          The secret name of the holder (26 characters
                               or more).
  BUILD_A_BEAM_BASE            https://mkfifo.com (the default).
  BUILD_A_BEAM_STATE           The file of the Message-IDs of the last save
                               (default ~/.config/build-a-beam/HOLDER.ids).
                               The next save deletes these envelopes first.
  BUILD_A_BEAM_GITHUB_REPO     sntran/BEAM.com (the default).
  BUILD_A_BEAM_GITHUB_REF      main (the default).
  BUILD_A_BEAM_GITHUB_TOKEN    A fine-grained token: Actions, read and write,
                               on the repository only.
  BUILD_A_BEAM_CF_ACCOUNT_ID   The Cloudflare account of the email sender.
  BUILD_A_BEAM_CF_EMAIL_TOKEN  A token of Cloudflare Email Service (send).
  BUILD_A_BEAM_FROM            The sender, for example build-a-beam@mkfifo.com.
  BUILD_A_BEAM_BOX_KEY         32 bytes in hexadecimal: the key of the boxes
                               of the addresses.
  BUILD_A_BEAM_DONE_SECRET     The secret of the answers of the workflow: the
                               secret BUILD_A_BEAM_SECRET of the repository.
  BUILD_A_BEAM_R2_BUCKET       The bucket of the builds.
  BUILD_A_BEAM_R2_ENDPOINT     https://ACCOUNT_ID.r2.cloudflarestorage.com
  BUILD_A_BEAM_R2_READ_KEY_ID  An R2 key that can only read the bucket.
  BUILD_A_BEAM_R2_READ_SECRET  Its secret.
"""

import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

SEEDS = pathlib.Path(__file__).resolve().parent.parent / "priv" / "seeds" / "build-a-beam"
DEFAULTS = {
    "BASE": "https://mkfifo.com",
    "GITHUB_REPO": "sntran/BEAM.com",
    "GITHUB_REF": "main",
}
PLACEHOLDER = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
SEALED = re.compile(r"<seal:[^>]*>")
INGRESS = re.compile(r"^(\d+)-([a-z0-9-]+)\.eml$")


def fail(message):
    raise SystemExit(f"build-a-beam: {message}")


def value(name):
    text = os.environ.get("BUILD_A_BEAM_" + name, DEFAULTS.get(name, ""))
    if not text:
        fail(f"BUILD_A_BEAM_{name} is not set")
    if "\n" in text or "\r" in text or ">" in text:
        fail(f"BUILD_A_BEAM_{name} has a line break or a '>'")
    return text


def check():
    if not re.fullmatch(r"[0-9a-f]{64}", value("BOX_KEY")):
        fail("BUILD_A_BEAM_BOX_KEY must be 32 bytes in hexadecimal (64 characters)")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{25,63}", value("HOLDER")):
        fail("BUILD_A_BEAM_HOLDER must be a name of 26 to 64 characters: a-z, 0-9, -, _ and .")
    if not re.fullmatch(r"https://[a-z0-9.-]+(:[0-9]+)?", value("BASE").rstrip("/")):
        if not re.fullmatch(r"http://localhost(:[0-9]+)?", value("BASE").rstrip("/")):
            fail("BUILD_A_BEAM_BASE must be an https URL with no path")


def render(text):
    return PLACEHOLDER.sub(lambda m: value(m.group(1)), text)


def envelopes():
    """[(file, ingress text, [(file, egress text)], [(file, note html)])]"""
    files = sorted(p.name for p in SEEDS.iterdir())
    result = []
    for name in sorted((f for f in files if INGRESS.match(f)), key=lambda f: int(f.split("-")[0])):
        stem = name[: -len(".eml")]
        egress = [f for f in files if f != name and f.startswith(stem + ".") and f.endswith(".eml")]
        notes = sorted(
            (f for f in files if re.fullmatch(re.escape(stem) + r"\.\d+\.html", f)),
            key=lambda f: int(f.split(".")[-2]),
        )
        result.append(
            (
                name,
                (SEEDS / name).read_text(),
                [(f, (SEEDS / f).read_text()) for f in egress],
                [(f, (SEEDS / f).read_text()) for f in notes],
            )
        )
    return result


def request(method, body=b"", headers=None, sleep=time.sleep):
    """A save or a delete in the holder. mkfifo.com takes 60 changes from
    one address in 10 minutes: after 429, the request waits and goes
    again, for at most 15 minutes."""
    url = value("BASE").rstrip("/") + "/" + value("HOLDER")
    waited = 0
    while True:
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            if error.code != 429 or waited >= 15 * 60:
                return error.code, text
            pause = 60
            print(f"mkfifo.com answered 429; the next try is in {pause} s")
            sleep(pause)
            waited += pause


def save(file, text, headers=None):
    status, body = request("PUT", text.encode(), headers)
    if status not in (200, 201):
        # The body tells the errors with the line numbers, never a value.
        fail(f"the save of {file} answered {status}: {body.strip()[:500]}")
    match = re.search(r"^Message-ID: (<[^>]+>)", body, re.M)
    return match.group(1) if match else None


def state_file():
    default = pathlib.Path.home() / ".config" / "build-a-beam" / (value("HOLDER") + ".ids")
    return pathlib.Path(os.environ.get("BUILD_A_BEAM_STATE") or default)


def main(argv):
    show = argv[1:] == ["--print"]
    if argv[1:] and not show:
        fail("usage: build-a-beam.py [--print]")
    check()
    all_envelopes = envelopes()
    if show:
        for name, ingress, egress, _notes in all_envelopes:
            for file, text in [(name, ingress)] + egress:
                print(f"=== {file}\n{SEALED.sub('<seal:****>', render(text))}")
        return

    state = state_file()
    if state.exists():
        for message_id in state.read_text().split():
            status, body = request("DELETE", headers={"Message-ID": message_id})
            if status not in (204, 404):
                fail(f"the delete of {message_id} answered {status}: {body.strip()[:200]}")
    ids = []
    for name, ingress, egress, notes in all_envelopes:
        message_id = save(name, render(ingress))
        if not message_id:
            fail(f"no Message-ID for {name}")
        ids.append(message_id)
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text("\n".join(ids) + "\n")
        os.chmod(state, 0o600)
        for file, text in egress:
            save(file, f"In-Reply-To: {message_id}\n" + render(text))
        for file, html in notes:
            save(file, html, {"Content-Type": "text/html", "In-Reply-To": message_id})
        print(f"saved {name} with {len(egress)} egress envelopes")
    print(f"{len(ids)} ingress envelopes in the holder. The Message-IDs: {state}")


if __name__ == "__main__":
    main(sys.argv)
