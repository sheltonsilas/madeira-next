# Architecture and source map

This file is the authority for where code in this repository came from, what
builds today, and what is still missing. Nothing copied from another project is
left unlisted.

## Build status (verified)

| Check | Result |
|---|---|
| XcodeGen generates the project from `project.yml` | passes in CI |
| `xcodebuild` builds the `MadeiraNext` target for iOS, signing off | passes in CI (run 38133166284) |
| Unsigned IPA is packaged and its zip is valid | passes; the IPA holds `Payload/MadeiraNext.app` with bundle id `com.sheltonsilas.madeiranext`, `MinimumOSVersion` 17.0 |
| Unit tests (26) pass on an iOS simulator | passes in CI (run 38205810052; the simulator is chosen at run time with `simctl` rather than assuming a device name exists in the image) |
| The QEMU engine and the aarch64 UEFI firmware are in the packaged IPA | passes in CI (run 38142473546): `Frameworks/qemu-aarch64-softmmu.framework` and `share/qemu/edk2-aarch64-code.fd` are in the archive |
| The IPA can load its engine: the engine exports `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and every `@rpath` dependency of all 55 bundled frameworks is in the archive | passes in CI (`tools/check_ipa_bundle.py`, run 38205810052: 55 frameworks, 0 unresolved references, 0 problems). Checked against a sabotaged IPA with glib removed, which it fails with 31 unresolved references. |
| An IPA that can be signed and installed | passes: the artifact is a device-only arm64 app with no signature of its own. **Not installed anywhere**: no Apple ID or device is available here. |
| The IPA is obtainable without this machine | passes and was exercised twice: run 38265087905 published commit `f09384c` to the `ipa-latest` release, then a later push republished `3e90487` over it (run 38266335261) with no manual step, and `tools/fetch_latest_ipa.py --require-head` took that copy and matched the sha256 the release publishes. The nightly `schedule` trigger is committed but has not fired yet, so only the push path is proven |
| A guest boots | **not verified**: the launcher is written and its argument vector is unit-tested, but nothing has loaded the engine or started a guest |
| The app runs on a device or simulator | **not verified**: no iPhone, iPad, or Mac here; the tests run in the simulator, but nothing has been driven through the UI |

The IPA is produced by `.github/workflows/ios.yml` and published to the
`ipa-latest` release, with the same build uploaded as the
`MadeiraNext-unsigned-ipa` artifact. The release is the durable copy: a release
asset does not expire, whereas an artifact is deleted after 14 days. The workflow
also runs on a nightly `schedule`, which is a build on GitHub's runners rather
than on any laptop, so it happens with the machine that asked for it asleep or
off. It is unsigned and must be signed on install; `docs/INSTALL.md` covers
signing it onto a device and what a machine does once it runs.

Run 38211725437 (commit `1b44a36`) produced an IPA that was downloaded and checked
directly: 43,461,166 bytes, sha256
`a29cb5c1a67bfcf8e7cea02263986bddefa52606884c483c0ff1f7ed7bc878ad`, 320 entries,
valid zip, the engine and both firmware files present, `LC_BUILD_VERSION`
platform `ios` (device, not simulator), and no `_CodeSignature` or
`embedded.mobileprovision`, so it is ready to re-sign. `tools/fetch_latest_ipa.py
--require-head` reproduced that file from the run byte-for-byte, which is what
makes a checksum here a claim about the artifact rather than about a copy.

The `publish` job ran for real on commit `f09384c` (run 38265087905) and put a
43,461,166-byte IPA, its sha256
`70582f7ee3812c686206a09a5bd738afb8a8dc5ba8ac5002ec58d364534b0da8`, and a
`build-info.json` naming that commit on the `ipa-latest` release. Fetching at that
commit with `--require-head` then took the release path, and the file it landed
matched the release's published checksum exactly and passed
`tools/check_ipa_bundle.py` (55 frameworks, 0 unresolved references). The first
attempt at this failed at the last step - `gh` had no git remote to infer the
repository from inside a job that never checks the repository out - which is the
kind of failure that leaves a green-looking pipeline with nothing published; the
job now names the repository with `GH_REPO`.

GitHub deletes an artifact 14 days after upload, so a green run is not on its own
a durable deliverable. Two things close that, and both are exercised rather than
assumed: the `publish` job puts the IPA, its sha256 and a `build-info.json` naming
the commit on the non-expiring `ipa-latest` release, and `tools/fetch_latest_ipa.py`
fetches from that release (falling back to the artifacts) and verifies what it got;
`docs/INSTALL.md` has the usage and the exit codes. Neither depends on an editing
session, or on this machine being powered on.

## What the app is today

A SwiftUI app: `App/MadeiraNextApp.swift` shows a list of Linux machines the
user can add, edit and delete. Machines persist to
`Application Support/MadeiraNext/machines.json` (atomic writes; a corrupt file is
reported, never silently discarded). Each machine can be given a disk image from
the Files picker (copied into the machine's own folder, because a
security-scoped URL is only valid for the callback's lifetime) and started.

Starting a machine builds QEMU's argument vector, writes its EFI variables, runs
the engine on its own thread, and shows its serial console, with Stop asking
QEMU's own monitor to quit so the guest's disk is flushed by QEMU itself. The
engine's stdout and stderr are captured into the console and appended to
`Documents/linux-engine.log`, because QEMU answers a command line it cannot use
by printing and calling `exit(1)` — inside this process, the app vanishing with
the reason lost.

**What is still missing**: no display. A guest boots headless and is read over
the console; its framebuffer is not drawn in the app.

Two device-only constraints are written down here because neither is visible in
the simulator. A Unix socket path must fit in `sockaddr_un.sun_path` (104 bytes
on Darwin): an app container spends about 76, and a socket placed beside its
disk image under `Library/Application Support` arrives at roughly 175, at which
point QEMU refuses it and the machine starts with no console and a monitor that
never answers. So the sockets live in a two-character directory at the
container root instead, named after a short tag of the machine's id. And the
firmware's variables bank is extended to the size of the code image, because the
`virt` machine refuses a flash bank shorter than its device.

## Licences

| Scope | Licence | Why |
|---|---|---|
| `upstream/utm/**` (copied) | Apache-2.0, see `upstream/utm/LICENSE` | UTM by osy, <https://github.com/utmapp/UTM> |
| The app's own Swift, the scripts in `tools/`, and the CI workflow | GPL-3.0-or-later, see `COPYING` | `trim-qemu-sysroot.sh` is a copy of Madeira's GPL-3.0-or-later script |

Apache-2.0 code can be used in a GPL-3.0 project, but not the reverse. No code
from Madeira (GPL-3.0) is in this repository.

## Pinned upstream

| Project | Repository | Commit | Licence |
|---|---|---|---|
| UTM | utmapp/UTM | `7eadb056ae0f91d979059544d0ddcd2d5a40be92` (main) | Apache-2.0 |

## Copied from UTM (`upstream/utm/`, unchanged)

Each file keeps its own copyright header.

| Path | Role here |
|---|---|
| `QEMULauncher/Bootstrap.c`, `Bootstrap.h`, `main.c` | dlopen bootstrap for the QEMU shared library (the launch seam) |
| `QEMUHelper/QEMUHelper.m`, `.h`, `main.m` | QEMU helper process; reference for the launch protocol, not used on iOS |
| `Services/UTMQemuSystem.m`, `.h` | QEMU system wrapper (`qemu_init` / `qemu_main_loop`) |
| `Services/UTMQemuImage.swift` | disk image handling |
| `Services/UTMProcess.m`, `.h`, `UTMHelperProcess.swift` | process helpers |
| `Services/UTMLogging*`, `UTMPipeInterface.swift`, `UTMQemuPort.swift` | logging and chardev plumbing |
| `Services/UTMQemuSnapshotBackend.swift`, `Configuration/UTMSnapshotManifest.swift` | snapshot model |
| `Services/UTMExtensions.swift` | helpers |
| `Configuration/QEMU*.swift`, `UTMQemuConfiguration*.swift` | typed QEMU configuration and argument building |
| `Configuration/UTMConfiguration*.swift` | VM configuration model |
| `Configuration/QEMUConstantGenerated.swift` | generated constants (large) |
| `Services/UTMAppleVirtualMachine.swift` | Apple Virtualization backend; reference only, iOS does not have it |

**None of these files is compiled yet.** They are not in the Xcode target.

## Written here

| Component | Status |
|---|---|
| XcodeGen spec and app target (`project.yml`, `App/`) | done, builds in CI |
| Machine list: add, edit, delete, validation, JSON persistence (`App/MachineStore.swift`) | done, unit-tested |
| QEMU engine bundled from the published payload (`tools/fetch-engine.sh`, `tools/trim-qemu-sysroot.sh`) | done in CI: run 38137299749 trims the payload 3,087 MiB to 308 MiB and the IPA contains `Frameworks/qemu-aarch64-softmmu.framework` (55 frameworks). **Not run**: no guest has been started. |
| Engine locator: finds `Frameworks/qemu-aarch64-softmmu.framework` and reports available or missing (`App/EngineLocator.swift`) | done, unit-tested (10 tests pass in run 38134790715) |
| CI workflow (`.github/workflows/ios.yml`) | done, produces an unsigned IPA, and publishes it to the non-expiring `ipa-latest` release on `main`; also runs on a nightly `schedule` on GitHub's runners |
| Firmware bundling: `share/qemu` is copied into the bundle beside `Frameworks/` (`tools/fetch-engine.sh`, `.github/workflows/ios.yml`) | done in CI |
| QEMU launcher: argument vector, firmware and blocker checks, per-machine writable EFI variables (`App/QEMULauncher.swift`) | done; the argument vector, image handling and vars extension are unit-tested |
| Engine loadability check for the packaged IPA (`tools/check_ipa_bundle.py`) | done; run in CI, and verified to fail a sabotaged IPA |
| Recovery of the packaged IPA from CI, checked the same way (`tools/fetch_latest_ipa.py`) | done; from a clean checkout it reproduces run 38211725437's IPA byte-for-byte. It prefers the non-expiring release asset and falls back to artifacts, checking the file against the sha256 the release publishes. Its refusal paths are exercised rather than assumed: exit 2 with no token, and exit 3 with no release or no matching artifact, or when `--require-head` is asked for a commit that has no run |
| Machine runtime: start, stop through QEMU's monitor, the guest's console read from its serial socket, the engine's own output captured to `Documents/linux-engine.log`, disk-image import (`App/MachineRuntime.swift`) | done; vars extension, socket-path headroom and image-name sanitizing are unit-tested. **The engine has never actually been loaded.** |
| Machine UI: Start, Console screen, disk-image picker (`App/MadeiraNextApp.swift`, `App/ConsoleView.swift`) | done, not exercised outside the simulator |
| Guest display (framebuffer into a Metal view) | **not started** |
| Windows engine (Wine/FEX/DXMT) | **not started** |
| Machine import/export and snapshots | not started |

## Remaining work, in order

1. Boot a guest on a device and read its serial console. The launcher and its
   argument vector are written and tested, but nothing has loaded the engine, so
   the first `dlopen` of `qemu-aarch64-softmmu.framework` is still unproven. A
   device is required: the engine is a device-only Mach-O, so the simulator
   cannot exercise it.
2. Draw the guest's framebuffer. Add `-device virtio-gpu-pci`, read its scanout
   and present it in a Metal view; the argument builder and the runtime are the
   places this attaches to. Madeira's Windows side solved this with a Metal host
   view, which is the reference.
3. JIT onboarding (StikDebug, `csops` detection, the onboarding screen). Not
   needed for this engine: the payload is TCG-interpreter-only, so it has no JIT
   to enable. It becomes necessary if a JIT-capable engine is added.
4. The Windows side is a separate effort (Wine, FEX, DXMT), not started.

## Open decisions

- Whether the Windows side reuses Madeira's Wine/FEX/DXMT submodules. Those are
  GPL and LGPL, which is compatible with this repository's GPL-3.0-or-later.
- Whether the guest display uses `virtio-gpu-pci` with a scanout reader (as
  Madeira's Windows side does with MetalHostView) or another path.

## Known risks

- No device or simulator is available here. Nothing is verified on hardware.
- Copying UTM's launcher and configuration code does not make the engine work
  on iOS. Each piece has to be built and checked.
- The iOS app cannot be checked for crashes without a device.

## Third-party code brought in by the engine payload

The engine is not built here. `tools/fetch-engine.sh` downloads Madeira's published `qemu-ios-tci-arm64.tar.gz` payload, which bundles QEMU (GPL-2.0), glib, gstreamer, spice, openssl, and others, each under its own licence. The payload's own licence files (for example `share/qemu/edk2-licenses.txt`, EDK2 firmware under BSD-2-Clause-Patent) are the reference; this repository does not relicense them.

`tools/trim-qemu-sysroot.sh` is a copy of Madeira's `build/ci/trim-qemu-sysroot.sh` (GPL-3.0-or-later, same author), so it is GPL-3.0-or-later like the rest of the app's own code.

## Where the launcher came from

`App/QEMULauncher.swift` and `App/MachineRuntime.swift` are written for this
repository, guided by Madeira's `app/Madeira/Variant/QEMULauncher.swift`
(GPL-3.0-or-later, same author) — the same `dlopen` seam over QEMU's
`qemu_init` / `qemu_main_loop` / `qemu_cleanup`, the same socket-driven console
and monitor, and the same writable-EFI-variables reasoning. They are not copies:
they carry only what this app needs, they take their machine model from
`App/MachineStore.swift` rather than Madeira's `LinuxEnvironment`, and they have
no display path. Madeira's file is the reference for each decision, including
why the framework copy under `Frameworks/` is the loadable one and why the
writable vars image has to be extended to the code image's size.

The licences that apply to the app's own code and to the copied files are in
`COPYING` (GPL-3.0-or-later) and `upstream/utm/LICENSE` (Apache-2.0), and the
engine payload's own licence files are listed above.
