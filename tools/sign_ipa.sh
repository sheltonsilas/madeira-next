#!/usr/bin/env bash
#
# sign_ipa.sh - sign the unsigned IPA with your own identity and the entitlements
# the engine needs.
#
# WHY THIS EXISTS
# The IPA this repository publishes is unsigned on purpose: it has to be signed on
# install, with the user's own Apple ID. Sideloading tools sign it with the
# entitlements their own defaults carry, and those defaults are how an app ends up
# installed and unable to run a guest: no executable memory, no larger memory
# limit, and a guest's RAM is the allocation that gets the app killed.
#
# This script signs the IPA with App/MadeiraNext.entitlements explicitly, verifies
# that those entitlements are in the signature it produced, and leaves an IPA that
# a sideloading tool can install as-is. The nested frameworks are signed first,
# innermost first, because codesign refuses an app whose frameworks are not signed
# with the same identity.
#
# ON macOS ONLY. It needs codesign, which nothing else provides.
#
# Usage:
#   tools/sign_ipa.sh dist/MadeiraNext-unsigned.ipa --identity "Apple Development: You (ABCDE12345)"
#   tools/sign_ipa.sh app.ipa --identity - --out dist/signed.ipa        # ad-hoc, for checking
#   tools/sign_ipa.sh --print-entitlements                              # what would be signed
#
# Exit 0 only when the app and every framework verify and the signature carries
# the required entitlement keys.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
entitlements="$root/App/MadeiraNext.entitlements"

# The keys the app cannot run without on a device. Checked in the signature this
# script produced, not in the file it read.
required_keys=(
    "get-task-allow"
    "com.apple.security.cs.allow-jit"
    "com.apple.developer.kernel.increased-memory-limit"
    "com.apple.developer.kernel.extended-virtual-addressing"
)

if [ "${1:-}" = "--print-entitlements" ]; then
    cat "$entitlements"
    exit 0
fi

ipa="${1:-}"
shift || true
identity=""
out=""
profile=""

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) identity="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --profile) profile="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$ipa" ] || [ ! -f "$ipa" ]; then
    echo "usage: sign_ipa.sh <ipa> --identity <codesign identity> [--out <ipa>] [--profile <mobileprovision>]" >&2
    exit 2
fi

if [ -z "$identity" ]; then
    echo "::error::--identity is required (use - for an ad-hoc signature that only a check can use)" >&2
    exit 2
fi

if ! command -v codesign >/dev/null 2>&1; then
    echo "::error::codesign is not on this machine; this script is for macOS. Sign on install with your sideloading tool instead." >&2
    exit 1
fi

if [ ! -f "$entitlements" ]; then
    echo "::error::$entitlements is missing, so there is nothing to sign with" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

unzip -q "$ipa" -d "$work"
app="$work/Payload/MadeiraNext.app"
if [ ! -d "$app" ]; then
    echo "::error::$ipa does not contain Payload/MadeiraNext.app" >&2
    exit 1
fi

if [ -n "$profile" ]; then
    if [ ! -f "$profile" ]; then
        echo "::error::no provisioning profile at $profile" >&2
        exit 1
    fi
    cp "$profile" "$app/embedded.mobileprovision"
    echo "embedded $(basename "$profile")"
fi

# Frameworks first, and the deepest ones first: a framework's nested code has to
# be signed before the framework itself, or codesign rejects it.
sign_args=(--force --timestamp=none --sign "$identity" --entitlements "$entitlements")
nested=0
while IFS= read -r item; do
    sign_args=(--force --timestamp=none --sign "$identity")
    codesign "${sign_args[@]}" "$item"
    nested=$((nested + 1))
done < <(find "$app/Frameworks" -name '*.framework' -o -name '*.dylib' 2>/dev/null | sort -r)
echo "signed $nested nested item(s)"

codesign --force --timestamp=none --sign "$identity" --entitlements "$entitlements" "$app"
echo "signed the app"

# The signature is the only thing that carries entitlements onto a device, so the
# signature is what is checked. `codesign -d --entitlements` prints the same plist
# the kernel reads.
signed_plist="$work/signed-entitlements.plist"
codesign -d --entitlements :- "$app" > "$signed_plist" 2>/dev/null

for key in "${required_keys[@]}"; do
    if ! grep -q "$key" "$signed_plist"; then
        echo "::error::the signature is missing $key - the app would install and fail to run a guest" >&2
        exit 1
    fi
done
echo "the signature carries ${#required_keys[@]} required entitlement(s)"

codesign --verify --deep --strict "$app"
echo "verification passed"

if [ -z "$out" ]; then
    out="$(dirname "$ipa")/$(basename "${ipa%.ipa}")-signed.ipa"
fi
mkdir -p "$(dirname "$out")"
(cd "$work" && zip -qry "$(pwd)/signed.ipa" Payload)
mv "$work/signed.ipa" "$out"
echo "wrote $out"

# A reminder that belongs in the output, because this IPA is not the deliverable
# until it is on a device: a free-Apple-ID certificate expires after seven days
# and the app has to be signed again.
echo "install it with your sideloading tool of choice; a free Apple ID's certificate lasts seven days"
