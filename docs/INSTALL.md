# Installing Madeira Next

The app is distributed as an **unsigned** IPA. It must be signed on install with
your own Apple ID; nothing here can be installed as it stands.

## What you get

`MadeiraNext-unsigned.ipa`, produced by `.github/workflows/ios.yml` and published
to the **`ipa-latest` release** of the repository. That release is rewritten by
every green build on `main`, so the assets on it always name the newest one, and
it does not expire. The same build is uploaded as the `MadeiraNext-unsigned-ipa`
artifact, which GitHub deletes after 14 days — the release is the copy to use.

Each release asset carries a companion: `MadeiraNext-unsigned.ipa.sha256` is what
the file hashes to, and `build-info.json` names the commit and the run it was
built from.

The workflow also runs on a nightly `schedule`. That build runs on GitHub's own
runners, not on anyone's laptop, so an IPA keeps being produced while the machine
that asked for one is asleep, closed, or off.

One caveat worth knowing: GitHub disables a scheduled workflow after 60 days with
no repository activity. Any push clears that, and so does starting the workflow by
hand, so it only goes quiet if the repository does.

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

## Getting the IPA again

`dist/` is gitignored (it holds a 43 MB binary), so a downloaded copy is easy to
lose, and a CI artifact expires after 14 days. One command fetches the deliverable
from any checkout, without the web UI:

```sh
python3 tools/fetch_latest_ipa.py                  # newest -> dist/
python3 tools/fetch_latest_ipa.py --require-head    # only for this commit
python3 tools/fetch_latest_ipa.py --source release  # the permanent release only
python3 tools/fetch_latest_ipa.py --wait 60         # poll until a run finishes
```

It needs a token — `GH_TOKEN`, `GITHUB_TOKEN`, or `~/.madeira_push_token` — with
`contents:read` for the release and `actions:read` for the artifact fallback.

By default (`--source auto`) it takes the **release** asset first, because that is
the copy that does not expire, and falls back to the newest unexpired CI artifact
when the release is missing, has no IPA, or — under `--require-head` — was built
from a different commit than this checkout. `--source release` and
`--source artifact` pin one or the other.

It exits 0 **only** when the archive is intact, the engine's dependencies resolve
(`tools/check_ipa_bundle.py`), the firmware is present, the app carries no
signature, and — for a release download — the file's sha256 matches the one the
release publishes. The sha256 is written beside it as
`dist/MadeiraNext-unsigned.ipa.sha256`. Any other exit code means the IPA on disk
was not replaced: 2 for a missing token, 3 for no release or no matching artifact
(with the URL to start a run), 1 for a download that failed verification.

`--wait` is the part worth knowing: the download finishes after whatever started
it is gone, so a fetch launched before an interruption still lands on disk.

`--wait` is the part worth knowing: the download finishes after whatever started
it is gone, so a fetch launched before an interruption still lands on disk.

Nothing here depends on an editing session or on the machine that asked for it.
A green run on `main` is the source of truth; if there is none, push to `main` or
start the `ios` workflow by hand and fetch again.

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