#!/usr/bin/env bash
#
# fetch-engine.sh - put the QEMU engine into the app bundle's Frameworks/.
#
# The engine is a published payload, not something this repository builds: it
# is the iOS QEMU sysroot that Madeira's CI publishes as qemu-ios-tci-arm64.tar.gz
# in the madeira-ci payloads release. This script downloads it, trims it with
# trim-qemu-sysroot.sh (copied from Madeira, see docs/ARCHITECTURE.md), and copies
# the trimmed Frameworks/ into the app's Frameworks directory.
#
# Usage: fetch-engine.sh <destination-Frameworks-directory> [share-destination]
#        fetch-engine.sh --share-only <share-destination>
#
# --share-only fetches the firmware and nothing else. tools/boot_smoke.py needs
# only share/qemu, and it runs on a schedule, so it should not drag 55 frameworks
# through a runner to boot a guest. The firmware it gets is the same payload the
# packaged app ships: trim-qemu-sysroot.sh deletes firmware for other machines
# and leaves the aarch64 pair alone, so these are the bytes inside the IPA.
#
# Exit 0 only when the engine framework is present in the destination, or, with
# --share-only, when the firmware is. Any other result is a failure: a build that
# silently ships without the engine would make EngineLocator report "missing"
# with no reason anyone could see.

set -euo pipefail

share_only=no
if [ "${1:-}" = "--share-only" ]; then
    share_only=yes
    shift
fi

dest="${1:-}"
if [ -z "$dest" ]; then
    echo "usage: fetch-engine.sh [--share-only] <destination-Frameworks-directory> [share-destination]" >&2
    exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
repo="${MADEIRA_PAYLOAD_REPO:-sheltonsilas/madeira-ci}"
asset="qemu-ios-tci-arm64.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download payloads --repo "$repo" --pattern "$asset" --dir "$work"

# The archive is rooted at ./Frameworks, ./share, ... so extract it into the sysroot.
sysroot="$work/sysroot"
mkdir -p "$sysroot"
tar -xzf "$work/$asset" -C "$sysroot" 2>/dev/null

if [ "$share_only" = yes ]; then
    mkdir -p "$dest"
    cp -R "$sysroot/share/." "$dest/"
    if [ ! -f "$dest/qemu/edk2-aarch64-code.fd" ] || [ ! -f "$dest/qemu/edk2-arm-vars.fd" ]; then
        echo "::error::the firmware did not land in $dest" >&2
        exit 1
    fi
    echo "firmware installed in $dest"
    exit 0
fi

bash "$here/trim-qemu-sysroot.sh" "$sysroot"

engine="$sysroot/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
if [ ! -f "$engine" ]; then
    echo "::error::the trimmed payload has no aarch64 engine at $engine" >&2
    exit 1
fi

mkdir -p "$dest"
cp -R "$sysroot/Frameworks/." "$dest/"

if [ ! -f "$dest/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" ]; then
    echo "::error::the engine did not land in $dest" >&2
    exit 1
fi
echo "engine framework installed in $dest"

# The firmware lives in share/qemu. It goes to a directory outside App/ so that
# XcodeGen does not treat 75 MB of firmware as app sources; the packaging step
# copies it into the bundle as share/. The launcher passes these paths to QEMU.
share_dest="${2:-Engine/share}"
mkdir -p "$share_dest"
cp -R "$sysroot/share/." "$share_dest/"
if [ ! -f "$share_dest/qemu/edk2-aarch64-code.fd" ]; then
    echo "::error::the firmware did not land in $share_dest" >&2
    exit 1
fi
echo "firmware installed in $share_dest"
