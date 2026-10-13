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
| Unit tests (86) pass on an iOS simulator | passes in CI (run 38395227472, 86 tests, 0 failures; the simulator is chosen at run time with `simctl` rather than assuming a device name exists in the image). Up from 27: the launcher's two guest kinds, the image catalogue, the downloader's checksum handling, the JIT and memory reasoning and the media helpers are all covered |
| The QEMU engine and the aarch64 UEFI firmware are in the packaged IPA | passes in CI (run 38142473546): `Frameworks/qemu-aarch64-softmmu.framework` and `share/qemu/edk2-aarch64-code.fd` are in the archive |
| The IPA can load its engine: the engine exports `qemu_init`, `qemu_main_loop`, `qemu_cleanup`, and every `@rpath` dependency of all 55 bundled frameworks is in the archive | passes in CI (`tools/check_ipa_bundle.py`, run 38205810052: 55 frameworks, 0 unresolved references, 0 problems). Checked against a sabotaged IPA with glib removed, which it fails with 31 unresolved references. |
| An IPA that can be signed and installed | passes: the artifact is a device-only arm64 app with no signature of its own. **Not installed anywhere**: no Apple ID or device is available here. |
| The IPA is obtainable without this machine | passes and was exercised twice: run 38265087905 published commit `f09384c` to the `ipa-latest` release, then a later push republished `3e90487` over it (run 38266335261) with no manual step, and `tools/fetch_latest_ipa.py --require-head` took that copy and matched the sha256 the release publishes. The nightly `schedule` trigger is committed but has not fired yet, so only the push path is proven |
| The boot recipe starts a guest | passes three times, most recently after the launcher was rewritten for guest kinds: runs 38276446514, 38277229801 and 38395227472 ran the argument vector the app's own builder produces under a host QEMU, and each guest reached `UEFI Interactive Shell v2.2` and `UEFI v2.70 (EDK II, 0x00010000)` - in 65.4s, 66.8s and 66.6s - then quit through the monitor with status 0. The last one booted the rewritten vector (a disk attached as `-drive ...,if=none` plus `-device virtio-blk-pci`), so the change is covered by a boot rather than by reading. It is the recipe, the firmware and the bundle layout that are verified here, not the engine: a device-only framework cannot be loaded on a runner. |
| The entitlements the engine needs survive a signature | passes in CI (run 38395227472): a copy of the packaged app is signed ad-hoc with `App/MadeiraNext.entitlements`, and `codesign -d --entitlements :-` on the result shows `get-task-allow`, `com.apple.security.cs.allow-jit`, `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing`. `tools/check_entitlements.py` checks the same file, its build wiring and the exit guard in seconds on Linux, and fails if any of them is dropped |
| Every image the app offers is really there, the size it says, and covered by a checksum list | passes in CI (run 38395227472): `tools/check_image_catalog.py` asked Ubuntu's and Debian's servers about all six images and every checksum list; each answered 200 with the byte count the table records. It failed the first time it ran - on a Fedora URL that answered 404 from a GitHub runner while answering 200 from here minutes earlier, which is why Fedora is not in the table and the reason is written down in `App/ImageCatalog.swift` |
| A guest boots inside the app | **not verified**: nothing has ever `dlopen`ed the engine, so the engine's own load path and the app's boot remain unexercised. The recipe under them is now verified |
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

## Booting a guest, nightly

The `boot-smoke` job is the only one here that runs a guest, and unlike packaging
it can fail because the boot recipe itself is wrong. It is the answer to "does a
machine start" that does not depend on this laptop: the job runs on GitHub's
runners, on the same nightly `schedule` as the IPA, so the question is asked again
by a machine that never sleeps. What is verified is the job itself - three real
runs, one of which failed for the right reason and two of which booted, in 65.4s
and 66.8s, with the same firmware hash both times - not the clock: as noted above,
the schedule has not fired yet.

The argument vector is not written down twice. `tools/boot_smoke.py` reads it out
of the launch test's log - `testArgumentVectorForTheBootSmoke` prints the output of
the real `QEMUArguments.build` between two markers - rewrites the test's
`/MADEIRA_SMOKE` paths onto a real machine folder, and starts a host QEMU with it.
A boot passes only when the guest reaches its firmware shell *and* then stops on
command through the monitor socket, which is the same interface the app uses to
stop a machine. Everything the vector names has to exist before it is started, so
a vector that has drifted from the folder the script builds is a failure rather
than a boot of something else.

