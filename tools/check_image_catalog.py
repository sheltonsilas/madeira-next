#!/usr/bin/env python3
"""Check the image catalogue against the servers it names.

WHY THIS EXISTS
The point of the catalogue is that a user never has to find a distribution image.
That only works while every URL in it is real, every size is right and every
checksum list still covers the file - and none of that can be seen by reading the
Swift. A dead URL in the table is a button that fails on a device, which is the
worst place to find out.

WHAT IS CHECKED
For each GuestImage in App/ImageCatalog.swift:
  * the URL is https;
  * the last path component of the URL is the name the table says the server
    publishes, because that name is what a checksum list is searched for;
  * a HEAD (or a ranged GET, for a server that refuses HEAD) answers 200 and its
    Content-Length is the byte count the table records - that number is what the
    download's progress bar is drawn from;
  * a published checksum list answers 200 and mentions the file.

The stored name is checked against the recorded format too, because that is what
QEMU is told to read: a qcow2 image stored under a name ending in .img would be
attached as raw, and raw and qcow2 read the same bytes very differently.

Usage:
    python3 tools/check_image_catalog.py             # table + network
    python3 tools/check_image_catalog.py --offline   # table only

Exit 0 only when every check passes. A connection that fails is retried three
times and then reported: a catalogue that cannot be reached is not a catalogue
that is correct.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "ImageCatalog.swift"

FIELD_PATTERNS = {
    "id": r'id:\s*"([^"]+)"',
    "kind": r"kind:\s*\.(\w+)",
    "remoteFileName": r'remoteFileName:\s*"([^"]+)"',
    "storedFileName": r'storedFileName:\s*"([^"]+)"',
    "url": r'url:\s*URL\(string:\s*"([^"]+)"',
    "format": r"format:\s*\.(\w+)",
    "byteCount": r"byteCount:\s*([0-9_]+)",
    "checksumURL": r'checksumURL:\s*URL\(string:\s*"([^"]+)"',
    "checksumAlgorithm": r"checksumAlgorithm:\s*\.(\w+)",
}

ATTEMPTS = 3
TIMEOUT = 45


def parse_catalog(text: str) -> list[dict]:
    """Every GuestImage entry in the Swift, as a dictionary.

    Split on the constructor rather than parsed as Swift: the table is one
    `GuestImage(...)` per image, and each field inside it has exactly one spelling.
    """
    end = text.find("enum WindowsImageGuidance")
    if end > 0:
        text = text[:end]
    chunks = text.split("GuestImage(")[1:]
    entries = []
    for chunk in chunks:
        entry: dict = {}
        for field, pattern in FIELD_PATTERNS.items():
            match = re.search(pattern, chunk)
            if match:
                entry[field] = match.group(1)
        entries.append(entry)
    return entries


def describe(entry: dict) -> str:
    return entry.get("id") or entry.get("remoteFileName") or "<unnamed>"


def check_table(entries: list[dict], problems: list[str]) -> None:
    seen_ids: set[str] = set()
    seen_remote: set[str] = set()

    for entry in entries:
        name = describe(entry)
        for field in ("id", "kind", "remoteFileName", "storedFileName", "url", "format", "byteCount"):
            if field not in entry:
                problems.append(f"{name}: the entry has no {field}")
        if any(field not in entry for field in ("url", "remoteFileName", "storedFileName", "format", "byteCount")):
            continue

        if entry["id"] in seen_ids:
            problems.append(f"{name}: the id is used twice")
        seen_ids.add(entry["id"])
        if entry["remoteFileName"] in seen_remote:
            problems.append(f"{name}: the remote file name is used twice")
        seen_remote.add(entry["remoteFileName"])

        url = urlparse(entry["url"])
        if url.scheme != "https":
            problems.append(f"{name}: the URL is {url.scheme or 'not'} https")
        if url.path.rsplit("/", 1)[-1] != entry["remoteFileName"]:
            problems.append(
                f"{name}: the table calls the file {entry['remoteFileName']} but the URL publishes "
                f"{url.path.rsplit('/', 1)[-1]}; a checksum list is searched for the table's name")

        stored = entry["storedFileName"].lower()
        fmt = entry["format"]
        expected_suffix = {"iso": ".iso", "qcow2": ".qcow2"}.get(fmt)
        if expected_suffix and not stored.endswith(expected_suffix):
            problems.append(
                f"{name}: recorded as {fmt} but stored as {entry['storedFileName']}; QEMU is told to read it "
                f"as {fmt} from that name")
        if fmt == "raw" and not (stored.endswith(".img") or stored.endswith(".raw")):
            problems.append(f"{name}: recorded as raw but stored as {entry['storedFileName']}")

        size = int(entry["byteCount"].replace("_", ""))
        if size <= 0:
            problems.append(f"{name}: no byte count, so progress cannot be shown")

        if ("checksumURL" in entry) != ("checksumAlgorithm" in entry):
            problems.append(f"{name}: has one of a checksum list and an algorithm without the other")
        if "checksumURL" in entry and urlparse(entry["checksumURL"]).scheme != "https":
            problems.append(f"{name}: the checksum list is not https")


def fetch(url: str, range_only: bool = False) -> tuple[int, dict, bytes]:
    """One request, retried. Returns (status, headers, first bytes)."""
    last: Exception | None = None
    for attempt in range(ATTEMPTS):
        request = urllib.request.Request(url, method="HEAD")
        if range_only:
            request = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 - the URLs are the table's
                headers = {key.lower(): value for key, value in response.headers.items()}
                body = b""
                if range_only:
                    body = response.read(1 << 20)
                return response.status, headers, body
        except urllib.error.HTTPError as error:
            last = error
            if error.code in (405, 501) and not range_only:
                # This server will not answer HEAD; ask for one byte instead.
                return fetch(url, range_only=True)
            if error.code in (429, 500, 502, 503, 504):
                time.sleep(2 * (attempt + 1))
                continue
            return error.code, {}, b""
        except Exception as error:  # noqa: BLE001 - any failure is retried once
            last = error
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{url}: {last}")


def fetch_full(url: str, limit: int = 1 << 20) -> tuple[int, bytes]:
    """A whole response, capped at a megabyte.

    The checksum lists are a few kilobytes, so they are read rather than
    range-requested: a range request for one byte is what the first version of
    this script did, and it then reported every list as not mentioning its own
    file.
    """
    last: Exception | None = None
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as response:  # noqa: S310 - the URLs are the table's
                return response.status, response.read(limit)
        except urllib.error.HTTPError as error:
            return error.code, b""
        except Exception as error:  # noqa: BLE001 - retried, then reported
            last = error
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{url}: {last}")


def check_network(entries: list[dict], verbose: bool) -> list[str]:
    problems: list[str] = []
    for entry in entries:
        name = describe(entry)
        try:
            status, headers, _ = fetch(entry["url"])
        except RuntimeError as error:
            problems.append(f"{name}: {error}")
            continue
        if status != 200:
            problems.append(f"{name}: the image URL answered {status}")
            continue
        recorded = int(entry["byteCount"].replace("_", ""))
        length = headers.get("content-length")
        if length is None:
            problems.append(f"{name}: the image URL answered 200 with no Content-Length, so progress cannot be shown")
        elif int(length) != recorded:
            problems.append(
                f"{name}: the table says {recorded} bytes and the server says {length}; the progress bar is drawn "
                f"from the table")
        if verbose:
            print(f"  image  {name}: 200, {length} bytes")

        if "checksumURL" in entry:
            try:
                status, body = fetch_full(entry["checksumURL"])
            except RuntimeError as error:
                problems.append(f"{name}: checksum list {error}")
                continue
            if status != 200:
                problems.append(f"{name}: the checksum list answered {status}")
                continue
            if entry["remoteFileName"].encode() not in body:
                problems.append(
                    f"{name}: the published checksum list does not mention {entry['remoteFileName']}, so a "
                    f"download would be verified against nothing")
            elif verbose:
                print(f"  sums   {name}: 200, mentions the file")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--offline", action="store_true", help="check the table only, without the network")
    parser.add_argument("--quiet", action="store_true", help="print only problems")
    args = parser.parse_args()

    if not CATALOG.is_file():
        print(f"::error::no catalogue at {CATALOG}", file=sys.stderr)
        return 1

    entries = parse_catalog(CATALOG.read_text(encoding="utf-8"))
    if not entries:
        print("::error::the catalogue parsed as empty; the Swift has probably been renamed", file=sys.stderr)
        return 1

    verbose = not args.quiet
    if verbose:
        print(f"{len(entries)} image(s) in the catalogue")

    problems: list[str] = []
    check_table(entries, problems)
    if not args.offline and not problems:
        problems += check_network(entries, verbose)

    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        print(f"\n{len(problems)} problem(s)")
        return 1

    print(f"the catalogue is consistent{'' if args.offline else ' and every URL, size and checksum list answered'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
