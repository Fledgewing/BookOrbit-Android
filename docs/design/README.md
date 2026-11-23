# Designs

Feature designs that span both platforms, one file per feature, linked from its
[`ROADMAP.md`](../../ROADMAP.md) row. A design and its mockups need the user's approval before the
item moves to building. Android-only designs are in [`android/docs/`](../../android/docs/).

- [`STATS-DESIGN.md`](STATS-DESIGN.md), [`STATS.md`](STATS.md) (the `orbit-battery-stats/1`
  format) and [`XTEINK-BATTERY-STATS.md`](XTEINK-BATTERY-STATS.md): battery stats on both platforms.
- [`end-of-book/`](end-of-book/DESIGN.md): mark done at the end of a book, the end-of-book
  screen (rating, next in series, author, suggestions). ROADMAP 1 and 2.
- [`local-first/`](local-first/DESIGN.md): local-first Android home, local-first Xteink catalog,
  and Xteink lists by series and author. ROADMAP 3, 4 and 6a.
- [`orbit-plugin.md`](orbit-plugin.md): Orbit as a KOReader plugin (ROADMAP 8a).
- [`emulated-release-tests.md`](emulated-release-tests.md): the release-gate stage that runs the
  hand-tested device scenarios on emulators and simulators against a real BookOrbit (designing).
- [`write-through-cache.md`](write-through-cache.md): one cache in front of BookOrbit on both
  platforms: reads from the cache and revalidated, writes through. ROADMAP 4 and 4a.
- Mockups for end-of-book and local-first: `mockups.html` in each folder, also at
  https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk.