The job's first real result was a failure, which is what the check is for: the
script had copied the bundle's `edk2-arm-vars.fd` template (329,216 bytes) straight
into the writable slot, and QEMU refused the machine outright - "cfi.pflash01
device '/machine/virt.flash1' requires 67108864 bytes, pflash1 block backend
provides 329216 bytes". The app already knew this and pads the template to the code
image's size (`WritableFirmwareVars`, with a test); the mirror was wrong, not the
app. The script now makes that file the same way, and the second run booted.
On the runner the bank it built was 67,108,864 bytes from a 329,216-byte template.

The firmware bytes are the payload's own: the job fetches them with
`tools/fetch-engine.sh --share-only`, which takes the same release asset the
packaged app ships from, and `trim-qemu-sysroot.sh` deletes firmware for other
machines while leaving this pair. The code image booted in run 38276446514 hashes
to `ee769c4bf42a5350d33345fc1b16d00156fe0c25fb3c68debd003bd844e4e3fa`.

**What this does not prove.** A runner cannot load the iOS engine framework, so
the engine's `dlopen`, its 55 dependencies and the app's own boot path are still
only exercised on a device. Nor is it shown that a UEFI variable written by one
boot is still there on the next one: the bank is writable and a machine reuses its
own file, but no run has yet started a guest twice and compared. And a guest that
reaches its firmware shell is a machine that starts; it is not a Linux that boots,
because nothing has installed one.

## Why pressing Start used to take the app with it

Four causes, and they look identical from the outside: the app is open, a machine
is selected, Start is pressed, and there is no app any more. Each was addressed
where it starts rather than where it shows.

1. **The engine called `exit(1)`.** QEMU answers a command line it will not take
   by printing to stderr and exiting, and inside a process that has `dlopen`ed it
   that exit is the whole app - no window, no message, and the reason flushed out
   with it. `App/EngineExitGuard.c` interposes `exit` through
   `DYLD_INTERPOSE`, and when the caller is the thread the engine is running on it
   records the status and ends *that thread* with `pthread_exit` instead. The app
   stays up and says what happened; anything else that exits the process still
   does, unchanged.
2. **The system killed the app for its guest's RAM.** A guest's memory is one
   large allocation inside this process, and the app shipped with no entitlements
   at all. `App/MadeiraNext.entitlements` now carries
   `com.apple.developer.kernel.increased-memory-limit`,
   `com.apple.developer.kernel.extended-virtual-addressing`,
   `com.apple.security.cs.allow-jit`, `get-task-allow` and a library-validation
   exemption; `tools/sign_ipa.sh` signs with that file and verifies the keys land
   in the signature; and the diagnostics screen measures the guest size against
   the limit and says so before Start rather than after.
3. **Nothing said what the process was allowed to do.** `App/JITStatus.swift`
   takes two real measurements - `P_TRACED` on this process, and whether a
   `MAP_JIT` page can be mapped and marked executable - and the app shows them,
   with the engine kind spelt out: this engine interprets, so a slow first boot is
   expected rather than a fault, and no JIT entitlement is needed to run a guest.
4. **An ISO was attached without a disk to install to, or a file name QEMU could
   not read.** An installer with no install disk runs and finds nothing; a qcow2
   image named `.img` is read as raw and never boots; and a path containing a
   comma cannot be written on a `-drive` line at all, because its option string
   has no escape for one. The launcher now makes the format decision from the
   file's own bytes, creates an install disk from the machine's menu, warns in the
   console when an installer has nowhere to go, and uses `-blockdev` with JSON for
   the paths `-drive` cannot name.

**What none of that proves.** The interposer is the one piece here that nothing
on a runner can exercise: only a device can show it catching a real `exit`. The
JIT probes answer on the simulator and are unit-tested through a pure decision
function, but the value they return on a real device - and what a sideloader's
signature does to the entitlements - has not been seen. The installable IPA has
never been installed. What is verified is the argument vector (booted nightly),
the entitlements (signed and read back), the catalogue (asked of the servers) and
the reasoning (tested).

## What the app is today

