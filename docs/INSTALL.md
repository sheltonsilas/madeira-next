# Installing Madeira Next

The app is distributed as an **unsigned** IPA. It must be signed on install with
your own Apple ID; nothing here can be installed as it stands.

## What you get

`MadeiraNext-unsigned.ipa`, produced by `.github/workflows/ios.yml` and uploaded
as the `MadeiraNext-unsigned-ipa` artifact on a green run. Download it from the
run's page, or from the Actions tab of the repository.

The build is **device-only** (`LC_BUILD_VERSION` platform `ios`, arm64) and
requires **iOS 17.0** or later.

Verified contents of the packaged IPA:

| Item | Value |
|---|---|
| Bundle identifier | `com.sheltonsilas.madeiranext` |
| Display name | Madeira Next |
| Version | 0.1.0 (1) |
| Device family | iPhone and iPad (`UIDeviceFamily` 1, 2) |
| Linux engine | `Frameworks/qemu-aarch64-softmmu.framework` (55 frameworks) |
| UEFI firmware | `share/qemu/edk2-aarch64-code.fd`, `share/qemu/edk2-arm-vars.fd` |
| Signature | none (`_CodeSignature` and `embedded.mobileprovision` are absent, so the app is ready to re-sign) |

## Signing and installing

Any sideloading tool works, because the app is unsigned and carries no
entitlements of its own. With a free Apple ID, **AltStore** or **Sideloadly**
will sign and install it; expect the usual seven-day certificate, after which
the app has to be re-signed.

The one requirement is **JIT**. The Linux engine is QEMU's TCI interpreter build,
so a machine can boot without any JIT entitlement — but a sideloaded app on iOS
17+ generally runs under a debugger-only policy. If the engine is refused, the
console will say so: the message is captured in the console screen and appended
to `Documents/linux-engine.log`.

## Using it

1. Create a machine (name, RAM, CPUs).
2. **Choose disk image...** and pick a Linux ISO or a disk image (`.iso`,
   `.qcow2`, `.img`, `.raw`). It is copied into the app's own storage.
3. **Start**. The console screen shows the guest's serial output.

A guest boots **headless**: there is no display in the app yet, so the console is
the whole of what you can see. A desktop ISO is the case to watch, because its
installer writes to the serial console; a graphical installer will sit at a blank
`-display none` framebuffer.

To stop a machine, press **Stop**. That sends `quit` to QEMU's own monitor, so
the guest's disk is flushed by QEMU rather than the thread killed.

## If a machine will not start

The app refuses with a sentence rather than crashing, and the console says why.
The messages that matter:

| Message | Meaning |
|---|---|
| "This build has no Linux engine" | The IPA was packaged without `Frameworks/`; use an artifact from a green run. |
| "No disk image is set for this machine yet" | Pick one with **Choose disk image...**. |
| "The disk image is no longer at ..." | The machine's copy was removed from the app's storage. |
| A QEMU error in the console | The engine's own words. Copy them from `Documents/linux-engine.log`; that file is the reason the app does not vanish silently. |

Nothing here has been run on a device yet. See `docs/ARCHITECTURE.md` for exactly
which checks pass and which have never been exercised.