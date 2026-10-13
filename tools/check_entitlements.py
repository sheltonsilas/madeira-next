#!/usr/bin/env python3
"""Check the invariants that decide whether a guest can run at all.

WHY THIS EXISTS
The engine needs executable memory, more virtual address space than an
unentitled app gets, and a larger memory limit; the app needs to survive QEMU
calling exit(1). Each of those is one file and one build setting, and each of them
is invisible until a device is in hand - a sideloaded app with no entitlements
installs perfectly and dies on Start. This gate is seconds long and fails loudly
if any of them is dropped, which is the usual reason "the app installed but
nothing runs".

It reads the files; it does not sign anything. The signature itself is checked in
CI on macOS, where `codesign` exists, and by tools/sign_ipa.sh on the machine that
installs the app.

Exit 0 only when every one of those pieces is present and wired up.
"""

from __future__ import annotations

import argparse
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

ENTITLEMENTS = ROOT / "App" / "MadeiraNext.entitlements"
BRIDGING_HEADER = ROOT / "App" / "MadeiraNext-Bridging-Header.h"
EXIT_GUARD = ROOT / "App" / "EngineExitGuard.c"
PROJECT = ROOT / "project.yml"
SIGN_SCRIPT = ROOT / "tools" / "sign_ipa.sh"

# The keys without which the app cannot run a guest on a device, and why each is
# required rather than merely useful.
REQUIRED = {
    "com.apple.security.cs.allow-jit": "the MAP_JIT mapping the engine's JIT needs",
    "com.apple.developer.kernel.increased-memory-limit": "a guest's RAM as one allocation",
    "com.apple.developer.kernel.extended-virtual-addressing": "one address space for guest RAM and translation buffers",
    "get-task-allow": "executable memory at all, which iOS only grants to a debuggable process",
}


def fail(problems: list, path: pathlib.Path, message: str) -> None:
    problems.append(f"::error file={path.relative_to(ROOT)}::{message}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--quiet", action="store_true", help="print only problems")
    args = parser.parse_args()

    problems: list[str] = []

    # 1. The entitlements file parses, and carries the keys that matter.
    if not ENTITLEMENTS.is_file():
        fail(problems, ENTITLEMENTS, "the entitlements file is missing: the app would be signed without any of the keys below")
    else:
        try:
            keys = plistlib.loads(ENTITLEMENTS.read_bytes())
        except Exception as error:  # noqa: BLE001 - any parse failure is the point
            fail(problems, ENTITLEMENTS, f"the entitlements plist does not parse: {error}")
            keys = {}
        for key, why in REQUIRED.items():
            if keys.get(key) is not True:
                fail(problems, ENTITLEMENTS, f"missing entitlement {key} ({why})")
        if not args.quiet and not problems:
            print(f"entitlements: {len(keys)} keys, all {len(REQUIRED)} required ones present")

    # 2. The build is actually told to use it, and to compile the exit guard.
    if not PROJECT.is_file():
        fail(problems, PROJECT, "project.yml is missing")
    else:
        text = PROJECT.read_text(encoding="utf-8")
        for needle, why in {
            "CODE_SIGN_ENTITLEMENTS: App/MadeiraNext.entitlements": "the target would be built without the entitlements file",
            "SWIFT_OBJC_BRIDGING_HEADER: App/MadeiraNext-Bridging-Header.h": "the exit guard's C functions would not be visible to Swift",
            "MadeiraNext.entitlements": "the entitlements file must be excluded from the copy-resources phase",
        }.items():
            if needle not in text:
                fail(problems, PROJECT, f"project.yml does not contain {needle!r}: {why}")
        if "path: App" not in text:
            fail(problems, PROJECT, "project.yml has no App source path, so the app's Swift and the exit guard are not compiled at all")

    # 3. The pieces the app's own Swift refers to exist.
    for path, why in (
        (EXIT_GUARD, "the exit interposer: without it QEMU's exit(1) terminates the whole app"),
        (BRIDGING_HEADER, "the declarations Swift needs to arm the exit guard"),
    ):
        if not path.is_file():
            fail(problems, path, f"{path.name} is missing: {why}")

    # 4. The C guard and the Swift side agree on the names that cross the boundary,
    #    which is the one thing here a compiler would not catch across languages.
    if EXIT_GUARD.is_file() and BRIDGING_HEADER.is_file():
        guard = EXIT_GUARD.read_text(encoding="utf-8")
        header = BRIDGING_HEADER.read_text(encoding="utf-8")
        for name in ("madeira_engine_guard_arm", "madeira_engine_guard_disarm", "madeira_engine_guard_armed"):
            if name not in guard or name not in header:
                fail(problems, EXIT_GUARD, f"{name} is declared in one of {EXIT_GUARD.name} and {BRIDGING_HEADER.name} but not the other")
        if "madeira_engine_noted_exit" not in guard:
            fail(problems, EXIT_GUARD, "the guard does not call madeira_engine_noted_exit, so nothing would be reported when the engine gives up")
        swift = ROOT / "App" / "EngineExitGuard.swift"
        if swift.is_file() and '@_cdecl("madeira_engine_noted_exit")' not in swift.read_text(encoding="utf-8"):
            fail(problems, swift, "EngineExitGuard.swift does not define madeira_engine_noted_exit with @_cdecl, which is the name the C guard calls")

    # 5. The signing helper exists, and signs with the same file the build uses.
    if not SIGN_SCRIPT.is_file():
        fail(problems, SIGN_SCRIPT, "tools/sign_ipa.sh is missing: a sideloader that strips entitlements is exactly how the app installs and cannot run")
    else:
        text = SIGN_SCRIPT.read_text(encoding="utf-8")
        if "MadeiraNext.entitlements" not in text:
            fail(problems, SIGN_SCRIPT, "sign_ipa.sh does not pass --entitlements App/MadeiraNext.entitlements")
        if "codesign --verify" not in text and "--verify" not in text:
            fail(problems, SIGN_SCRIPT, "sign_ipa.sh signs but never verifies the result")
        if "set -euo pipefail" not in text:
            fail(problems, SIGN_SCRIPT, "sign_ipa.sh does not use set -euo pipefail, so a failed codesign could be missed")

    if problems:
        for problem in problems:
            print(problem)
        print(f"\n{len(problems)} problem(s)")
        return 1

    if not args.quiet:
        print("entitlements, project wiring and the exit guard are all in place")
    return 0


if __name__ == "__main__":
    sys.exit(main())
