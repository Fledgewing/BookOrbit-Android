# Features

What Orbify ships, per platform. Only what we add: KOReader's, BookOrbit's and CrossInk's own
features are not listed. Planned work is in [`ROADMAP.md`](../ROADMAP.md); an item moves here when
it ships (AGENTS.md "Features and roadmap").

**Principle: nothing interrupts reading.** While a book is open in front, nothing Orbify adds
shows, restarts or takes focus; it waits for the next non-reading moment
([design](design/reading-gate.md)). Exceptions: menus you open, the end-of-book sheet, and the approved OrbiSmart Yes / No popup.

**yes**: shipped. Firmware is built on CrossInk 2.x only, now the release candidate
`2.0.0+bookorbit.1-rc3`; CrossInk 1.6 is retired, and readers still on it keep the stable
`xteink-v1.6.1.114`, which gets nothing new, until a final CrossInk 2.x release replaces it.
**2.x rc**: in the CrossInk 2.x release-candidate build (Include Release Candidates). **no**: not on this reader, with the reason. Platforms: AGENTS.md "Platforms".

## Credits

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Public About credit: Orbify independence, thanks to BookOrbit, and separate project licences ([design](design/bookorbit-credit.md)); same text in README | yes (plugin and companion) | 2.x rc | 2.x rc | no: flash |

## Network and sync

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Reach a BookOrbit server that is only on your tailnet | yes (Tailscale app, woken by the companion) | yes (MicroLink) | yes | yes |
| Tailnet login and status on the device (Settings > Tailscale, QR code) | n/a (Tailscale app) | yes | yes | yes |
| Tailnet names (`bookorbit`, `*.ts.net`) for every client on the device | n/a (Tailscale app) | yes | yes | yes |
| Network brought up before the plugin syncs, and back off after | yes | n/a (firmware does it) | n/a | n/a |
| Sync on sleep, wake pull, Sync and sleep | yes | n/a (firmware does it) | n/a | n/a |
| OrbiSmart: furthest-place sync, behind-hold, pause sync, a Yes / No popup for another reader's place (silent only before render), and "Read from here everywhere" queued offline ([design](design/orbismart.md); upstream: [send-time stale-push guard](server-contract.md#the-stale-push-guard-compares-send-times)) | yes | 2.x rc (sleep, wake and pause) | 2.x rc | 2.x rc (sleep only) |
| Sync while reading (time, pages or chapters) | yes | 2.x rc | 2.x rc | no: no memory beside an open book |
| Wi-Fi modes: Always on, Off while reading, Just in time | yes | n/a | n/a | n/a |
| Faster Wi-Fi join and catalog boot session | n/a | yes | yes | yes |
| Download progress, and back to the catalog after a download | n/a | yes | yes | yes |
| BookOrbit server certificate checked before credentials are sent: Let's Encrypt roots, or a certificate trusted at login by its fingerprint (re-trust when it changes); tailnet hosts exempt ([design](design/server-tls.md)) | n/a (Android's TLS) | 2.x rc | 2.x rc | no: flash |

## Library and home

| Feature | KOReader-Android | X4 Pro | X4 | X3 |
|---|---|---|---|---|
| Home button: back to the book, then BookOrbit home; companion as launcher | yes | n/a | n/a | n/a |
| BookOrbit home opens on its first page | yes | n/a | n/a | n/a |
| Lists by series and by author (BookOrbit's Series and Authors views), on every book list (All books and Recently updated since 0.11.2) | yes | no | no | no |
| Reopen the open book after an update restart, and BookOrbit Home if it was on top | yes | n/a | n/a | n/a |
| Nothing interrupts reading: notes, update prompts, reminders and restarts wait until no book is open in front ([design](design/reading-gate.md)) | yes (0.11.1) | planned | planned | planned |
| Updates you start restart KOReader at once and say "Updated to vX"; automatic ones restart only at screen-off or with KOReader in the background | yes (0.11.1) | n/a | n/a | n/a |
| Offline mirror: a Full refresh saves every page reachable from Home (lists, section indexes, On device, details, covers) for browsing offline; every book's details too (0.11.2); a request with no answer is retried in smaller pages, then skipped, and a paused run resumes at the next network up, wake or Home (0.11.2); "Save every cover for offline" setting, off by default (0.11.2); one Storage limit on everything Orbit stores, 250 MB by default (0.11.2), with choices through 10 GB (including 2.5 GB and 5 GB) or No limit; Refresh rechecks every saved page; automatic Full refresh every 7 days or when the library changes; "Saved for offline · time" ([design](design/write-through-cache.md#offline-mirror-v0111); upstream: [catalog replies carry no version](server-contract.md#catalog-replies-carry-no-version)) | yes (0.11.1) | 2.x rc (smaller, on SD; ⟳ hold or settings; one start popup, then a rising % in the header while you browse) | 2.x rc | no: no room |
| On device grouped by author and series, like BookOrbit's lists | yes (0.11.1) | n/a | n/a | n/a |
| Remove a book from the reader while another book is open | yes (0.11.1) | n/a | n/a | n/a |
| Keep book copies current: a copy whose library file changed (BookOrbit writes tags into it) is downloaded again in the background, never while reading; position, highlights and bookmarks carried over ([design](design/keep-copies-current.md); upstream: [a metadata write changes the file hash](server-contract.md#a-metadata-write-changes-the-file-hash)) | yes (0.11.1) | 2.x rc (at the sleep sync) | 2.x rc | 2.x rc |
| Mark finished at the end of the book: final position, then read status and rating sent after the outbox, kept through the next state pull; a stale position push is held ([design](design/end-of-book/DESIGN.md); upstream: [progress finishes a book only at the library's threshold](server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold)) | yes (0.9.0) | 2.x rc (xteink-v2.0.0.123) | 2.x rc | 2.x rc |
| End-of-book sheet: Undo, stars, next in series (open, or download and open), one suggestion, the author's books | yes (0.9.0) | 2.x rc (xteink-v2.0.0.131) | 2.x rc | 2.x rc (no stars) |
| Local-first BookOrbit home: this device's reading shown at once, a refresh repaints only what changed, ⟳ and "updated" stamp on home and lists ([design](design/local-first/DESIGN.md)) | yes (0.9.0) | n/a (ROADMAP 4 is the Xteink catalog) | n/a | n/a |
| Write-through cache in front of BookOrbit: catalog screens open from Orbit's cache at once and are checked in the background; writes patch what they change; tap ⟳ = Refresh (check now, nothing evicted), hold ⟳ or the menu = Full refresh (fresh from the server, broken covers replaced); covers fetched only when missing or changed, with ETag 304s; offline, saved pages open and page without asking for Wi-Fi ([design](design/write-through-cache.md); upstream: the plugin's refresh deletes every cover on screen) | yes (0.10.1) | 2.x rc (⟳ on every catalog view; no background revalidation yet) | 2.x rc | no (no room) |

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
