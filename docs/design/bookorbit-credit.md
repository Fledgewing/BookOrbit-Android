# BookOrbit credit (W18)

The user approved the wording and placements below in the clarified W18 brief. BookSync keeps
its name. This is a courtesy acknowledgment of BookOrbit and the runtime hooks, not a claim
that BookSync contains its code or shares its licence.

The copyright line is verbatim from pinned BookOrbit commit
`c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`, `ADDITIONAL_TERMS.md:5` (also `:17-19`).
The public About placement is informed by `ADDITIONAL_TERMS.md:13-27` at that commit.
The user's independence statement and thanks supersede that document's credit heading.

`shared/about/credits.json` is the one notice source. Its order is independence, thanks and
project URL, BookOrbit copyright and licence, then BookSync's licences immediately after.
The companion is MIT (`android/companion/LICENSE`); the plugin is AGPL-3.0-or-later as a
KOReader plugin (`android/koreader/LICENSE`, `android/koreader/README.md`). The Xteink overlay
source is MIT (`xteink/LICENSE`), with marked firmware files and the firmware binaries
GPL-3.0-or-later (`xteink/README.md`, “License”). These match main; no licences are changed.

Approved screen layouts:

- Companion Settings › About: BookSync version, full notice at normal body size, browser link
  immediately after the thanks, then Open-source licenses. Scrollable and available while
  settings are locked. The generated asset task and manifest entry deliver this screen.
- BookSync menu › About: scrollable text viewer with version, full notice and visible project URL
  immediately after the thanks. Available while settings are locked. `package.sh` bundles
  the JSON; no QR widget or new KOReader API is needed.
- X4 Pro and X4 Classic Settings › About: notice first in the existing paged system-info list,
  with the same heading/value styling. Two short text lines per row, no new widget or QR.
  When the Settings PIN is locked, its entry offers Enter settings PIN and About; About opens
  without unlocking. Returning leaves settings locked.
- X3 (`default`, also `simulator-X3`): omitted. At 825 bytes below the 99.5% flash gate there
  is no room for the full notice. `CROSSINK_TAILNET_ABOUT_CREDIT=0` removes the strings and
  PIN entry changes at compile time; system-info paging keeps its existing count.
- README Credits repeats the same notice and project link, checked against the JSON.

Firmware generates its header at build time; `source-archive.sh` includes the shared JSON
and generator so the corresponding-source archive remains rebuildable. All retained build
and packaging changes exist only to distribute the About notice.

These screens open only through user navigation. Tests cover the locked companion route,
browser link, locked plugin menu and rendered text, the firmware row provider, the X3 text
exclusion, the plugin zip and README parity. The shared tests run in Android CI and releases.
