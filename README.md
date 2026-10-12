# Madeira Next

A from-scratch iOS and iPadOS app for running Windows programs (Wine + FEX + DXMT)
and Linux desktops (QEMU TCG), with a shared engine layer.

Status: early scaffold. An unsigned, device-only IPA builds in CI and can be
signed onto a device — see [docs/INSTALL.md](docs/INSTALL.md) for how, and for
what the app does and does not do yet. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the source map, which records where every copied file came from and under
what licence.

## Licence

Madeira Next's own code is GPL-3.0-or-later (see `COPYING`).

The files under `upstream/utm/` are copied from UTM and remain Apache-2.0
(see `upstream/utm/LICENSE`). Apache-2.0 code can be used in a GPL-3.0 project.
Each copied file keeps its own copyright header.
