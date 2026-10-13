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
that asked for one is asleep, closed, or off. The same nightly run also starts a
guest: the `boot-smoke` job boots a machine with the argument vector the app's own
code builds, using a host QEMU, and requires it to reach the UEFI shell and then
stop on command. That check covers the recipe, the firmware and the app's own
firmware handling; it cannot load the iOS engine, so nothing there proves the
engine itself, which only a device can. Run 38276446514 was the first run that got
as far as a guest: `UEFI Interactive Shell v2.2`, 65.4s after start. Run
38395227472 did it again in 66.6s, with the argument vector the launcher builds
after it was rewritten for guest kinds and install disks, so the recipe is
re-measured rather than assumed.

The same run's `invariants` job is the cheap half of this: it checks the
entitlements and their build wiring, the Swift's delimiters, and every image URL,
size and checksum list in the catalogue against the servers it names - the check
that caught a Fedora URL which answers 404 from a runner and 200 from elsewhere.

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
| Entitlements | `Payload/MadeiraNext.app/MadeiraNext.entitlements`: the six keys from `App/MadeiraNext.entitlements`. They are not in the signature - there is none - so signing with them is a step you take, see below |
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

## Signing and installingAny sideloading tool can sign and install the IPA, because the file itself is
unsigned. With a free Apple ID, **AltStore** or **Sideloadly** will do it; expect
the usual seven-day certificate, after which the app has to be re-signed.

The one thing not to leave to a tool's defaults is the entitlements - see below.
A tool that strips them produces an app that installs cleanly and is killed the
moment a guest asks for its RAM.

### Sign it with the app's own entitlements

The engine needs four things a sideloading tool will not ask for on its own:
executable memory (`get-task-allow`, `com.apple.security.cs.allow-jit`), a larger
memory limit (`com.apple.developer.kernel.increased-memory-limit`) and more
virtual address space
(`com.apple.developer.kernel.extended-virtual-addressing`). Without the memory
one, a guest's RAM is an allocation iOS can kill the app for halfway through
making it, which looks exactly like a crash: the screen goes away, no message,
nothing in any log.

Those keys are `App/MadeiraNext.entitlements`, and a copy travels inside the IPA
at `Payload/MadeiraNext.app/MadeiraNext.entitlements`. On a Mac, sign with that
file and have the signature checked before you install:

```sh
python3 tools/fetch_latest_ipa.py
tools/sign_ipa.sh dist/MadeiraNext-unsigned.ipa \
  --identity "Apple Development: You (TEAMID1234)"
```

That signs every nested framework, then the app, then reads the entitlements back
out of the signature and refuses to finish if any of the four keys is missing - a
signature without them is an app that installs and cannot run a guest.

**JIT is not required.** The engine in this build interprets guest code instead of
compiling it, so a machine runs with no executable memory at all - and far more
slowly than a JIT would, which is why an installer can take minutes to reach its
first screen. The Diagnostics screen says which situation this process is in, and
it is measured rather than assumed: a `P_TRACED` check on this process and a real
`MAP_JIT` mapping.

## Using it

1. Tap **+** and create a machine: a name, a guest (**Linux** or **Windows
   (ARM64)**), RAM and CPUs. 1024 MB or less is what runs without the memory
   entitlement; more than that is a deliberate choice the Diagnostics screen will
   warn about.
2. Give it a medium, in whichever way suits:
   * **Download a Linux image...** lists six aarch64 images with their real sizes
     and fetches one with a background download: it keeps going while the app is
     closed, is verified against the distribution's own checksum list, and lands
     in the machine's folder. Nothing has to be found on a computer first.
   * **Choose disk image...** takes your own file (`.iso`, `.qcow2`, `.img`,
     `.raw`). It is copied into the app's own storage, and what it is is decided
     by its bytes: a qcow2 image named `.img` is read as qcow2 rather than as raw.
3. If the medium is an installer, make it somewhere to install: **Create install
   disk** makes a sparse 16 GB disk in the machine's folder and attaches it
   beside the ISO. Without it, setup runs and finds nothing to install to.
4. **Start**. The console screen shows the guest's serial output. Windows has no
   downloadable image - the machine's own note says where one comes from and
   which of its installer checks this engine cannot satisfy.

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
| "This build has no engine" | The IPA was packaged without `Frameworks/`; use an artifact from a green run. |
| "No disk image is set for this machine yet" | Pick one with **Choose disk image...** or **Download a Linux image...**. |
| "The image at ... is empty" | The file is zero bytes: the import or download did not finish. |
| "The disk image is no longer at ..." | The machine's copy was removed from the app's storage. |
| "The engine refused to start (exit N)" | QEMU would not take the command line and said so. The app stayed up to show it: the reason is in the console above that line and in `Documents/linux-engine.log`. |
| A note about guest memory in the console | The machine asks for more RAM than an app without `com.apple.developer.kernel.increased-memory-limit` may hold. Sign with `App/MadeiraNext.entitlements`, or give the machine 1024 MB. |
| A QEMU error in the console | The engine's own words. Copy them from `Documents/linux-engine.log`; that file is the reason the app does not vanish silently. |

The **Diagnostics** screen (top left) is the short answer to "why did that not
run": it reports the engine, the firmware, whether executable memory is allowed,
the engine kind, the guest's memory against the limit, and the last engine exit,
then offers the engine log in full.

Nothing here has been run on a device yet. See `docs/ARCHITECTURE.md` for exactly
which checks pass and which have never been exercised.