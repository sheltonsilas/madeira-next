#!/usr/bin/env python3
"""Fetch and verify the newest Madeira Next IPA from CI.

WHY THIS EXISTS
The IPA is built by .github/workflows/ios.yml, but it used to live in only two
places: a CI artifact, which GitHub deletes after 14 days, and whatever `dist/`
happens to hold on the machine that downloaded it. Both can be gone between one
session and the next, and then "the build is green" is a claim about a file
nobody can produce.

So the workflow now also publishes the IPA to a rolling release, which does not
expire, and this tool prefers that release and falls back to the artifacts. It
turns a green run back into a verified local IPA with one command, from any
checkout, without the GitHub web UI, and without the laptop that asked for it
being awake.

It refuses to call the file good unless the archive is intact, the engine and its
frameworks resolve inside the bundle, the firmware is present, no signature is
left behind that would block re-signing, and - when the release published one -
the sha256 matches the file the release says it published.

It can also poll until a run finishes, which is the part that outlives the shell
that started it: run it with --wait and the download still happens after the
session that asked for it is gone.

Usage:
    python3 tools/fetch_latest_ipa.py                   # newest -> dist/
    python3 tools/fetch_latest_ipa.py --require-head     # only for this commit
    python3 tools/fetch_latest_ipa.py --source release   # permanent release only
    python3 tools/fetch_latest_ipa.py --wait 60          # poll until one appears

Exit 0 only when a verified IPA is on disk. Any other exit means the IPA on the
disk was not replaced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API = "https://api.github.com"
DEFAULT_REPO = "sheltonsilas/madeira-next"
DEFAULT_ARTIFACT = "MadeiraNext-unsigned-ipa"
DEFAULT_RELEASE_TAG = "ipa-latest"
DEFAULT_OUT = "dist/MadeiraNext-unsigned.ipa"

# The names the publish job puts on the release. They are part of the interface
# between the workflow and this tool, so they are spelled once, here.
IPA_ASSET = "MadeiraNext-unsigned.ipa"
CHECKSUM_ASSET = "MadeiraNext-unsigned.ipa.sha256"
INFO_ASSET = "build-info.json"

PREFIX = "Payload/MadeiraNext.app/"
ENGINE = PREFIX + "Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
FIRMWARE = (
    PREFIX + "share/qemu/edk2-aarch64-code.fd",
    PREFIX + "share/qemu/edk2-arm-vars.fd",
)

EXIT_OK = 0
EXIT_VERIFY = 1
EXIT_USAGE = 2
EXIT_NONE = 3


class NoCrossHostAuth(urllib.request.HTTPRedirectHandler):
    """Keep the token off the host the download is redirected to.

    GitHub answers both the artifact download and a release asset with a 302 to
    signed blob storage. urllib copies the request headers onto the redirect, so
    without this the token would be sent to a host that does not need it.
    Browsers drop the Authorization header on a cross-host redirect; so does
    this.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        if urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            redirected.headers.pop("Authorization", None)
        return redirected


def read_token(explicit: str) -> str:
    """The token, from the environment first and then from a file.

    The value is never printed: it is only ever put on a request header.
    """
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    path = pathlib.Path(explicit).expanduser()
    if path.is_file():
        return path.read_text().strip()
    return ""


def api(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "madeira-next-fetch-ipa",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download_bytes(url: str, token: str, timeout: int = 600):
    """Open a download URL, following the redirect without the token."""
    request = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/octet-stream",
        "User-Agent": "madeira-next-fetch-ipa",
    })
    return urllib.request.build_opener(NoCrossHostAuth()).open(request, timeout=timeout)


def list_artifacts(repo: str, name: str, token: str) -> list:
    """Every non-expired artifact with this name, newest first."""
    url = f"{API}/repos/{repo}/actions/artifacts?name={urllib.parse.quote(name)}&per_page=100"
    found = [a for a in api(url, token).get("artifacts", []) if not a["expired"]]
    found.sort(key=lambda a: a["created_at"], reverse=True)
    return found


