# Features

What Orbify ships, per platform. Only what we add: KOReader's, BookOrbit's and CrossInk's own
features are not listed. Planned work is in [`ROADMAP.md`](../ROADMAP.md); an item moves here when
it ships (AGENTS.md "Features and roadmap").

**yes**: shipped. Firmware builds: stable on CrossInk `1.6.1+bookorbit.9`, release candidate on
`2.0.0+bookorbit.1-rc3`. **2.x rc**: in the CrossInk 2.x release-candidate build only (Include Release
Candidates). **no**: not on this reader, with the reason. Platforms: AGENTS.md "Platforms".

## Network and sync

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Reach a BookOrbit server that is only on your tailnet | yes (Tailscale app, woken by the companion) | yes (MicroLink) | yes | yes |
| Tailnet login and status on the device (Settings > Tailscale, QR code) | n/a (Tailscale app) | yes | yes | yes |
| Tailnet names (`bookorbit`, `*.ts.net`) for every client on the device | n/a (Tailscale app) | yes | yes | yes |
| Network brought up before the plugin syncs, and back off after | yes | n/a (firmware does it) | n/a | n/a |
| Sync on sleep, wake pull, Sync and sleep | yes | n/a (firmware does it) | n/a | n/a |
| Sync while reading (time, pages or chapters) | yes | 2.x rc | 2.x rc | no: no memory beside an open book |
| Wi-Fi modes: Always on, Off while reading, Just in time | yes | n/a | n/a | n/a |
| Faster Wi-Fi join and catalog boot session | n/a | yes | yes | yes |
| Download progress, and back to the catalog after a download | n/a | yes | yes | yes |

## Library and home

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Home button: back to the book, then BookOrbit home; companion as launcher | yes | n/a | n/a | n/a |
| BookOrbit home opens on its first page | yes | n/a | n/a | n/a |
| Lists by series and by author (BookOrbit's Series and Authors views) | yes | no | no | no |
| Reopen the open book after an update restart | yes | n/a | n/a | n/a |
| Mark finished at the end of the book: final position, then read status and rating sent after the outbox, kept through the next state pull; a stale position push is held ([design](design/end-of-book/DESIGN.md); upstream: [progress finishes a book only at the library's threshold](server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold)) | yes (0.9.0) | planned (ROADMAP 1) | planned | planned |
| End-of-book sheet: Undo, stars, next in series (open, or download and open), one suggestion, the author's books | yes (0.9.0) | planned (ROADMAP 2) | planned | if flash allows |
| Local-first BookOrbit home: this device's reading shown at once, a refresh repaints only what changed, ⟳ and "updated" stamp on home and lists ([design](design/local-first/DESIGN.md)) | yes (0.9.0) | n/a (ROADMAP 4 is the Xteink catalog) | n/a | n/a |
| Write-through cache in front of BookOrbit: catalog screens open from Orbit's cache at once and are checked in the background; writes patch what they change; tap ⟳ = Refresh (check now, nothing evicted), hold ⟳ or the menu = Full refresh (fresh from the server, broken covers replaced); covers fetched only when missing or changed, with ETag 304s; offline, saved pages open and page without asking for Wi-Fi ([design](design/write-through-cache.md); upstream: the plugin's refresh deletes every cover on screen) | yes (0.10.1) | planned (ROADMAP 4) | planned | planned |

## Device

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Settings PIN (kid lock) | yes | 2.x rc | 2.x rc | 2.x rc |
| Battery stats in the `orbit-battery-stats/1` format, Compare across readers | yes | 2.x rc | 2.x rc | 2.x rc (file only, no numbers on screen) |
| Clicker buttons (page turns in KOReader and other apps, Send key) | yes | n/a | n/a | n/a |
| Frontlight re-applied after the first paint of every boot | n/a | yes | yes | yes |
| Setup installs KOReader and the BookOrbit plugin; USB installer (`tools/install-usb.sh`) | yes | n/a | n/a | n/a |
| Add-on mode: keep the reader's own launcher and Wi-Fi; Orbify installs, updates and sets up KOReader and the plugins; Wi-Fi switching, sleep sync, clicker buttons and the PIN are optional helpers; switch modes in Settings › Mode ([design](design/addon-mode.md)) | yes (0.11.0) | n/a | n/a | n/a |
| Recommended settings applied at setup and on update: only values still at KOReader's or BookOrbit's default change, values you changed are listed for review, Undo from a backup (Tools › Android sync › Recommended settings) | yes (0.11.0) | n/a | n/a | n/a |
| Companion Setup shows "Signed in to BookOrbit" (a yes/no from the plugin, never the server or account) and the recommended-settings state | yes (0.11.0) | n/a | n/a | n/a |
| Orbit is a KOReader plugin (`orbit.koplugin`, in the Plugin manager; replaces the 0.7.x user patch on update, [design](design/orbit-plugin.md)) | yes (0.8.0) | n/a | n/a | n/a |
| Self-update, SHA-256 checked | yes (app and plugin) | yes (OTA) | yes (OTA) | yes (OTA) |
