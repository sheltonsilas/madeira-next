#!/usr/bin/env python3
"""Boot a guest with the argument vector the app itself builds.

WHY THIS EXISTS
Everything else in this repository checks packaging. Nothing checked the boot
recipe, and the boot recipe is the part that cannot be checked by reading: does
`-M virt -accel tcg,thread=single -cpu max` with this firmware pair, a pflash
code image, a writable vars image and a virtio disk actually reach a running
guest? That question is answerable on any machine with QEMU installed, which
means it is answerable on a scheduled CI runner while the laptop that asked for
it is asleep - and it is the cheapest useful step towards the one thing nobody
here has seen: a loaded engine.

The argument vector is not written here. It is produced by the real
`QEMUArguments.build` in the app (Tests/QEMULauncherTests.swift prints it between
markers), so this script boots what the app would boot rather than a second copy
of the same strings that drifts. The test's paths are under /MADEIRA_SMOKE and
are rewritten to this run's working directory, which is the only thing the script
changes about them.

It is honest about what it does and does not prove. It loads a host QEMU, not the
iOS engine framework: an iOS device binary cannot be dlopened on the runner, so
the claim it supports is about the recipe, the firmware and the machine layout.
The engine's own load path is still only exercised on a device.

Usage:
    python3 tools/boot_smoke.py --log test.log --firmware-dir Engine/share \\
        --work /tmp/smoke
    python3 tools/boot_smoke.py --log test.log --firmware-dir Engine/share \\
        --work /tmp/smoke --dry-run

Exit 0 only when a guest booted to its UEFI shell and then quit cleanly through
the monitor socket, the same way the app's machine runtime talks to it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import time

# The prefix the Swift test builds its paths under. Kept in one place, here and
# in Tests/QEMULauncherTests.swift, because it is the interface between them.
PLACEHOLDER = "/MADEIRA_SMOKE"
BEGIN = "MADEIRA-ARGV-BEGIN"
END = "MADEIRA-ARGV-END"

# A disk with nothing bootable on it: the firmware gets as far as its own shell,
# which is what "a guest started" means without a distribution to install.
DISK_BYTES = 64 * 1024 * 1024

# What a booted AAVMF guest prints. Both have to appear: the first says the
# firmware ran at all, the second that it got all the way to an interactive
# shell rather than stopping at a boot failure.
FIRMWARE_MARKER = re.compile(r"uefi", re.IGNORECASE)
SHELL_MARKER = re.compile(r"Shell>\s*$|Startup\.nsh", re.IGNORECASE | re.MULTILINE)

EXIT_BOOTED = 0
EXIT_NO_GUEST = 1
EXIT_INPUT = 2
EXIT_NO_ARGV = 3


def read_argv(log_path: pathlib.Path) -> list:
    """The argument vector between the markers in an xcodebuild log.

    The JSON is located by its opening bracket rather than by the marker's own
    line, so a log that prefixes test output with something still parses.
    """
    text = log_path.read_text(errors="replace")
    start = text.find(BEGIN)
    if start < 0:
        raise ValueError(
            f"{log_path} has no {BEGIN} marker: run the launch test with "
            f"-only-testing:MadeiraNextTests/QEMULauncherTests/testArgumentVectorForTheBootSmoke")
    bracket = text.find("[", start)
    if bracket < 0:
        raise ValueError(f"{log_path} has {BEGIN} but no JSON after it")
    argv, _ = json.JSONDecoder().raw_decode(text[bracket:])
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) for item in argv):
        raise ValueError(f"{log_path}: the vector is {type(argv).__name__}, not a list of strings")
    return argv


def rewrite(argv: list, work: pathlib.Path) -> list:
    """Point the app's placeholder paths at this run's working directory.

    as_posix() rather than str(): on a POSIX runner they are the same string, and
    on any other host the substituted path keeps one separator, so this logic can
    be dry-run wherever a checkout happens to be rather than only on the runner.
    """
    return [item.replace(PLACEHOLDER, work.as_posix()) for item in argv]


def digest(path: pathlib.Path) -> str:
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            sha.update(chunk)
    return sha.hexdigest()


def prepare(work: pathlib.Path, firmware_dir: pathlib.Path, argv: list) -> dict:
    """Build the machine's folder, matching the layout the app ships.

    `share/qemu` is where the app keeps its firmware inside the bundle and what
    the launcher points `-L` at, so the smoke reproduces that layout rather than
    pointing at wherever the payload happens to be. The firmware files are the
    payload's own bytes, which are also the bytes inside the IPA.
    """
    code = firmware_dir / "qemu" / "edk2-aarch64-code.fd"
    varstore = firmware_dir / "qemu" / "edk2-arm-vars.fd"
    for path in (code, varstore):
        if not path.is_file():
            raise FileNotFoundError(f"no firmware at {path}: pass --firmware-dir <dir holding qemu/>")

    work.mkdir(parents=True, exist_ok=True)
    share_qemu = work / "share" / "qemu"
    share_qemu.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(code, share_qemu / code.name)
    shutil.copyfile(varstore, share_qemu / varstore.name)

    # UEFI writes its variables, so the varstore has to be a fresh writable copy
    # rather than the readonly payload file. It is recreated each run so a pass
    # never depends on state left by an earlier one.
    efi_vars = work / "efi-vars.fd"
    efi_vars.unlink(missing_ok=True)
    shutil.copyfile(varstore, efi_vars)

    disk = work / "disk.raw"
    if not disk.exists():
        with open(disk, "wb") as handle:
            handle.truncate(DISK_BYTES)

    # The vector has to name these paths, or the smoke is not booting the layout
    # it just built - which would make a green result mean nothing. The readonly
    # varstore is deliberately not in the list: the builder passes the writable
    # copy in the machine's folder and never names the payload file, so requiring
    # it here would fail on a correct vector. It is still copied, because the
    # bundle ships the pair and the launcher checks for both.
    expected = [share_qemu / code.name, efi_vars, disk]
    joined = "\n".join(argv)
    missing = [path.as_posix() for path in expected if path.as_posix() not in joined]
    if missing:
        raise ValueError(
            "the argument vector does not mention the files this run prepared, so the "
            "test's placeholder layout and this script's have drifted apart: "
            + ", ".join(missing))

    return {"code": code, "varstore": varstore, "disk": disk}


def wait_for_socket(path: pathlib.Path, process: subprocess.Popen, timeout: float) -> None:
    """Wait for QEMU to listen, failing as soon as it dies instead of waiting out."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited with {process.returncode} before {path} appeared")
        time.sleep(0.025)
    raise TimeoutError(f"{path} never appeared")