A SwiftUI app: `App/MadeiraNextApp.swift` shows a list of machines the user can
add, edit and delete, each **Linux** or **Windows (ARM64)**. Machines persist to
`Application Support/MadeiraNext/machines.json` (atomic writes; a corrupt file is
reported, never silently discarded; a field added since is decoded with a default,
so an older file still loads). A machine can be given an image from the Files
picker (copied into the machine's own folder, because a security-scoped URL is
only valid for the callback's lifetime), downloaded inside the app, or pointed at
a blank install disk it makes itself.

Starting a machine builds QEMU's argument vector, writes its EFI variables, runs
the engine on its own thread, and shows its serial console, with Stop asking
QEMU's own monitor to quit so the guest's disk is flushed by QEMU itself. The
engine's stdout and stderr are captured into the console and appended to
`Documents/linux-engine.log`, because QEMU answers a command line it cannot use
by printing and calling `exit(1)` — inside this process, the app vanishing with
the reason lost, which is what `App/EngineExitGuard.c` now prevents. Every start
begins by printing what the build knows about itself (engine, firmware,
executable memory, guest, medium) so a failure is read with the facts in front of
it.

**Images come from the app.** `App/ImageCatalog.swift` lists six aarch64 images -
Ubuntu 24.04 cloud (minimal and server), Ubuntu 24.04 live-server and desktop
ISOs, and Debian 13 and 12 cloud - with the exact URL, byte count and published
checksum list for each. `App/ImageDownloader.swift` fetches one with a background
`URLSession`, which is what keeps several gigabytes moving while the app is
suspended or closed, verifies it against the distribution's own `SHA256SUMS` or
`SHA512SUMS`, and moves it into the machine's folder; a download that finishes
with no view on screen is adopted on the next launch. Windows has no such entry
and says why instead - `WindowsImageGuidance` - because Microsoft publishes no
downloadable Windows ARM64 ISO.

**What is still missing**: no display. A guest boots headless and is read over
the console; its framebuffer is not drawn in the app. And no Wine: running
Windows *applications* is Madeira's Wine/FEX path, and nothing of it is here - a
Windows machine is a Windows guest under this same engine.

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
| Entitlements for JIT, kernel memory and library validation (`App/MadeiraNext.entitlements`), and the signing helper that puts them in a signature (`tools/sign_ipa.sh`) | done: CI signs a copy of the packaged app and reads the keys back out of the signature (run 38395227472), and `tools/check_entitlements.py` fails if the file, the build setting or the exit guard goes missing. The shipped IPA is still unsigned, so what a sideloader does with it is unverified |
| Engine exit guard: `exit` interposed so QEMU's `exit(1)` ends only its own thread (`App/EngineExitGuard.c`, `App/EngineExitGuard.swift`) | written and wired into the launcher, with the bookkeeping around it unit-tested. **Not exercised**: only a device can show it catching a real exit |
| Diagnostics: real probes for executable memory, guest memory against what iOS allows, the engine kind, and the last engine exit (`App/JITStatus.swift`, `App/DiagnosticsView.swift`) | done; the decision table and every message are unit-tested, and the screen takes its measurements on the simulator. What a device returns is unverified |
| Image catalogue and downloader (`App/ImageCatalog.swift`, `App/ImageDownloader.swift`) | done; every URL, size and checksum list is re-checked against the servers on every CI run, and the checksum parsing and hashing are unit-tested. **No download has been made from a device** |
| Guest kinds and their devices (`GuestKind` in `App/MachineStore.swift`, `QEMUArguments` in `App/QEMULauncher.swift`) | done; both guests' argument vectors are unit-tested and the Linux one is booted nightly. A Windows install has never been attempted, and the guidance screen says what it needs (a UUP dump, the TPM and Secure Boot bypass, and an install disk) |
| Media handling: the format read from the file's own bytes, a sparse install disk, an adopted download, and names cleaned of what QEMU cannot read (`App/MachineRuntime.swift`) | done, unit-tested |
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
3. Install the IPA on a device and press Start. That is the only check left for
   the four failures in the section above: the exit guard catching a real `exit`,
   the entitlement file surviving a sideloader, a guest's RAM being allocated at
   all, and what the JIT probes answer on hardware. Nothing on a runner can stand
   in for it, and the diagnostics screen is written so the answer is readable when
   someone does.
4. JIT *enabling* (StikDebug, `csops`, an onboarding screen). Not needed for this
   engine: the payload is TCG-interpreter-only, so there is no JIT to turn on, and
   the status screen that says so is written. It becomes necessary only if a
   JIT-capable engine is added.
5. The Windows *applications* side is a separate effort (Wine, FEX, DXMT), not
   started. A Windows guest is not that: it is the same engine with devices
   Windows has drivers for.

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
