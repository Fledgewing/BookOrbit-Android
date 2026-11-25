# Orbify for Xteink (CrossInk-Tailnet)

Orbify's Xteink firmware, built as the CrossInk-Tailnet overlay. It lived in
Fledgewing/CrossInk-Tailnet until it moved into Orbify with its history (`xteink/`); that repo is
archived. Releases are this repo's `xteink-v…` tags (AGENTS.md "Releases").

[CrossInk-Bookorbit](https://github.com/agosez/CrossInk-Bookorbit) firmware with your reader on
your Tailscale tailnet, using [MicroLink](https://github.com/CamM2325/microlink). BookOrbit sync,
the catalog, OPDS and downloads can reach servers that are only on your tailnet.

This is an **overlay**, not a fork. CrossInk's source is used as released; the overlay adds:

| Piece | Where | What it does |
|---|---|---|
| MicroLink | `third_party/microlink` (submodule: the `crossink` branch of [our fork](https://github.com/Fledgewing/microlink)) | Tailscale-compatible WireGuard client for ESP32, with our changes (closest relay region, per-peer relays) on top |
| Shim | `tailnet/shim` | Starts MicroLink when WiFi gets an address, stops it when WiFi goes away; answers tailnet names (`bookorbit`, `bookorbit.<tailnet>.ts.net`) for every HTTP client in the firmware |
| Settings screen | `tailnet/ui` | **Settings > Tailscale**: on/off, status and address, log in (QR code) and log out |
| Build hook | `tailnet/tailnet_build.py` + `overlay/platformio.local.ini` | Compiles the above into CrossInk's normal PlatformIO build and points the updater at Orbify's `xteink-v…` releases (patch `ota-tag-prefix`) |
| CrossInk patches | `overlay/patches/v2.0/` (CrossInk 2.x) | One numbered series per upstream line: the Settings row (0001), the framebuffer freed while Tailscale runs in a network boot on the X3/X4 (0002, `tailnet/shim/TailnetNetPhase.h`), and the memory and download changes after them |

**CrossInk 2.x only.** Orbify no longer builds or supports CrossInk 1.6 (its patch series is in git
history). Readers still on 1.6 stay on the feed's stable entry, `xteink-v1.6.1.114+bookorbit.9`,
until CrossInk 2.0 leaves its release candidates (below).

When CrossInk-Bookorbit releases, the daily CI run rebuilds its newest 2.x tag with the overlay and
publishes a release here. The only thing that can need hand work is the patch series for that upstream
line, and CI says so if it stops applying.

### Releases and the update feed

Readers' updaters read `xteink/releases.json` on the `xteink-feed` branch: the newest stable and
the newest pre-release `xteink-v…` release. Which one a build becomes is decided by the upstream tag
(`scripts/upstream-line.sh channel`, tested by `test/upstream_line_test.sh`):

| Upstream tag | Our release | Feed |
|---|---|---|
| a release candidate or beta (`v2.0.0+bookorbit.1-rc3`) | pre-release | the pre-release entry (readers with Include Release Candidates on) |
| a final release (`v2.0.0+bookorbit.1`, no `-rc`/`-beta`) | stable | the stable entry: readers still on 1.6 are offered it at their next check |
| 1.x | refused | — |

Every firmware release keeps `make_latest=false`: GitHub's "latest" stays an Android release.

### When a release is made

Releases are batched, so readers don't get a new build for every change:
- **The daily run** publishes only when CrossInk-Bookorbit has a tag no release was built from yet
  (a new rc, or the final, which becomes the stable entry). Otherwise it builds and publishes
  nothing.
- **Our own changes** go out only when someone runs the workflow by hand (`gh workflow run Xteink
  --ref main`), which publishes what main has unless that exact overlay was already released
  (`force_release` publishes it again).
- Pushes and pull requests build and test, and never publish.

The rule is `scripts/upstream-line.sh publish`, tested by `test/upstream_line_test.sh`.

## Readers

| Reader | Env | Notes |
|---|---|---|
| X4 Pro | `x4-pro` | ESP32-S3 + PSRAM. Primary target. |
| X4 Classic | `x4-classic` | ESP32-S3 + PSRAM. |
| X3 / X4 | `default` | ESP32-C3, no PSRAM. Built with English UI only to make room; smaller MicroLink buffers. |

The partition table is never changed (that can only be done over USB).

### X3 (v2.0) differences

CrossInk 2.x plus Tailscale does not fit the ESP32-C3's app slot, so the `default` build
(X3 and the C3 X4) of CrossInk 2.x leaves out four upstream features and Orbify's server certificate check. The X4 Pro and X4 Classic
keep everything. Each is a switch in `tailnet/tailnet_build.py` (`CROSSINK_TAILNET_NO_*`).

| Removed on the X3 | Workaround |
|---|---|
| Nearby transfer (send a book, nearby position and stats sync) | Use File Transfer (web) or the SD card to move books. |
| mDNS (`<name>.local`) | Connect Calibre and the web file transfer with the IP address shown on the reader's screen. |
| Plugins (hub, catalog, plugin events, the web plugin pages) | None on the X3. |
| Language and hyphenation pack downloads | Install from the SD card (below). Packs already on the card keep working. |
| The BookOrbit server certificate check ([below](#bookorbit-server-certificate)) | Reach BookOrbit over Tailscale, which authenticates the server itself. |

To install from the SD card, download `crossink-languages-<version>.zip` from the
CrossInk-Bookorbit release that matches the firmware (upstream CrossInk's packs lack this fork's
screens). Copy its `.crossink` folder to the root of the SD card. It holds both
`.crossink/languages` and `.crossink/hyphenation` (`hyph-<code>.cphyph`). Then:

- **Languages:** pick one in **Settings > System > Device > Language**.
- **Hyphenation:** open **Settings > Reader > Page Layout > Hyphenation Packs** and select a
  pack marked **Install**. Installed packs offer **Delete** only. To update a pack, delete it,
  copy the new file and install it again.

Where the downloads used to be, the reader shows where to copy the files.

## First install

Flash the `.bin` for your reader from the latest release the same way you install CrossInk from
an SD card or USB. After that, **Settings > Check for updates** installs new releases over the air:
Orbify's `xteink-v…` firmware releases (a reader on a CrossInk-Tailnet build gets there through
that repo's last release, which already points at Orbify). To go back to stock CrossInk-Bookorbit, flash its `.bin` the same way.

The check reads Orbify's own small feed (`xteink/releases.json` on the `xteink-feed` branch, two
releases), not GitHub's release API, and a failed check is tried once more. The download then runs
with the larger WiFi buffers of the boots that park the screen (the X3's `parked` tier). The last
CrossInk-Tailnet bridge (`v2.0.0.51+bookorbit.1-rc2`) still reads the GitHub API and the small
buffers: on an X3 its first check can fail out of memory (try again) and its download can take
30-50 minutes. Leave the reader on its charger; the next update from Orbify is fast.

## Joining your tailnet

Tailscale ships **off**. Nothing tailnet-related runs until you turn it on.

1. Open **Settings > Tailscale** and choose **Log in**. It turns Tailscale on and, if WiFi is
   off, asks for a network first.
2. Scan the QR code with a phone that is signed in to Tailscale and approve the device. The
   screen then shows the reader's `100.x.y.z` address. From then on the reader joins the tailnet
   whenever WiFi is on.
3. In the [admin console](https://login.tailscale.com/admin/machines), tag the reader as described
   in [Recommended tailnet setup](#recommended-tailnet-setup) (recommended; required only on
   tailnets of several hundred devices). If you don't tag it, **disable key expiry** for it instead: a device that joined
   by QR cannot renew its own key. Optionally rename it (default `esp32-xxyyzz`).
4. Point BookOrbit (or OPDS) at the server's tailnet name, its `100.x` address, or a public DNS
   name that points at the `100.x` address (e.g. `https://books.example.net`).

**Log out** in the same screen erases the reader's tailnet keys; remove the old device in the
admin console too. Turning Tailscale off keeps the login for later.

## Recommended tailnet setup

Recommended for every tailnet: give the reader its own tag and let it reach only your BookOrbit
server. Tailscale sends each device only the peers it may talk to (or that may talk to it), so the
reader then receives a list of about one device instead of your whole tailnet.

- **The reader stores its tailnet key unencrypted.** Tagged and restricted, a lost reader can
  reach one service, not your tailnet.
- **Tagged devices don't expire.** You don't need to disable key expiry by hand.
- **MicroLink is small.** It tracks 16 peers (8 on the X3); on a larger tailnet the overlay pins
  your server into that table (see below), at the cost of a restart. It also reads at most 512 KB of
  the device list (roughly 350 devices); past that, only a smaller list helps.

In the admin console, **Access controls**, add (adapt the address and port):

```jsonc
"tagOwners": {
  "tag:ereader": ["autogroup:admin"],
},
"grants": [
  // E-readers reach only the BookOrbit server (add "tcp:80" for plain HTTP).
  {"src": ["tag:ereader"], "dst": ["100.69.222.123"], "ip": ["tcp:443"]},
],
```

Then in **Machines**, open the reader (`esp32-…`) → **Edit ACL tags** → add `tag:ereader`. It keeps
its login.

**Don't give the reader Mullvad.** With Tailscale's Mullvad add-on, every device that has Mullvad
access receives all of Mullvad's ~530 exit nodes in its device list, far more than MicroLink can
read. A `nodeAttrs` entry granting `"mullvad"` to a user group (e.g. `autogroup:member`) does not
apply to tagged devices, so tagging the reader takes care of it; just don't add `tag:ereader` to
such an entry.

**Check for broad rules.** A rule whose `dst` is `"*"` (or a group the reader falls into) lets its
sources reach the reader, and those sources are then sent to the reader too. Name the destinations
of such rules explicitly instead. On the reader, **Settings > Tailscale > Diagnostics** should show
only one or two peers tracked once this is right.

### Large tailnets

MicroLink keeps a small peer table (16 on the X4 Pro/Classic, 8 on the X3). When the reader
connects to a tailnet address that isn't in it, the overlay pins that address as MicroLink's
priority peer, remembers it across reboots, and restarts MicroLink (a few seconds) so the server
is added; the request waits for it. It tries once per address per WiFi session, and the most
recent such address is the one pinned. Pinning cannot recover a server whose entry falls beyond
the 512 KB that MicroLink reads: Tailscale's protocol has no way to ask for a single device.

### Relay regions

When a direct connection isn't possible (guest WiFi, carrier NAT, Kubernetes), traffic goes through
Tailscale's DERP relays, which are grouped into regions that don't forward to each other. Stock
MicroLink uses one fixed region (Dallas) for everything. The overlay's MicroLink patch makes it
behave like a normal Tailscale client:

- **Closest region.** Each time it connects, the reader times a STUN probe to every relay region
  and makes the fastest its home (kept unless another is a third faster). With UDP blocked it
  keeps its previous home.
- **Per-peer relays** (off by default). Packets for a peer can go through that peer's home region
  over a second relay connection, opened on demand and closed after a minute idle. Each costs a TLS
  session of internal RAM, which the X4 Pro can't spare next to CrossInk's own connections, so it's
  built with `CONFIG_ML_DERP_EXTRA_CONNS 0` (`tailnet/ml_config.h`). Peers running Tailscale reach
  the reader through its home region anyway.

**Settings > Tailscale > Relay region** overrides the choice of home region:

- **Match BookOrbit server** (default): the reader's home follows the home region of the tailnet server it
  connects to (learned on first use and remembered; it restarts MicroLink once if the server moves).
  Until it has learned the server's region it uses the closest.
- **Automatic (closest)**: as above.
- **A fixed region** (e.g. `sea`): listed once the reader has connected at least once.

**Settings > Tailscale > Diagnostics** shows both regions ("Relay: ours sea, server sea").

## Sync while reading (X4 Pro, X4 Classic)

With BookOrbit **Smart sync** on, **Settings > BookOrbit Sync > Sync While Reading** syncs the
open book in the background every 10, 15, 30 or 60 minutes, every 25, 50 or 100 pages, or every
one or two chapters (off by default). The book stays open: WiFi and Tailscale come up, the
progress is synced with Smart sync's rules, and WiFi goes off again. A newer position on the
server is never overwritten; it waits for the next sync when you open the book or the reader
sleeps, as does any case Smart sync would ask about. Highlights, bookmarks and reading stats
also wait for that sync. Nothing is shown while reading; without a network it simply tries
again at the next interval. Not on the X3: a sync does not fit in its memory beside an open
book.

## Nothing interrupts reading

While a book is open, Orbify never draws over it, repaints it or restarts the reader on its own:
no message, no update prompt, no sync or WiFi status. The checks for updates run only from
**Settings > Check for updates**; the sync while reading never repaints the page. What does show
while reading: the End-of-Book page (you reached it), any menu or screen you open, and the sleep
sync behind the sleep screen. Anything else waits for a screen that is not the book (Home, the
catalog, the Library) or is dropped. The rule is one table (`orbify/core/ReadingQuiet`,
`shared/fixtures/reading-quiet/cases.json`, host-tested), and every place the overlay could show
something on its own asks it first (`orbify/Quiet.h`).

## Finished at the end of a book

Turning past the last page marks the book finished on the reader, and the next BookOrbit sync
(on sleep, by hand, or while reading) tells BookOrbit: the book leaves Also Reading and counts as
read on the day it was finished. Marking a book finished from the menus, its stats page or the
Library is sent the same way, and marking it unfinished before that sync cancels it. Offline,
up to 16 finished books wait in `/.crosspoint/orbify_finish.bin` and go with the next sync. A sync
on sleep also no longer pushes a position far below the end of a book finished here (a second
reader's old position would otherwise reopen it as a reread).

**Settings > BookOrbit Sync > Mark Finished at End** turns the automatic mark off (on by default).

The End-of-Book page, full screen in large type, then shows **The End** over the book's title and
author, where the book stands, and what comes next:
- **Finished · sends at next sync** (Undo).
- Your rating as five stars on the X4s: tap a star on the X4 Pro, or Left/Right then Confirm.
- The **next book in the series** (or the gap, or "You've finished the series").
- Up to two suggestions ("Also by" and "You might like").
- **All books by <author>**.
- Home.

Rows keep their places when you Undo, and a tap only counts once the page is on screen. A book that is not on the card offers
**Download**: the catalog downloads it and opens it, and Back returns to the finished book. The
next book and suggestions come from BookOrbit when the book is downloaded and are refreshed by
syncs near its end. Without them (offline, or never fetched), the page shows the series the book
names with "Connect to see what's next", CrossInk's folder suggestions and the author's row.

## Book copies kept current

When BookOrbit rewrites a book's file (editing its tags or cover writes them into the EPUB), the copy on the
card stops syncing highlights and bookmarks: the server knows it only as an older copy. **Keep Book Copies
Current** (BookOrbit Sync settings, on by default) replaces those copies while the reader sleeps:

- The sleep sync asks the server about every book the catalog downloaded, 20 at a time, and queues the
  copies it calls older. The BookOrbit Home's **Refresh** finds them too.
- Each sleep sync then replaces queued copies one at a time, for up to three minutes: same path and name,
  downloaded beside the old copy, checked against the server's hash of the library file, then swapped in.
  The reading position, highlights and bookmarks move to the new copy.
- The queue is kept on the card, so a wake press or a reset carries on at the next sleep.
- A sync that finds the open book out of date offers **Update**. It now shows "Updates when you leave the
  book" and queues the copy instead of restarting.

The log shows `ORB Copy refresh: <n> queued` and, per book, `replaced: <old hash> -> <new hash>`.

## Saved catalog replies (X4 Pro, X4 Classic)

The catalog keeps every reply it reads from BookOrbit in `/.crosspoint/bookorbit-cache/` (at most
2 MB and 200 replies; the least recently used go first). A screen checked in the last minute, or
opened without Wi-Fi, comes from the card; otherwise the reader asks BookOrbit, keeps the answer,
and shows the saved one if BookOrbit does not answer. A finish or rating sent to BookOrbit updates
the saved replies that list the book. Home covers keep BookOrbit's ETag, so a book whose details
change but whose cover doesn't costs a short "not modified" reply instead of a new cover. Another
server or account clears the folder. The X3 keeps today's catalog
([design](../docs/design/write-through-cache.md)).

**Offline catalog.** Every catalog screen has a ⟳ at the top right, with when the screen was
last updated beside it ("updated just now", "Offline, saved 3 h ago"). On the X4 Pro, tap it; on
the X4, press Up on the first row to select it, then Confirm:
- **Refresh** (tap, or Confirm) asks BookOrbit for this screen now.
- **Full refresh** (hold, or a long press of Confirm) saves the catalog for offline use: its root,
  the first page of each section and of the lists they lead to, and the details of the books on
  the reader and the next books in their series. One popup says it started ("Full refresh in
  progress · about 0% · you can keep reading and browsing"), then a small % in the header, where
  the "updated" text was, shows how far it is; it only goes up, and ends on "Done" (or "Done with
  N errors"). You keep browsing meanwhile; leave the catalog and it carries on while the reader
  sleeps, or the next time you open the catalog. Home's header shows the % while one is unfinished.

**Settings › BookOrbit › Home › Full refresh** does the same from settings; its value says when
the catalog was last saved. The reader also refreshes the saved catalog by itself while asleep
(with Wi-Fi in reach) every 7 days, or when the library changes. With a saved catalog, opening
the catalog without Wi-Fi shows it from the card instead of giving up. Search and downloads still
need a connection.

## BookOrbit server certificate

The reader checks the BookOrbit server's HTTPS certificate before it sends your credentials
([design](../docs/design/server-tls.md)). Certificates from Let's Encrypt (including `tailscale
cert`) are accepted as they are. For any other certificate (self-signed, or from your own CA),
the first **Settings > BookOrbit > Authenticate** shows **Unknown server certificate** and its
SHA-256 fingerprint: compare it with your server's (`openssl x509 -noout -fingerprint -sha256
-in <cert>`), then press Confirm to trust it. If the server's certificate later changes, the
catalog and sync stop connecting. Run Authenticate again: it shows **Server certificate changed**
and the new fingerprint to trust. The certificate must name the host in the server URL.

Servers reached over Tailscale (`100.x` addresses, `*.ts.net` and short tailnet names) are not
checked this way: WireGuard already authenticates them.

Not on the X3 and C3 X4 (`default`): its flash has no room for the check. There, reach BookOrbit
over Tailscale rather than a public HTTPS URL on shared Wi-Fi.

## Settings PIN

**Settings > System > Settings PIN** sets an optional 4-digit PIN (Up/Down change a digit,
Confirm moves on). While one is set, the reader asks for it before opening Settings, the
BookOrbit, KOReader and OPDS account screens, Quick Actions and button setup, the plugin
installer, and before joining or forgetting a WiFi network. The web file transfer answers
"settings locked" for its settings, WiFi, OPDS, font and plugin-file pages, and hidden files
(`.crosspoint`, `.crossink`) stay hidden on the reader, in the web file manager and over
WebDAV. Reading, the library, the BookOrbit catalog, downloads and sync stay open. Once
entered, the PIN holds until you leave Settings or the reader sleeps.

It is a lock against children, not security: anyone can take the SD card out and edit the
settings files. The PIN is kept in the reader's internal memory, so deleting the settings file
does not remove it. If it is forgotten, create an empty file named `unlock-settings` in the
`.crossink` folder of the SD card and restart the reader: the PIN is removed and the file
deleted.

## Battery stats

The reader keeps a small log of how its battery is used: one 16-byte record whenever it wakes,
sleeps, restarts, turns WiFi on or off, is plugged in or unplugged, opens or closes a book,
turns the frontlight on or off, or its battery level changes while awake. The log is
`.crossink/battery.bin` on the SD card, about 1.6 KB a day. Nothing wakes the reader to
record it, and nothing leaves the reader on its own.

**Settings > System > Battery stats** writes `battery_stats.json` to the root of the SD card in
the `orbit-battery-stats/1` format, which Orbit Companion's Battery › Compare reads. On the X4
Pro and X4 Classic the same page shows the time left and the battery used per hour asleep,
per hour reading and per 100 pages, and the file is written again whenever USB Drive mode
starts. The X3 and X4 build (`default`) writes the file without the numbers on the page.

## Limits

- Only tailnet hosts go through the tunnel. Internet traffic (GitHub updates, public OPDS
  catalogs) goes direct: MicroLink cannot use an exit node.
- Tailnet names come from the reader's peer list, not MagicDNS. Short names and full
  `*.ts.net` names of peers work; other MagicDNS records do not. Public DNS records pointing at
  `100.x` addresses work, unless your router's DNS rebinding protection strips such answers.
- The tailnet key is stored in the reader's internal flash, unencrypted (MicroLink's design).
  Limit the reader with an ACL tag, and remove it in the admin console if it's lost.
- MicroLink is an independent, beta implementation of the Tailscale protocol (see its README).

## Building locally

```bash
git clone --recursive https://github.com/agosez/CrossInk-Bookorbit
git clone --recursive https://github.com/Fledgewing/Orbify
Orbify/xteink/scripts/apply.sh CrossInk-Bookorbit
Orbify/xteink/test/run-host-tests.sh CrossInk-Bookorbit   # the overlay's host tests
cd CrossInk-Bookorbit && pio run -e x4-pro    # or x4-classic, default
```

`apply.sh` picks the patch series from the checkout's CrossInk version (`[crossink] version` in its
`platformio.ini`, else its tag): 2.x uses `overlay/patches/v2.0`, and any other version (1.6
included) stops with an error. `apply.sh --series v2.0 <checkout>` (or
`CROSSINK_PATCH_SERIES=v2.0`) chooses one explicitly. Besides that series it only touches git-ignored
paths in CrossInk, and it is safe to rerun.

If you also build other CrossInk lines, keep a separate PlatformIO home for 2.x (they use different
pioarduino platforms), e.g. `PLATFORMIO_CORE_DIR=~/.platformio-2x pio run -e default`.

To rebuild a published release, use the commits from its notes: clone CrossInk-Bookorbit at the
release's upstream tag (`git clone --recursive --branch <tag> ...`), check out Orbify at
the release's overlay commit (`git checkout <commit> && git submodule update --init --recursive`),
then run the same commands. CI builds with PlatformIO Core 6.1.19 (pioarduino); see
`.github/workflows/xteink.yml` at that commit (`.github/workflows/build.yml` in
CrossInk-Tailnet for its releases).

## License

- **Source in this repository** (the overlay): MIT, see [`LICENSE`](LICENSE). MicroLink, the
  submodule, is MIT too (`third_party/microlink/LICENSE`, with its WireGuard and X25519 notices).
- **Firmware code moved out of the patches** (files under `orbify/` whose first line is
  `SPDX-License-Identifier: GPL-3.0-or-later`): GPL-3.0-or-later. They were new files inside the
  patch series, written to build into CrossInk-Bookorbit, and keep the firmware's license. Every
  other file here without that line is MIT.
- **Released firmware binaries** (`firmware-*.bin`): they combine CrossInk-Bookorbit, MicroLink,
  this overlay, the Arduino core, ESP-IDF and other third-party components, including
  [wolfSSL](https://github.com/wolfSSL/Arduino-wolfSSL), which is licensed GPL-2.0-or-later. The
  binaries are therefore distributed under the **GNU General Public License v3.0 or later**
  ([`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt)). Each component keeps its own license for its
  own code.
- **Third-party list:** [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) lists every component
  in the firmware with its version, license, copyright and source; [`licenses/`](licenses/) holds
  the license texts and notices. Every release attaches both (`licenses.zip`).
- **Corresponding source:** each release's notes ("Licenses and source") link the exact overlay
  commit, the CrossInk-Bookorbit tag, the MicroLink commit and these build instructions
  ([Building locally](#building-locally)). The upstream tag's `platformio.ini` pins the platform and
  every library version. Releases also attach `source-<version>.tar.gz` with all of that source,
  including the libraries and the Arduino core, in one archive.

Not affiliated with or endorsed by Tailscale Inc.