def collect_console(path: pathlib.Path, process: subprocess.Popen, timeout: float) -> tuple:
    """Read the guest's serial output until it reaches its shell.

    Connecting as soon as the socket exists matters: a socket chardev has nowhere
    to put output written before a client arrives, so the firmware's first lines
    are the ones a late connection loses.
    """
    deadline = time.monotonic() + timeout
    transcript = bytearray()
    reached_shell = False
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(path))
        connection.settimeout(1.0)
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(1 << 16)
            except socket.timeout:
                chunk = b""
            if chunk:
                transcript += chunk
                text = transcript.decode("utf-8", "replace")
                if FIRMWARE_MARKER.search(text) and SHELL_MARKER.search(text):
                    reached_shell = True
                    break
            elif process.poll() is not None:
                break
    return bytes(transcript), reached_shell


def quit_through_monitor(path: pathlib.Path, process: subprocess.Popen, timeout: float) -> int:
    """Ask the guest to stop the way the app would, then wait for it to exit."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(path))
        connection.sendall(b"quit\n")
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=30)
        return -1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--log", type=pathlib.Path,
                        help="xcodebuild log holding the app's argument vector")
    source.add_argument("--argv-json", type=pathlib.Path,
                        help="a file holding that vector instead")
    parser.add_argument("--work", type=pathlib.Path, default=pathlib.Path("smoke"),
                        help="the machine's folder: rewritten placeholder paths land here")
    parser.add_argument("--firmware-dir", type=pathlib.Path, default=pathlib.Path("Engine/share"),
                        help="a directory holding qemu/edk2-aarch64-code.fd and qemu/edk2-arm-vars.fd")
    parser.add_argument("--qemu", default="qemu-system-aarch64",
                        help="the QEMU binary to run the vector with")
    parser.add_argument("--boot-timeout", type=float, default=300.0,
                        help="seconds to wait for the guest to reach its shell")
    parser.add_argument("--dry-run", action="store_true",
                        help="rewrite the paths and report, without starting QEMU")
    args = parser.parse_args()

    try:
        argv = read_argv(args.log) if args.log else json.loads(args.argv_json.read_text())
    except (OSError, ValueError) as error:
        print(f"cannot read the argument vector: {error}", file=sys.stderr)
        return EXIT_NO_ARGV

    if not any(PLACEHOLDER in item for item in argv):
        print(f"the argument vector has no {PLACEHOLDER} paths, so it was not built by "
              f"the launch test", file=sys.stderr)
        return EXIT_NO_ARGV

    work = args.work.resolve()
    rewritten = rewrite(argv, work)
    try:
        files = prepare(work, args.firmware_dir.resolve(), rewritten)
    except (OSError, ValueError) as error:
        print(f"cannot prepare the machine: {error}", file=sys.stderr)
        return EXIT_INPUT

    print(f"machine folder: {work}")
    print(f"firmware code:  {files['code']} sha256 {digest(files['code'])}")
    print(f"firmware vars:  {files['varstore']} sha256 {digest(files['varstore'])}")
    print(f"command: {' '.join(rewritten)}")
    if args.dry_run:
        print("dry run: the vector rewrites onto files that exist; QEMU was not started")
        return EXIT_BOOTED

    for stale in (work / "console.sock", work / "monitor.sock"):
        stale.unlink(missing_ok=True)

    log_path = work / "qemu.log"
    with open(log_path, "wb") as log:
        process = subprocess.Popen(rewritten, stdout=log, stderr=subprocess.STDOUT,
                                   cwd=str(work))
        started = time.monotonic()
        try:
            wait_for_socket(work / "console.sock", process, 60.0)
            transcript, reached_shell = collect_console(work / "console.sock", process,
                                                        args.boot_timeout)
        except (OSError, RuntimeError, TimeoutError) as error:
            process.kill()
            process.wait(timeout=30)
            print(f"the guest did not start: {error}", file=sys.stderr)
            _report(transcript=None, log_path=log_path, elapsed=time.monotonic() - started)
            return EXIT_NO_GUEST

        elapsed = time.monotonic() - started
        text = transcript.decode("utf-8", "replace")
        if not reached_shell:
            print("the guest never reached its UEFI shell", file=sys.stderr)
            _report(transcript=text, log_path=log_path, elapsed=elapsed)
            return EXIT_NO_GUEST

        code = quit_through_monitor(work / "monitor.sock", process, 60.0)
        print(f"booted to the UEFI shell in {elapsed:.1f}s and quit through the monitor "
              f"with status {code}")
        _report(transcript=text, log_path=log_path, elapsed=elapsed)
        # A guest that boots and then will not stop on command is not a passing
        # machine: the app stops its guests the same way.
        return EXIT_BOOTED if code == 0 else EXIT_NO_GUEST


def _report(transcript: str | None, log_path: pathlib.Path, elapsed: float) -> None:
    """Print what the guest said, so a failure can be read rather than guessed."""
    print(f"--- serial, {len(transcript or '')} characters over {elapsed:.1f}s ---")
    if transcript:
        print(transcript)
    else:
        print("(nothing arrived on the console socket)")
    print(f"--- QEMU's own log, {log_path} ---")
    try:
        tail = log_path.read_text(errors="replace").splitlines()[-30:]
        print("\n".join(tail) if tail else "(QEMU wrote nothing)")
    except OSError as error:
        print(f"(unreadable: {error})")


if __name__ == "__main__":
    sys.exit(main())
