#!/usr/bin/env python3
"""Check that the packaged IPA can actually load its engine.

WHY THIS EXISTS
The engine and its 54 dependency frameworks are Mach-O libraries copied into the
app by the packaging step, not built by Xcode. Nothing in the build resolves
their install names: the app links none of them. So a payload trimmed one
framework too far produces an app that builds, packages, installs, and then dies
inside dyld when Start is pressed - which is exactly the failure this repository
cannot reproduce, because the engine is a device-only binary.

The engine names its dependencies `@rpath/<name>.framework/<name>`, and the app's
only relevant LC_RPATH is `@executable_path/Frameworks`. So each such name has to
be a file at `Frameworks/<name>.framework/<name>` in the bundle, or the load
fails. This checks that, for the engine and for every framework it pulls in.

Exit 0 when every @rpath dependency resolves inside the IPA.

Usage: check_ipa_bundle.py <path-to.ipa>
"""

import plistlib
import re
import struct
import sys
import zipfile

PREFIX = "Payload/MadeiraNext.app/"
FRAMEWORKS = PREFIX + "Frameworks/"
ENGINE = FRAMEWORKS + "qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"

# The entitlements travel inside the IPA, because the file is unsigned: a user
# with no copy of this repository still has to be able to sign with the keys the
# engine needs, and a sideloader's defaults are how an app installs and is then
# killed the moment a guest asks for its RAM.
ENTITLEMENTS = PREFIX + "MadeiraNext.entitlements"
REQUIRED_ENTITLEMENTS = [
    "get-task-allow",
    "com.apple.security.cs.allow-jit",
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing",
]
RTYPE = re.compile(rb"@(rpath|loader_path|executable_path)/[A-Za-z0-9./_+-]+")

# The entry points the launcher resolves with dlsym. QEMU built with
# --enable-shared-lib exports these three and nothing else is needed; a payload
# built without it loads and then fails at the first call site.
ENTRY_POINTS = [b"qemu_init", b"qemu_main_loop", b"qemu_cleanup"]

MACH_MAGICS_64 = (0xFEEDFACF, 0xCFFAEDFE)
LC_SYMTAB = 0x2


def symbol_table_strings(data):
    """The Mach-O string table of a 64-bit image, or None.

    Searching the table for a symbol's name is how the export check stays
    bounded: the table is a few megabytes even in a 197 MB engine, where walking
    every symbol is not.
    """
    if struct.unpack_from("<I", data, 0)[0] not in MACH_MAGICS_64:
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SYMTAB:
            _, _, stroff, strsize = struct.unpack_from("<IIII", data, offset + 8)
            return data[stroff:stroff + strsize]
        if cmdsize == 0:
            return None
        offset += cmdsize
    return None


def framework_binaries(names):
    """The main binary of each .framework in the archive."""
    found = []
    for name in names:
        if not name.startswith(FRAMEWORKS) or ".framework/" not in name:
            continue
        framework, _, inner = name[len(FRAMEWORKS):].partition("/")
        if inner != framework.removesuffix(".framework"):
            continue
        found.append(name)
    return sorted(found)


def main():
    if len(sys.argv) != 2:
        print("usage: check_ipa_bundle.py <path-to.ipa>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    problems = []

    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())

        if ENGINE not in names:
            print(f"the IPA has no engine at {ENGINE}", file=sys.stderr)
            return 1

        engine = archive.read(ENGINE)
        strings = symbol_table_strings(engine)
        if strings is None:
            problems.append("the engine's symbol table could not be read")
        else:
            # C symbols carry the leading underscore the linker adds.
            for entry in ENTRY_POINTS:
                if b"_" + entry + b"\x00" not in strings:
                    problems.append(
                        f"the engine does not export {entry.decode()}: it was "
                        f"probably built without --enable-shared-lib")

        if ENTITLEMENTS not in names:
            problems.append(
                f"the bundle has no {ENTITLEMENTS[len(PREFIX):]} to sign with, so a user "
                f"with only the IPA cannot sign with the keys the engine needs")
        else:
            try:
                keys = plistlib.loads(archive.read(ENTITLEMENTS))
            except Exception as error:  # noqa: BLE001 - any parse failure is the point
                problems.append(f"the bundled entitlements do not parse: {error}")
                keys = {}
            for key in REQUIRED_ENTITLEMENTS:
                if keys.get(key) is not True:
                    problems.append(f"the bundled entitlements are missing {key}")

        # The app's rpath is what makes @rpath mean Frameworks/, so it is the
        # precondition for everything below.
        app_binary = PREFIX + "MadeiraNext"
        if app_binary in names:
            app = archive.read(app_binary)
            if b"@executable_path/Frameworks\x00" not in app:
                problems.append(
                    "the app has no @executable_path/Frameworks rpath, so the "
                    "engine's @rpath dependencies cannot be found")

        frameworks = framework_binaries(names)
        if len(frameworks) < 2:
            problems.append(f"only {len(frameworks)} framework(s) are in the bundle")

        # Every @rpath reference in the engine and in each framework, resolved
        # the way dyld resolves it.
        unresolved = []
        for binary in [ENGINE] + frameworks:
            references = sorted({m.group(0).decode() for m in RTYPE.finditer(archive.read(binary))})
            for target in references:
                if not target.startswith("@rpath/"):
                    # @loader_path and @executable_path from inside a framework
                    # resolve relative to a directory this check does not model;
                    # reported rather than silently passed.
                    unresolved.append((binary, target, "not an @rpath reference"))
                    continue
                resolved = FRAMEWORKS + target[len("@rpath/"):]
                if resolved not in names:
                    unresolved.append((binary, target, resolved))

        if unresolved:
            for binary, target, resolved in unresolved:
                problems.append(
                    f"{binary[len(PREFIX):]} needs {target}, which is not at {resolved}")

    print(f"{path}: {len(frameworks)} framework(s), "
          f"{len(unresolved)} unresolved reference(s), {len(problems)} problem(s)")
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    if problems:
        return 1
    print("the engine exports its entry points and every dependency resolves in the bundle")
    return 0


if __name__ == "__main__":
    sys.exit(main())