def pick(repo: str, name: str, token: str, head: str | None) -> dict | None:
    for artifact in list_artifacts(repo, name, token):
        run = artifact.get("workflow_run") or {}
        if head and run.get("head_sha") != head:
            continue
        return artifact
    return None


def published_release(repo: str, tag: str, token: str) -> dict | None:
    """The rolling release, or None when it has not been published yet.

    A missing tag is the ordinary state of a repository that has not published
    one, not a failure, so it is reported as absence and the caller falls back.
    """
    try:
        return api(f"{API}/repos/{repo}/releases/tags/{urllib.parse.quote(tag)}", token)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def asset(release_body: dict, name: str) -> dict | None:
    """One named asset of a release, or None."""
    for item in release_body.get("assets", []):
        if item["name"] == name:
            return item
    return None


def asset_text(release_body: dict, name: str, token: str) -> str | None:
    """A small text asset, or None when it is absent or unreadable."""
    item = asset(release_body, name)
    if item is None:
        return None
    try:
        with download_bytes(item["browser_download_url"], token, timeout=120) as response:
            return response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError):
        return None


def published_commit(release_body: dict, token: str) -> str | None:
    """The commit the release's IPA was built from, per its build-info.json.

    A release tag says nothing about which commit is inside it: the tag is
    rewritten by every green build. The provenance has to be published beside the
    artifact for --require-head to mean anything against a release.
    """
    text = asset_text(release_body, INFO_ASSET, token)
    if text is None:
        return None
    try:
        return json.loads(text).get("commit")
    except ValueError:
        return None


def published_checksum(release_body: dict, token: str) -> str | None:
    """The sha256 the release says its IPA has, or None."""
    text = asset_text(release_body, CHECKSUM_ASSET, token)
    if text is None:
        return None
    first = text.strip().split()[0] if text.strip() else ""
    return first or None


def head_sha() -> str | None:
    """The commit this checkout is on, or None outside a work tree."""
    try:
        result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def unwrap(archive_path: pathlib.Path, destination: pathlib.Path) -> None:
    """Turn a downloaded artifact archive into the IPA at `destination`.

    GitHub hands an artifact back as a zip containing whatever was uploaded. The
    workflow uploads the IPA itself, so the download is a zip with a single
    `MadeiraNext-unsigned.ipa` member. That nesting is unwrapped here rather than
    left to the caller, because a zip inside a zip is not the file a signing tool
    or a device expects. An artifact that already is the IPA is accepted too, so
    the tool does not depend on how the workflow happens to upload it.
    """
    partial = destination.with_name(destination.name + ".partial")
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if any(name.startswith("Payload/") for name in names):
            shutil.copyfile(archive_path, partial)
        else:
            inner = [name for name in names if name.lower().endswith(".ipa")]
            if len(inner) != 1:
                raise ValueError(
                    f"the artifact holds {len(names)} file(s) and "
                    f"{len(inner)} .ipa member(s): {names[:5]}")
            with archive.open(inner[0]) as source, open(partial, "wb") as target:
                shutil.copyfileobj(source, target, 1 << 20)
    # Renamed only once it is whole, so an interrupted run cannot leave a
    # truncated file where the next one would trust it.
    partial.replace(destination)


