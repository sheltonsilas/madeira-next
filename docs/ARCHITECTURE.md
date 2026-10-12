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
| Unit tests (24) pass on an iOS simulator | passes in CI (run 38204478113; the simulator is chosen at run time with `simctl` rather than assuming a device name exists in the image) |
| The QEMU engine and the aarch64 UEFI firmware are in the packaged IPA | passes in CI (run 38142473546): `Frameworks/qemu-aarch64-softmmu.framework` and `share/qemu/edk2-aarch64-code.fd` are in the archive |
| The IPA can load its engine: the engine exports `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and every `@rpath` dependency of all 55 bundled frameworks is in the archive | passes in CI (`tools/check_ipa_bundle.py`, run 38204478113: 55 frameworks, 0 unresolved references, 0 problems). Checked against a sabotaged IPA with glib removed, which it fails with 31 unresolved references. |
| A guest boots | **not verified**: the launcher is written and its argument vector is unit-tested, but nothing has loaded the engine or started a guest |
| The app runs on a device or simulator | **not verified**: no iPhone, iPad, or Mac here; the tests run in the simulator, but nothing has been driven through the UI |

The IPA is produced by `.github/workflows/ios.yml` and uploaded as the
`MadeiraNext-unsigned-ipa` artifact. It is unsigned and must be signed on
install.

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
| CI workflow (`.github/workflows/ios.yml`) | done, produces an unsigned IPA |
| Firmware bundling: `share/qemu` is copied into the bundle beside `Frameworks/` (`tools/fetch-engine.sh`, `.github/workflows/ios.yml`) | done in CI |
| QEMU launcher: argument vector, firmware and blocker checks, per-machine writable EFI variables (`App/QEMULauncher.swift`) | done; the argument vector, image handling and vars extension are unit-tested |
| Engine loadability check for the packaged IPA (`tools/check_ipa_bundle.py`) | done; run in CI, and verified to fail a sabotaged IPA |
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
