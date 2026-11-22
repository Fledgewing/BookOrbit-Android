# Orbify

Keeps e-readers in sync with a [BookOrbit](https://github.com/bookorbit/bookorbit) server over
Tailscale, on Android and on Xteink readers.

- **Android** ([`android/`](android/README.md)): a KOReader patch and the Orbit Companion app.
  They bring Wi-Fi and Tailscale up for the BookOrbit plugin, sync on sleep and while reading,
  and add a Home button, lists by series and author, battery stats, clicker buttons and a
  settings PIN. New here? The [setup guide](android/docs/SETUP.md).
- **Xteink** ([`xteink/`](xteink/README.md)): CrossInk-Bookorbit firmware with the reader on your
  tailnet (X4 Pro, X4 Classic, X3), formerly CrossInk-Tailnet.

What ships where: [`docs/FEATURES.md`](docs/FEATURES.md). What's next: [`ROADMAP.md`](ROADMAP.md).
How the server behaves: [`docs/server-contract.md`](docs/server-contract.md).

## Releases

One [releases page](https://github.com/Fledgewing/Orbify/releases) for both platforms:

- `android-v…`: Orbit Companion APK and the KOReader patch. Both update themselves.
- `xteink-v…`: firmware for each reader, installed over the air from **Settings > Check for
  updates**, or flashed from an SD card or USB.

Every release carries `SHA256SUMS` and build attestations:
`gh attestation verify <file> -R Fledgewing/Orbify`.

## License

Per directory: `android/koreader-patch/` is AGPL-3.0-or-later; `android/companion/`, `xteink/`
(source) and everything else are MIT. Firmware binaries are GPL-3.0-or-later (they include
wolfSSL; see `xteink/README.md`). Each directory has its `LICENSE`.
