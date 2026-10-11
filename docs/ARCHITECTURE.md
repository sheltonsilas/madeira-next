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
| The app runs on a device or simulator | **not verified**: no iPhone, iPad, or Mac here |

The IPA is produced by `.github/workflows/ios.yml` and uploaded as the
`MadeiraNext-unsigned-ipa` artifact. It is unsigned and must be signed on
install.

## What the app is today

A SwiftUI scaffold: `App/MadeiraNextApp.swift` shows a list of Linux machines
with one placeholder entry. Nothing starts a machine yet.

## Licences

| Scope | Licence | Why |
|---|---|---|
| `upstream/utm/**` (copied) | Apache-2.0, see `upstream/utm/LICENSE` | UTM by osy, <https://github.com/utmapp/UTM> |
| Everything else written here | not yet chosen | see Open decisions |

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
| CI workflow (`.github/workflows/ios.yml`) | done, produces an unsigned IPA |
| Linux engine launch layer | **not started**; to be built on the copied UTM files |
| Windows engine (Wine/FEX/DXMT) | **not started** |
| Machine persistence, UI for create/import/export | not started |

## Remaining work, in order

1. Add the copied UTM Swift files to the app target and get them compiling.
   Expect many errors: they target UTM's own types and the Apple
   Virtualization framework, which are not present here.
2. Build a QEMU sysroot for iOS (TCG, aarch64) and load it through the copied
   bootstrap. This is the step the Madeira project spent most of its time on.
3. Boot a guest and read its serial console. Only then build a display.
4. The Windows side is a separate effort (Wine, FEX, DXMT), not started.

## Open decisions

- The licence for code written here (not copied). Madeira's GPL-3.0 would
  apply to the whole repository, including the copied Apache-2.0 files.
- Whether the Windows side reuses Madeira's Wine/FEX/DXMT submodules. Those are
  GPL and LGPL, so reusing them fixes the licence.

## Known risks

- No device or simulator is available here. Nothing is verified on hardware.
- Copying UTM's launcher and configuration code does not make the engine work
  on iOS. Each piece has to be built and checked.
- The iOS app cannot be checked for crashes without a device.
