# BookSync for e-readers

Keeps e-readers in sync with a [BookOrbit](https://github.com/bookorbit/bookorbit) server over
Tailscale, on Android and on Xteink readers.

- **Android** ([`android/`](android/README.md)): a KOReader patch and the BookSync Companion app.
  They bring Wi-Fi and Tailscale up for the BookOrbit plugin, sync on sleep and while reading,
  and add a Home button, lists by series and author, battery stats, clicker buttons and a
  settings PIN. New here? The [setup guide](android/docs/SETUP.md).
- **Xteink** ([`xteink/`](xteink/README.md)): CrossInk-Bookorbit firmware with the reader on your
  tailnet (X4 Pro, X4 Classic, X3), formerly CrossInk-Tailnet.

What ships where: [`docs/FEATURES.md`](docs/FEATURES.md). What's next: [`ROADMAP.md`](ROADMAP.md).
How the server behaves: [`docs/server-contract.md`](docs/server-contract.md).

## Releases

One [releases page](https://github.com/Fledgewing/BookSync/releases) for both platforms:

- `v…`: BookSync Companion APK and the KOReader plugin. They ship together: the companion updates itself and then installs the plugin of its release.
- `xteink-v…`: firmware for each reader, installed over the air from **Settings > Check for
  updates**, or flashed from an SD card or USB.

Every release carries `SHA256SUMS` and build attestations:
`gh attestation verify <file> -R Fledgewing/BookSync`. Before it is published, each release passes
the emulated release tests: a real BookOrbit server behind a fault proxy, Xteink scenarios in
the CrossInk simulator and the companion's JVM tests (`AGENTS.md`, "Emulated release tests").

## License

Per directory: `android/koreader/` is AGPL-3.0-or-later; `android/companion/`, `xteink/`
(source) and everything else are MIT. Firmware binaries are GPL-3.0-or-later (they include
wolfSSL; see `xteink/README.md`). Each directory has its `LICENSE`.

Repository rename compatibility and rollout: [`docs/repository-rename.md`](docs/repository-rename.md).

## Credits

BookSync is an independent project, not an official BookOrbit release, and does not include BookOrbit code.

[That said, it wouldn't exist without BookOrbit.](https://github.com/bookorbit/bookorbit)

Copyright (C) 2025-2026 neon. Additional copyright is held by the respective BookOrbit contributors.

BookOrbit is licensed under the GNU AGPLv3 with additional terms.

BookSync licences: BookSync Companion is MIT. The Xteink overlay source is MIT, except firmware code marked GPL-3.0-or-later; Xteink firmware binaries are GPL-3.0-or-later. BookSync is AGPL-3.0-or-later as a KOReader plugin.