def download(artifact: dict, destination: pathlib.Path, token: str) -> None:
    """Fetch the artifact and write its IPA to `destination`."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name(destination.name + ".download")
    try:
        with download_bytes(artifact["archive_download_url"], token) as response, \
                open(staged, "wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                handle.write(chunk)
        unwrap(staged, destination)
    finally:
        staged.unlink(missing_ok=True)


def download_asset(url: str, destination: pathlib.Path, token: str) -> None:
    """Fetch a release asset, which is the file itself rather than a zip of it."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name(destination.name + ".download")
    try:
        with download_bytes(url, token) as response, open(staged, "wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                handle.write(chunk)
        staged.replace(destination)
    finally:
        staged.unlink(missing_ok=True)


def digest(path: pathlib.Path) -> str:
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            sha.update(chunk)
    return sha.hexdigest()


def verify(ipa: pathlib.Path) -> list:
    """The problems that make this file not the deliverable, or [].

    Deliberately narrow: the engine's own dependencies are checked by
    tools/check_ipa_bundle.py, which is run separately so its exit status is
    preserved rather than paraphrased.
    """
    problems = []
    try:
        with zipfile.ZipFile(ipa) as archive:
            broken = archive.testzip()
            if broken is not None:
                problems.append(f"the archive is corrupt at {broken}")
            names = set(archive.namelist())
    except zipfile.BadZipFile as error:
        return [f"not a zip archive: {error}"]

    if ENGINE not in names:
        problems.append(f"no engine at {ENGINE}")
    for path in FIRMWARE:
        if path not in names:
            problems.append(f"no firmware at {path}")
    # Unsigned is the point: a signature would have to be stripped before the
    # app could be re-signed with the user's own Apple ID.
    signed = any("_CodeSignature" in name for name in names) or \
        any("embedded.mobileprovision" in name for name in names)
    if signed:
        problems.append("the IPA carries a signature, so it is not the unsigned artifact")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch and verify the newest Madeira Next IPA from CI.")
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help=f"where to write the IPA (default: {DEFAULT_OUT})")
    parser.add_argument("--repo", default=os.environ.get("MADEIRA_REPO", DEFAULT_REPO),
                        help=f"owner/name to fetch from (default: {DEFAULT_REPO})")
    parser.add_argument("--artifact", default=DEFAULT_ARTIFACT,
                        help=f"artifact name (default: {DEFAULT_ARTIFACT})")
    parser.add_argument("--release-tag", default=DEFAULT_RELEASE_TAG,
                        help=f"rolling release to prefer (default: {DEFAULT_RELEASE_TAG})")
    parser.add_argument("--source", choices=("auto", "release", "artifact"), default="auto",
                        help="where to fetch from; auto prefers the release, which "
                             "does not expire, and falls back to the CI artifact")
    parser.add_argument("--token-file", default="~/.madeira_push_token",
                        help="read the token from this file when the environment has none")
    parser.add_argument("--require-head", action="store_true",
                        help="only accept a build from this checkout's commit")
    parser.add_argument("--wait", type=float, default=0, metavar="SECONDS",
                        help="poll every SECONDS until an artifact appears")
    parser.add_argument("--timeout", type=float, default=45, metavar="MINUTES",
                        help="give up waiting after this long (default: 45)")
    parser.add_argument("--quiet", action="store_true", help="only report the outcome")
    args = parser.parse_args()

    def say(*message):
        if not args.quiet:
            print(*message, flush=True)

    token = read_token(args.token_file)
    if not token:
        print(f"no token: set GH_TOKEN or put one in {args.token_file}", file=sys.stderr)
        return EXIT_USAGE

    head = head_sha() if args.require_head else None
    if args.require_head:
        if head is None:
            print("--require-head needs a git checkout", file=sys.stderr)
            return EXIT_USAGE
        say(f"this checkout is {head[:12]}")

    out = pathlib.Path(args.out)

    # The release first: it is the one copy that does not expire, so it is what
    # survives a laptop being asleep, closed, or off for a month.
    release_body = None
    if args.source in ("auto", "release"):
        release_body = published_release(args.repo, args.release_tag, token)
        if release_body is None:
            if args.source == "release":
                print(f"release {args.release_tag} does not exist in {args.repo}",
                      file=sys.stderr)
                print(f"  run the ios workflow on main to publish it: "
                      f"https://github.com/{args.repo}/actions/workflows/ios.yml",
                      file=sys.stderr)
                return EXIT_NONE
        elif asset(release_body, IPA_ASSET) is None:
            say(f"release {args.release_tag} has no {IPA_ASSET} asset; "
                "falling back to artifacts")
            release_body = None
        elif head is not None:
            built = published_commit(release_body, token)
            if built != head:
                say(f"release {args.release_tag} was built from {str(built)[:12]}, "
                    f"not {head[:12]}; falling back to artifacts")
                release_body = None

    if release_body is not None:
        ipa_asset = asset(release_body, IPA_ASSET)
        expected = published_checksum(release_body, token)
        committed = published_commit(release_body, token)
        say(f"release {args.release_tag}: {IPA_ASSET}, {ipa_asset['size']} bytes, "
            f"published {ipa_asset['created_at']}")
        if committed:
            say(f"  built from {committed[:12]}")
        if expected:
            say(f"  published sha256 {expected}")
        say(f"  {release_body['html_url']}")
        print(f"downloading {out} (release)", flush=True)
        try:
            download_asset(ipa_asset["browser_download_url"], out, token)
        except (urllib.error.URLError, OSError) as error:
            print(f"the download failed: {error}", file=sys.stderr)
            return EXIT_VERIFY
    else:
        if args.source == "release":
            # --source release was asked to take the release and nothing else, and
            # the only way to arrive here with a release in hand is a commit
            # mismatch, so say which commit it holds rather than exiting mute.
            print(f"release {args.release_tag} does not hold a build of "
                  f"{(head or 'this commit')[:12]}", file=sys.stderr)
            return EXIT_NONE
        deadline = time.monotonic() + args.timeout * 60
        artifact = pick(args.repo, args.artifact, token, head)
        while artifact is None and args.wait > 0 and time.monotonic() < deadline:
            # The run is not finished yet. Peeking does not consume the artifact,
            # so polling costs nothing but the request.
            if args.require_head:
                say(f"no {args.artifact} for {head[:12]} yet; checking again in {args.wait:g}s")
            else:
                say(f"no {args.artifact} yet; checking again in {args.wait:g}s")
            time.sleep(args.wait)
            artifact = pick(args.repo, args.artifact, token, head)

        if artifact is None:
            wanted = f" for {head[:12]}" if head else ""
            print(f"no unexpired {args.artifact} artifact{wanted} in {args.repo}",
                  file=sys.stderr)
            print(f"  start one: https://github.com/{args.repo}/actions/workflows/ios.yml",
                  file=sys.stderr)
            return EXIT_NONE

        expected = None
        run = artifact.get("workflow_run") or {}
        run_id = run.get("id")
        say(f"artifact {artifact['id']}: {artifact['size_in_bytes']} bytes, "
            f"created {artifact['created_at']}")
        say(f"  from commit {str(run.get('head_sha'))[:12]} on {run.get('head_branch')}")
        if run_id:
            say(f"  run: https://github.com/{args.repo}/actions/runs/{run_id}")

        if not args.quiet:
            say(f"downloading to {out}")
        else:
            print(f"downloading {out}")
        try:
            download(artifact, out, token)
        except (ValueError, zipfile.BadZipFile, urllib.error.URLError, OSError) as error:
            print(f"the artifact could not be read: {error}", file=sys.stderr)
            return EXIT_VERIFY

    actual = digest(out)
    print(f"{out}: {out.stat().st_size} bytes, sha256 {actual}", flush=True)

    problems = verify(out)
    # A release publishes what its file should hash to. Comparing is what makes
    # the download provably the published artifact and not some other build that
    # happens to be structurally sound.
    if expected and actual != expected:
        problems.append(f"the file is not what the release published: expected {expected}")
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    if problems:
        print("the download is not the deliverable", file=sys.stderr)
        return EXIT_VERIFY

    # The bundle checker is the repository's own gate on the engine's
    # dependencies. Its exit status is the answer, so it is run rather than
    # reimplemented here.
    checker = pathlib.Path(__file__).with_name("check_ipa_bundle.py")
    result = subprocess.run([sys.executable, str(checker), str(out)])
    if result.returncode != 0:
        print("tools/check_ipa_bundle.py rejected the bundle", file=sys.stderr)
        return EXIT_VERIFY

    # Beside the IPA, so the file can be re-checked later without refetching.
    checksum = out.with_name(out.name + ".sha256")
    checksum.write_text(f"{actual}  {out.name}\n")
    print(f"verified: {out}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
