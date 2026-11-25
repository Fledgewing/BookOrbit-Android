# Local-first home and catalog: design (draft 2, 2026-11-22)

> **Approved 2026-11-22 PT** (every one-way door; mockups:
> [`mockups.html`](mockups.html), also published at https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk).
> Android code citations into `android/koreader-patch/2-orbit-android.lua` are to the patch as it
> was before roadmap 8a; that code now lives in `android/koreader/orbit.koplugin`
> ([`../orbit-plugin.md`](../orbit-plugin.md)).

ROADMAP items **3** (Local-first home, Android) and **4** (Local-first Xteink catalog, X4 Pro,
X4, X3). Status: designing. Mockups: `mockups.html` beside this file. Nothing here is built.

## Decisions approved by the user (2026-11-22 PT)

| # | Decision | Ruling |
|---|---|---|
| D1 | Local-first only changes what the device shows and never writes to the server. Auto-sync on is the normal case. | approved |
| D2 | Offline, a tap on something that isn't saved asks first: `Connect and open` (or `… download` / `… search`). It connects at once on yes, falls back to `Couldn't connect` / `Try again` only when connecting fails, and queues nothing for later. | approved |
| D3 | The X3 catalog opens from saved lists with no restart and no Wi-Fi. Saved lists have no age limit. | approved |
| D4 | A book finished on Android leaves Continue reading at once and counts toward the goal. It ships in the **same release as item 1** (mark done at end of book), so the server agrees and the book does not come back. | approved |
| D5 | On Xteink readers without touch, Up on a catalog view's top row selects the header refresh button (Up again wraps to the last row; Confirm refreshes). | approved |

Android items 1-3 are built in the new **BookSync KOReader plugin** (ROADMAP 8a, being built now),
not in the user patch. The Android hooks below are written for that plugin.

Draft 2 also takes in the user's review comments:

- Saved lists have **no age limit**. Instead, specific cases ask to update (search, paging, sort).
- There is a **refresh button in the header of every view** on both platforms. The Xteink "Update"
  row is gone.
- Network actions use the same words as the end-of-book work: **Connect and …**, then
  **Couldn't connect / Try again**.
- The freshness stamp now reads **"updated just now"** after a refresh. Draft 1's mockup 2 still
  said "2 h ago".
- New section: **lists by series and by author on the Xteink** (X4 Pro and X4 only), matching
  Android 0.6.0 and local-first like the rest.

Citations are `file:line` at the pins in `tools/upstreams.lock`:

- `P/` = BookOrbit v3.9.0 `c1dd6b4`, `koreader-plugin/bookorbit.koplugin/`
- `S/` = BookOrbit v3.9.0 `server/src/`
- `X/` = CrossInk-Bookorbit `v2.0.0+bookorbit.1-rc2` `5ec6eb0` (the line we build on).
  `X1.6/` = v1.6.1 `d7b4aa8`, which is cloned in `upstream/crossink-v1.6`. Citations added in
  draft 2 are `X1.6/`. In `BookOrbitCatalogBrowserActivity.cpp`, every line checked in draft 1
  was the same in both; re-check these when building.
- `O/` = Orbify at `1de3f82`.

## Outcome

> "The BookOrbit screen sometimes loads the wrong state and then refreshes and shows the right
> one. Could we drive it all from local cache so it's snappy, and it'll refresh from the server
> when it gets to it? I'd like the same for the XTEINK if possible: it shouldn't have to connect
> to wifi for cached data."

Done means:

1. **Android:** opening BookOrbit Home paints **once**, at once, from data on the device, and
   that paint already shows what this device knows (the page you just read to, the book you just
   finished, what is on the device). A refresh that changes nothing repaints only the header's
   stamp. A refresh that changes something also repaints only the tiles that changed.
   BookOrbit's board stays the home screen, with all its widgets and the user's layout.
2. **Xteink:** the catalog opens from the lists saved on the SD card with **no Wi-Fi and, on the
   X3, no restart**, however old they are. Every view has a refresh button that connects and
   updates it. The sleep sync, which already brings Wi-Fi up, refreshes lists in the background.
   Rows for books on the card show this card's progress and finished state.
3. Both platforms use the same rules, the same words and the same header refresh (see "Shared
   concepts").

## Why the Android screen shows the wrong state first (verified)

Opening Home can paint up to three times, and the first paint can be older than the device:

| # | Paint | Source | Why it can be wrong |
|---|---|---|---|
| 1 | Construction paints `initialDashboardContext()` | the persisted `settings.catalog_dashboard_cache` (`P/bookorbit_catalog.lua:332`, `P/bookorbit_catalog_dashboard.lua:26-29, 59-78`) | It is the last **server** body, saved at `P/bookorbit_catalog_dashboard.lua:227`. Reading done since then (progress, a finished book, a new download) is not in it. |
| 2 | On-device hydration finishes and calls `updateItems` | `hydrateOnDeviceMaps` in a subprocess (`P/bookorbit_catalog.lua:614-652`, repaint at `:649-651`) | On the first open after KOReader starts, the "on device" marks are empty in paint 1 and pop in here. |
| 3 | The refresh lands and `switchTo` repaints the whole board | `refreshDashboardOnOpen` (`:93-99`) → `loadDashboardRoot` (`:248-277`) → `switchTo` at `:274` → `P/bookorbit_catalog.lua:847-873` | Unconditional, even when the body is identical. The server can itself lag the device: the lifecycle outbox drains the close snapshot (`P/main.lua:394`, called at `:1310` close and `:1349` suspend) while the refresh is already in flight. |

`BoardData.build` (`P/bookorbit_board_data.lua:628-762`) takes Continue reading, progress, read
status, shelves, goal and streak from the body. Only these are local today:

- `on_device` (`decorate`, `:648-657`, from the `StateManager` maps);
- the heatmap minutes: the larger of the server's and the device's per day (`:165-190`), with a
  120 s TTL (`:26`);
- "today counts toward the streak" (`:720-722`).

The fingerprint (`:755-762`) includes `tostring(body)` and `d.stale`, so a fresh body, even an
identical one, gives a new fingerprint. That resets the widgets' layout memo
(`P/bookorbit_board_ui.lua:111-113`), which costs a re-pick but no visible change: the pick is
deterministic for the same data.

The Xteink Home already works the way the user asks:

- it opens from `bookorbit_home.bin` without the network (`X/src/BookOrbitHomeStore.h:10-14`);
- local recent books take the first rows, ahead of the server's
  (`X/src/components/themes/bookorbit/BookOrbitHomeModel.cpp:91-125`);
- books finished on the device since the last fetch count toward the goal until the server knows
  (`localFinishedAtFetch`, `X/src/BookOrbitHomeStore.h:41-43`).

**The Android design copies those rules**, so both platforms behave the same.

**No refresh button today (verified).** The board's header holds the greeting and the date line,
the device status (Wi-Fi, battery, clock, `P/bookorbit_board_ui.lua:695-714`), search and menu
(`P/bookorbit_catalog_board.lua:151-204`). The list header has back, title, status, search and
menu (`P/bookorbit_list_view.lua:162-200`). Neither has a refresh control:

- KOReader's title-bar refresh icon (`P/bookorbit_catalog.lua:392-395, 456-457`) is replaced by a
  stub on the board, list and detail views (`:411`, `P/bookorbit_catalog_board.lua:92-94`).
- The "Sync" tile's "Sync now" runs the book sync, not a Home refresh
  (`P/bookorbit_board_widgets.lua:1274-1291`, `P/bookorbit_catalog_board.lua:260-261, 931-932`).
- A Home refresh exists as `refreshCurrent` (`P/bookorbit_catalog.lua:474-490`), but it is reached
  only through the detail page's "Refresh from BookOrbit" (`P/bookorbit_catalog_detail.lua:558`)
  and the legacy book-actions dialog (`P/bookorbit_catalog.lua:1655-1658`).

## Shared concepts (both platforms)

| Concept | Rule | Words on screen |
|---|---|---|
| **Saved data** | Whatever the device last got from the server, kept on the device with **no age limit**. Always drawn first. | — |
| **Freshness stamp** | The time of the last successful fetch of what this view shows. It is "updated" while online and "saved" while offline. **It changes the moment a refresh succeeds**, to "updated just now", whether or not the data changed. It then ages ("updated 12 min ago"). Ages are given in min, h and d, as the Xteink Home tile already does (`X/lib/I18n/translations/english.yaml:1012`). | `updated just now` · `updated 3 h ago` · `Offline · saved 3 h ago` |
| **Not updated** | Online, but the server did not answer. | `Not updated · saved 3 h ago` |
| **Refresh button** | A ⟳ in the header of every view. It connects if needed, refetches the view, and lands as a quiet update. | ⟳ |
| **Device wins while newer** | For a book on this device, the device's value is shown when its position or status changed after the server's `lastReadAt`, or when that change still waits to upload. Otherwise the server's value is shown. | — |
| **Not synced** | With auto-sync on, which is the normal case, a change is uploaded within seconds and **no mark is shown**. The mark appears only when the upload is blocked or retrying, or auto-sync is off. | `not synced` (lists only) |
| **Finished here** | A book finished on this device leaves Continue reading, joins Finished, and counts toward the goal until the server knows (the Xteink `localFinishedAtFetch` rule). | `Finished` |
| **Needs Wi-Fi** | Something that is not saved: a list never opened, a page past the saved ones, a book's file, a server search. Offline it is drawn grey. A tap asks first and connects at once on yes. Nothing is queued. | `Connect and open` / `Connect and download` / `Connect and search`, `Cancel`; on failure `Couldn't connect` with `Try again` / `Cancel` |
| **Quiet update** | A refresh repaints only what changed, plus the stamp. Nothing else flashes. | — |
| **Display only** | Local-first changes what the device **shows**. It never writes to the server; the existing syncs do that. | — |

The "Connect and …" wording, and connecting straight away on that tap, match the end-of-book work
(ROADMAP #1, #2). Every action that needs the network brings Wi-Fi up itself.

The shared rule table lives in one fixture (`shared/fixtures/localfirst/overlay-cases.json`,
see Tests) that the Lua and the C++ tests both read.

---

## Item 3: local-first Home on Android

### Where the code lives

`LocalFirst` is a module of the **BookSync KOReader plugin** (ROADMAP 8a). Upstream doesn't accept
contributions, so the BookSync plugin hooks the official BookOrbit plugin at run time.

- **Installing.** When the BookSync plugin starts, it waits until BookOrbit's modules are in
  `package.loaded` (`bookorbit_catalog`, `bookorbit_catalog_dashboard`, `bookorbit_board_data`,
  `bookorbit_board_ui`, `bookorbit_list_view`, the `BookOrbit` plugin instance for
  `enqueueLifecycleSnapshot`). It then wraps methods on those tables with the same
  once-only `wrap` pattern the patch uses today (`O/android/koreader-patch/2-orbit-android.lua:4520-4527`,
  which keeps the stock function in `__orbit_stock`).
  - The list methods live on the catalog class, because `CatalogLists.install` copies them there
    (`P/bookorbit_catalog_lists.lua:1492-1496`), so that class is what gets wrapped. The same holds
    for the board and dashboard methods (`CatalogDashboard.install`,
    `P/bookorbit_catalog_dashboard.lua:299`).
- **Compat.** Before wrapping, the plugin checks that every hooked name exists, as the patch's
  `Compat.missingOn` does (`:4529-4545`). The list is kept in the BookSync plugin's compat table and
  in its `plugin_compat` test, which runs weekly against the pinned BookOrbit plugin. If any name
  is missing, local-first does not install, the board behaves as stock, and one line is logged.
- **Sharing hooks.** The BookSync plugin also hosts the series and author grouping moved from the
  patch, which wraps some of the same methods (`switchTo`, `listRun`, `listHeader`). Each feature
  registers its handler with one wrapper per method, which calls them in a fixed order:
  grouping's tag first, then local-first's overlay. No method is wrapped twice.

### Data on the device

| What | Where | Written by | Notes |
|---|---|---|---|
| Server body | `settings.catalog_dashboard_cache` (upstream) | upstream only (`P/bookorbit_catalog_dashboard.lua:31-34`) | **Never modified by us.** A test asserts that what upstream persists equals what the server sent. |
| Local book state | `<data>/settings/orbit_local_state.lua` (LuaSettings) | `LocalFirst` | Per digest: `bookId`, `percent`, `status` (`reading` / `complete` / `abandoned`), `changedAt`, `sidecarMtime`, `pending`. At most 200 entries; the oldest `changedAt` is dropped first. Disposable: rebuilt from the sidecars if it is missing or from another version. |
| Board's on-device index | same file, `board` key | `LocalFirst` after each paint | Book id → file path for the books the board drew (at most 64). Lets paint 1 show "on device" marks before hydration finishes. |
| Last fetch time | same file, `fetchedAt` per view key (`dashboard`, list keys) | `LocalFirst` when a fetch succeeds | Drives the freshness stamp. The dashboard's `generatedAt` is the fallback. |

Sources for local state, cheapest first. With auto-sync on, source 1 does nearly all the work:

1. **The close and suspend snapshot.** Wrap `BookOrbit:enqueueLifecycleSnapshot`
   (`P/main.lua:394`). The snapshot already carries `digest`, `percentage` and `status`
   (`P/bookorbit_book_sync.lua:67-130`), so recording it costs no extra I/O. It is stored with
   `pending = true`.
2. **The outbox.** While an entry still waits for that digest, `pending` stays true; once the
   entry is gone (acknowledged), `pending` becomes false (`P/bookorbit_lifecycle_outbox.lua:225-245`
   `listMetadata`, read once per open). An entry that `isBlocked` or has a `nextRetryAt`
   (`:247-285`) is what turns on the `not synced` mark.
3. **Sidecars, only when they changed.** On open and on resume, for the board's books that are on
   the device, compare each sidecar's mtime with `sidecarMtime`. Only changed sidecars are read
   with `DocSettings` (`percent_finished`, `summary.status`): up to 5 before paint 1, the rest in
   `UIManager:scheduleIn` steps, each followed by a quiet update. This catches books read in
   another app or while auto-sync was off.

### The overlay

Wrap `BoardData.build` (`P/bookorbit_board_data.lua:628`). Before the stock build runs, the
dashboard body in the context is replaced by an overlaid **copy**:

- **Progress and status.** This applies to each book in `continueReading`, `boardShelves[*]`,
  `finishedThisYear`, `discover` and `yearAgo.book`. If the book is on the device and "device wins
  while newer" holds, `progressPercentage` and `readStatus` come from local state (field names
  `S/modules/koreader/koreader-catalog.service.ts:960-962`). KOReader's `complete` becomes `read`.
- **Continue reading:**
  - a book read here more recently than the head of the list moves to the front;
  - a book finished here leaves the list;
  - a book started here that the server's list lacks is added only if a saved body or saved list
    page has its record (title, cover); otherwise it waits for the server.
- **Finished and goal:** books finished here and still `pending` join the front of
  `finishedThisYear` and add to `readingGoal.completedBooks`.
- **Streak and heatmap:** unchanged; they are already merged with local data.

The copy is memoised on `(body identity, local-state generation)`. The minute clock's rebuilds
(`P/bookorbit_catalog_board.lua:846-874`) therefore get the same table back, and the fingerprint
stays stable. List pages get the same overlay (below).

Item 1 (mark done at end of book) ships in the same release. It sends `read-status=read`, which
the server applies unconditionally (`O/docs/server-contract.md`, "read-status is unconditional"),
so a book finished here is finished on the server too, and it does not come back. As a safety
rule, if the server still disagrees after the device's change was acknowledged (for example, a
status changed in the web app later that day), **the server wins**, and `LocalFirst` logs it once
per book.

### One paint, then quiet updates

1. **Paint 1** stays upstream's construction path. It now carries the overlay (through
   `BoardData.build`), the on-device marks and the stamp. The marks come from
   `StateManager.onDeviceMaps()` when the maps are already in memory
   (`P/bookorbit_state_manager.lua:348-364`), and from the board index otherwise.
2. **Hydration** (`P/bookorbit_catalog.lua:649-651`). Wrap `refreshOnDevice` (`:592`) to compare
   the board's on-device key before and after. If it is unchanged, set a one-shot flag that makes
   the wrapped `updateItems` (`:2056`) skip that one repaint in dashboard mode. Other callers of
   `updateItems` (page turn, edit, rotation) are untouched.
3. **Server refresh** (on open, from the header ⟳, or after a sync). Wrap `dashboardRootFetch`
   (`P/bookorbit_catalog_dashboard.lua:113`) to tag the context it returns
   (`orbit_refresh = true`) and to record `fetchedAt`. Also wrap `switchTo`
   (`P/bookorbit_catalog.lua:847`). When a tagged dashboard context replaces (does not push) a
   dashboard:
   - Compute the **content key** of the old board and the new one: for every tile, a string of the
     data that tile draws (table below). It comes from the overlaid `d`, never from
     `tostring(body)` or `generatedAt`.
   - **Always:** adopt the new context: set `current_context` and `item_table`, so later requests'
     `is_current` checks still hold (`:252-257`). Then repaint the **header** with a `fast`
     refresh so the stamp reads "updated just now". This is the clock's own path
     (`P/bookorbit_catalog_board.lua:846-860`): a few lines of text, no flash.
   - **If some tiles changed:** also `boardRefreshTile` each changed tile (`:811-833`). On a colour
     panel this already uses the dithered partial refresh (`:815-820`).
   - **If the tile set or page count changed** (the layout was edited elsewhere, a page appeared):
     use the stock `switchTo`, one full repaint.

| Tile types (`P/bookorbit_board_widgets.lua` `W.*`) | Content key from `d` |
|---|---|
| `hero`, `also`, `forecast` | Continue reading: ids, rounded %, status, on-device, cover state |
| `shelf` | that shelf's ids, %, status, on-device, cover state |
| `goalpace` | goal books, done, year |
| `streak`, `week`, `today`, `heatmap`, `calendar` | streak, week minutes, today minutes |
| `sync` | `last_sync_at`, online |
| `link` | the counts it shows |
| `highlight`, `yearago`, `records`, `hours` | their record's id or values |
| `clock`, `light`, `word`, decor (`DECOR_TYPES`, `:1899`) | none: they repaint on their own timers |
| any type not in this table | its whole `d`, so any change repaints it (a safe default for new upstream widgets) |

### Header: refresh button and freshness stamp

- **Refresh button (⟳)**, left of the device status, on the board and on every list and detail
  view.
  - **Board and detail:** wrap `BoardUI.statusCluster` (`P/bookorbit_board_ui.lua:696`), which
    both headers build (`P/bookorbit_catalog_board.lua:176`, `P/bookorbit_detail_view.lua:336, 343`).
    Prepend a `BoardUI.hit` icon (`refresh-cw`, already in `P/bookorbit_board_icons.lua:20`) with
    the action `{ kind = "orbit-refresh" }`, and handle that action in a wrapped
    `CatalogBoard:boardRun` (`:882`).
  - **Lists:** wrap `ListView.header` (`P/bookorbit_list_view.lua:162-176`) to add the ⟳ as a
    header region beside search. Handle it in the shared `listRun` wrapper
    (`P/bookorbit_catalog_lists.lua:739`; grouping already wraps it in the patch,
    `O/…/2-orbit-android.lua:4582`). The list's sub line gets the stamp through the shared
    `listHeader` wrapper (`:4638`).
  - The action calls upstream's `refreshCurrent` (`P/bookorbit_catalog.lua:474-490`). It reloads
    the current view, asks for a connection through the user's Wi-Fi policy when offline
    (`runConnected`), and shows upstream's "Updating Home…" pill because the user asked for it.
    Its result goes through the quiet-update path above.
  - The menu sheet and the "Sync" tile keep their own "Sync now", which is the book sync.
- **Freshness stamp** on the header's second line (`P/bookorbit_catalog_board.lua:182-191`).
  Wrap `boardHeader` (`:151`) and pass the stock function a copy of `d` whose `date_long` carries
  the stamp. `date_long` is only drawn here and in a greeting field (`:1178`), which keeps the
  plain date.

| State | Second line | When it changes |
|---|---|---|
| Online, saved data, refresh in flight | `Sunday 22 November · updated 3 h ago` | — |
| A refresh succeeded | `Sunday 22 November · updated just now` | at once, by the header repaint above, even when no tile changed |
| Later | `… · updated 12 min ago` | with the header's minute repaint, which already happens |
| Online, refresh failed (no status code) | `Not updated · saved 3 h ago` | when the request ends |
| Offline | `Offline, saved 3 h ago` (upstream's own words) | when the network drops or returns |

On lists, the same stamp goes in the header's sub line (`count · order · updated just now`);
offline it goes in upstream's band (`P/bookorbit_catalog_lists.lua:1356-1363`).

### Lists and series

- **Phase 1:** the overlay also applies to book lists. Wrap `switchTo` for `context.kind ==
  "books"` and overlay `context.books` with a copy; the saved page from
  `P/bookorbit_list_cache.lua` is left untouched. List rows read `progressPercentage`
  (`P/bookorbit_list_view.lua:558`). Series and author views (Orbify's grouping) take the same
  path. A row is marked `not synced` only under the shared rule.
- **Phase 2:** lists open from their saved page first, then refresh quietly with the same
  content-key rule per row. Upstream keeps the newest 24 pages
  (`P/bookorbit_catalog_lists.lua:141-155`, `P/bookorbit_list_cache.lua:15`) and shows them only
  when the server does not answer (`P/bookorbit_catalog.lua:1149`).

### Out of scope here (ROADMAP #5, #7)

- **USB-added books** have no server match until the plugin matches them, either when the book is
  opened or through its manual sweep (`P/bookorbit_sweep.lua:1-10`). ROADMAP #7 adds a sweep on
  resume.
- **Linking our downloads:** when ROADMAP #5 downloads a book outside the plugin, it must call
  `StateManager.linkFile(digest, fileId, bookId, path)` (`P/bookorbit_state_manager.lua:446-450`)
  so the board marks it at once.

### Failure and staleness (Android)

| Case | Behaviour |
|---|---|
| No saved body, offline | upstream's placeholder (`P/bookorbit_catalog_dashboard.lua:69-78`); the ⟳ offers to connect |
| `orbit_local_state.lua` missing, corrupt or from another version | deleted and rebuilt from the outbox and changed sidecars; Home still paints from the server body |
| A sidecar read throws | `pcall`; that book keeps the server's value; logged once |
| The refresh is cancelled or superseded | upstream's generation check (`:249-268`) drops it; nothing repaints and the stamp keeps its old time |
| A hooked function is missing after a plugin update | local-first off (and the ⟳ with it), stock behaviour, one log line |
| The server disagrees about a finish after acknowledging it | the server's value, logged once (above) |
| The content key throws | fall back to the stock `switchTo` (a full repaint, which is today's behaviour) |

---

## Item 4: local-first catalog on Xteink

### What exists (verified)

| Piece | Where |
|---|---|
| Home, Library and Stats open from `/.crosspoint/bookorbit_home.bin` (magic `0x484F4242`, v3; 3 Continue rows, 2 shelves of 4). The sleep sync or the Home tile writes it. | `X/src/BookOrbitHomeStore.cpp:24-28`, `.h:18-56`; sleep sync `X/src/activities/reader/BookOrbitSyncActivity.cpp:349`; tile `X/src/activities/network/BookOrbitHomeRefreshActivity.cpp:54` |
| Catalog page cache: one JSON file per root, counts, facet page and books page under `/.crosspoint/bookorbit_lists/`; at most 24 KB each; no timestamp and no account key | `X/src/activities/browser/BookOrbitCatalogListCache.cpp:14-16, 36-55, 57-63, 84-92` |
| The cache is cleared on every fresh catalog entry | `X/src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:335` |
| Without Wi-Fi the browser goes back Home | `:383-390` (`onGoHome()` at `:389`) |
| The loaders already take `allowNetwork=false` (cache only) | `loadRoot` `:406-409, 431-437`; facet and books pages `:640-645, 699-704`; paging `:905-975` |
| On the C3, every catalog open restarts into a network boot | `X/src/activities/ActivityManager.cpp:1120-1130` (`X1.6/…:979-989`); the linked open `:1145-1153` (`X1.6/…:1003-1012`) |
| Local sections "On device" and "In progress", drawn from the download index, recent books and `stats_v5.bin` `isCompleted` | `:470-500, 522-560`; `X/src/activities/reader/BookReadingStats.h:8-13` |
| Download index: book id → path, at most 128 | `X/src/BookOrbitDownloadIndex.cpp:14, 19` |
| A book row on the card opens the book (with a silent restart to the reader); otherwise the book downloads | `:1516-1521`, `:1526-1532` |
| On-device marker `•` | `:171`, `:1870` |
| Header controls exist on **touch** readers only, on server book lists only: sort and filter, 44 px, right-aligned. The comment says they are "the Library's, minus its refresh and search". | `X1.6/…BrowserActivity.cpp:59-62, 124-145`; registered only with touch `:298` |
| **Button-only** readers: on a server book list, Left sorts and Right filters, and Up/Down move through the rows. Elsewhere the usual navigator applies, and a move past the end wraps to the top. | `X1.6/…:1704-1724`, `:1739-1744` |
| Touch is detected at run time | `X1.6/include/DeviceCapabilities.h` (`gpio.hasTouch()`), `X1.6/lib/hal/HalGPIO.cpp:217` |
| Catalog search: keyboard entry, then a server search | `X1.6/…:1019-1033`, `:1514` |
| Screens: X4 480 × 800, X3 528 × 792 | `X/docs/user-guide.md:743` |

### Changes (one overlay patch, `v2.0/0025-local-first-catalog.patch`)

C++ functions cannot be link-wrapped, so this is a patch in the series. Like the others it sits
behind a switch, `CROSSINK_TAILNET_LOCAL_FIRST_CATALOG` in `include/CrossInkTailnetCuts.h`, and is
on for all three builds. Only the 2.x line gets it, because v1.6 is being retired after 1.6.1.

1. **Keep the cache, with no age limit.** Drop the `clear()` at `:335`. A new
   `/.crosspoint/bookorbit_lists/owner.json` holds a hash of the server URL and username, plus the
   most recently opened listing keys. The folder is cleared only when that hash no longer matches,
   or on logout.
2. **Stamp each page.** Saved JSON gains `"v":1,"savedAt":<unix s>`. The stamp is 0 when the clock
   is not set, using the same `MIN_PLAUSIBLE_EPOCH` test as `X/src/BookOrbitHomeStore.cpp:39`.
   Upstream's readers ignore unknown keys, and a page without `savedAt` reads as "saved earlier".
3. **Open from the cache.** `goToBookOrbitCatalog` (`ActivityManager.cpp:1120`) first asks
   `BookOrbitCatalogListCache::hasRoot()`.
   - With a saved root, it opens the browser **in place and offline**: no restart on the C3 and no
     Wi-Fi join on any reader. The browser starts in `BROWSING` from `loadRoot(false)`, with the
     stamp `Offline · saved 3 h ago` under the title.
   - With no saved root, it behaves as today: a network boot on the C3, a Wi-Fi join elsewhere.
4. **Refresh button in every view's header**, replacing draft 1's "Update" row. A ⟳ sits at the
   header's right on the root, facet lists, book lists, local lists and search results. Sort and
   filter, where shown, move one place left.
   - **Touch readers** (`gpio.hasTouch()`): a third header control, `HEADER_CONTROL_REFRESH`, in
     the same `fui::ButtonProps` style as sort and filter. It is now registered on every view,
     not only on server book lists.
   - **Button-only readers:** the ⟳ is **focusable**. Up on the first row moves the selection to
     it (drawn inverted, like a selected row); Confirm refreshes; Down goes back to the first row.
     Up on the ⟳ wraps to the last row, so the old wrap is one press longer. The button hints
     say `Refresh` while it is selected. This is the only change to button navigation.
   - **What it does:** online, it refetches the current view (and the counts on the root) and
     redraws only the rows that changed. Offline, it connects at once: on the X4 in place, on the
     X3 through the network boot, which comes back to the same view (below). Then it refetches.
     If connecting fails, the `Couldn't connect` sheet appears.
5. **Browse offline.** Root, every saved facet page and every saved books page open and page as
   they do now, through the `allowNetwork=false` loaders. "On device" and "In progress" work as
   now. Rows whose target is not saved are drawn **grey**: a facet entry whose list was never
   opened, or a book not on the card.
6. **Connect and … (asks first, no queue).** Offline, these open a sheet:
   - a tap on a grey list → `Connect and open`;
   - a tap on a grey book, or `Download` in the long-press menu → `Connect and download`;
   - a page turn past the saved pages → `Connect and load more`.

   On yes it connects at once (X4 in place; X3 by network boot) and carries on with the action.
   `Cancel` goes back. On failure the sheet turns into `Couldn't connect` with `Try again` and
   `Cancel`. The X3 sheet adds `The reader restarts to connect, then comes back here`. It returns
   to the same listing through the existing download-resume record (`BookOrbitDownloadResume`,
   `X/src/activities/browser/BookOrbitCatalogListCache.h:9-37`) or the entry link
   (`ActivityManager.cpp:1145-1153`), extended with the action to finish.
7. **Specific cases instead of an age limit.** Saved lists never expire; the user updates when
   they want. These cases ask, because a saved answer could mislead:

   | Case | Offline behaviour |
   |---|---|
   | **Search** | Search the saved pages and the card (titles and authors in the saved JSON, plus the local sections). With matches: show them, then a last grey row `Search the server for "…"`. With none: the sheet `Not in your saved lists. Update and search the server?` with `Connect and search` / `Cancel`. |
   | **Sort or filter** that has no saved page | If the saved pages hold the whole list (`total` ≤ rows saved), sort or filter those rows on the reader without asking. Otherwise: `This order isn't saved. Connect and sort?` |
   | **Paging past the saved pages** | a grey last row `More (needs Wi-Fi)`; a tap → `Connect and load more` |
   | **A Home shelf link to an unsaved list** | `Connect and open`, then that list |
   | **A saved list that is empty** (for example "Continue reading" after the last book was finished here) | it says `Nothing here on this reader. Connect and update?` rather than a bare empty list |
   | **Wi-Fi already up** in this session (after a download, or a Connect) | no prompts: views refetch quietly when opened, and the stamp says `updated just now` |

8. **Local progress on rows.** For a book row on the card (`bookOnDevice`, `:215-230`), the right
   side shows `57 %` from its `progress.bin` (`RecentBookProgress::loadCachedEpubPercent`, as Home
   does, `BookOrbitHomeModel.cpp:79-82`), or `Finished` when `stats_v5.bin` says `isCompleted`,
   after the `•`. Only visible rows are read (about 10 per page).
9. **Background refresh at sleep.** After the Home snapshot (`BookOrbitSyncActivity.cpp:349`) and
   the cover decode, the sleep sync calls `BookOrbitCatalogListCache::refreshSaved(stop)`. It
   fetches the root and counts, then page 1 of the 4 most recently opened listings from
   `owner.json`. Each request checks the wake press (`sleepSyncWakeRequested`), so a wake ends it
   at once. It runs last in the sync, after progress and Home, and is skipped when the progress
   sync failed, as Home is (`:345-346`).
10. **Retention.** No age limit, only a size limit: at most 96 page files. When the browser exits,
    the files with the oldest `savedAt` beyond 96 are deleted. Pages are already capped at 24 KB
    (`:43`), so the folder holds at most about 2.3 MB and typically a few hundred KB.
    `bookorbit_home.bin` and its covers are not touched.

**Freshness stamp on Xteink.** It sits under the title on every view:

- `Offline · saved 3 h ago`: the view came from saved pages this session;
- `updated just now`: the view was fetched or refreshed in this session, from the moment the
  refresh succeeds, changed or not;
- `updated 20 min ago`: such a view seen again later in the session;
- `Not updated · saved 3 h ago`: online, but the server did not answer.

A list made of pages saved at different times shows the oldest page's age.

**Phase 2 (X4 Pro and X4 only).** When a listing opens offline and its page is older than 1 hour,
start the reader's background task from patch 0022
(`O/xteink/overlay/patches/v2.0/0022-background-sync.patch`, `BookOrbitBackgroundSync`) to join
Wi-Fi and refetch that page. Changed rows repaint in place and the stamp becomes "updated just
now". Not on the X3: a TLS session does not fit beside the UI, as 0022 itself notes.

### X3: restarts and flash

- **Restarts.** Today, every catalog open on the X3 costs one silent restart plus a Wi-Fi join,
  and leaving costs another restart (`:354-365`). With a saved root, opening and browsing cost
  **zero** restarts. Only ⟳, a `Connect and …` or a download costs the network boot, as before.
  Opening a book from the catalog still uses the reader restart (`:1526-1532`), unchanged, to keep
  the patch small.
- **Memory.** Offline browsing runs in a normal boot without TLS, so it does not need the 15-20 KB
  of TLS headroom that forces the network boot (`ActivityManager.cpp:1132-1134`). The X3 heap
  while parsing a 24 KB page, and while searching saved pages (one page in memory at a time), is
  to be measured with the heap log before building on.
- **Flash.** The X3's 2.x build is at 98.8 %. This patch's budget on `default` is **4 KB**,
  measured from the CI size report. The patch mostly removes or reroutes code and reuses the
  loaders, the header-control code and the existing sheet. If it goes over budget, the X3 drops
  features in this order: row progress (8), local sort and filter (7), offline search of saved
  pages (7; the X3 then goes straight to `Connect and search`), grey marks (5). The header ⟳ and
  offline browsing stay. The X3 build is English-only already.

### Failure and staleness (Xteink)

| Case | Behaviour |
|---|---|
| No saved root | today's flow (network boot on the C3, Wi-Fi join elsewhere) |
| A page file unreadable or over 24 KB | treated as not saved (grey); deleted on exit |
| The clock was never set | stamp 0; the header says `Offline · saved earlier` |
| Account or server changed | the `owner.json` mismatch clears the folder before anything is drawn |
| Sleep sync woken mid-refresh | stops between requests; pages already written keep their new stamp |
| A saved book row points to a book deleted on the server | its download fails online as today (detail 404); the page is refetched by the next ⟳ or sleep sync |
| Connecting fails | `Couldn't connect` with `Try again` / `Cancel`; the view stays as it was |

---

## Lists by series and by author on Xteink (X4 Pro, X4)

The user asked for this alongside items 3 and 4. It is not in `ROADMAP.md` yet: add it as a row
("**Lists by series and by author**: any library, collection or smart scope listing grouped by
series or by author, as Android 0.6.0 does", platforms X4 Pro and X4, status designing). The
user ruled that it is **not an X3 feature**: it is compiled out of the `default` build
(`CROSSINK_TAILNET_GROUP_LISTS` 0), so it costs the X3 no flash.

### What Android 0.6.0 does (read from `O/android/koreader-patch/2-orbit-android.lua`)

- **Where it appears.** The list's Sort sheet gets `By series` and `By author` at the top on a
  library, collection or smart scope (`listSortSheetModel` wrap, `:4568-4580`).
- **How it groups.** The patch reads the list's books 100 a page, saying "Reading N of M books…",
  holds them, and groups them on the device (`Group`, `:875-1230`, pure and tested). The server's
  sections endpoint takes no list (`O/android/docs/DESIGN.md:466-470`).
  - Series key: `seriesId`, or the folded `seriesName` when `seriesId` is null (`Group.seriesKey`,
    `:908-914`).
  - Members are in series order (`seriesIndex`).
  - Read buckets follow the server's (`:878-892`).
- **Hooks.** It wraps `loadSection`, `fetch`, `switchTo`, `listRun`, `listSortSheetModel`,
  `listHeader` and `listToolbar`, and the API's `query`, `catalogBooks` and `catalogManifest`
  (`:4386-4406`).
- **Drilling in.** A series or author tapped in a library or collection is requested with
  `libraryId` / `collectionId` plus the list's filters. In a smart scope it is requested by
  `ids=`, capped at 200, and served from the held books past that (`Group.drill`, `:1149-1178`).
- **An author.** Tapping an author shows their books in the list by series, with "Not in a
  series" last (`:1031-1039`) and the chips `By series` / `All books` / `All by author`
  (`:4512-4517`). A series view has `Whole series` (`:4677`).
- **Freshness.** The grouped view is a snapshot until you leave the list.

### What the Xteink has (verified, `X1.6/`)

- A books page holds `id`, `title`, the first `author`, and `seriesName` only under the series
  sort; there is no `seriesId`, `seriesIndex` or read status
  (`X1.6/src/network/BookOrbitCatalogClient.h:33-42`, `.cpp:515-543`).
- Pages are 20 books (`.h:137`); the request takes a `size` (`.cpp:206`).
- The browser keeps a window of 3 pages, 60 rows, in memory
  (`X1.6/…BrowserActivity.cpp:176-179`); patch 0010 packs those rows.
- Its Series and Authors sections are server-wide facets, not scoped to a list
  (`fetchSectionEntries`, `.cpp:551-575`).

### Design

1. **Where the control lives: the Sort options, not the header.** `By series` and `By author` go
   at the top of the list's Sort sheet, as on Android. It is reached by the header sort icon on
   touch readers and by Left on button-only readers (`X1.6/…:1704-1716`). The header stays
   sort · filter · ⟳.
2. **Which lists.** A listing whose query has `libraryId`, `collectionId` or `smartScopeId`
   (`BookOrbitBookQuery`, `.h:66-80`), as on Android.
3. **Reading the list.** The patch requests the list's books 100 a page with a grouping
   projection: `id`, `title`, `authors[0]`, `seriesId`, `seriesName`, `seriesIndex`, `readStatus`.
   The screen shows `Reading 54 of 142 books…`, and Back cancels.
   - The books are held as compact records in **PSRAM**: fixed fields plus offsets into one string
     pool, about 100 bytes a book.
   - **Cap: 2,000 books** (about 200 KB). A longer list groups its first 2,000 and the header says
     `first 2,000 of 3,412 books`.
   - Grouping and sorting are pure functions over the held records, ported from Android's `Group`
     with the same rules: the series key; series order; the reading and finished buckets; author
     previews reading, then finished, then newest; "Not in a series" last.
4. **Views.** These are built from the held records with **no further request**. That includes a
   smart scope past 200 books, so Android's `ids=` cap never arises on the Xteink.
   - `Series in Kids shelf`: one row per series, with its name, first author and book count. The
     right side shows `•` and the number of its books on the card.
   - `Authors in Kids shelf`: one row per author, with the book count and their main series.
   - A series row opens `The Wayfarer books in Kids shelf`: its books in series order, with the
     local-first row values (`• 57 %`, `• Finished`).
   - An author row opens their books **by series**, as series headings with the books under them
     and `Not in a series` last. The Sort options add `All books` (flat) and `All by author` (the
     server-wide author page), standing in for Android's chips. A series view's Sort options add
     `Whole series`. `All by author` and `Whole series` are server views, so they follow item 4:
     open if saved, otherwise `Connect and open`.
   - Sort: `Name` or `Most books`. Filter: `Reading` / `Finished` / all, using the existing
     filter sheet.
5. **Offline (local-first).** After a successful read, the held records are saved as one
   disposable file, `/.crosspoint/bookorbit_lists/group_<hash>.bin` (magic, version, `savedAt`,
   the query key, records, string pool). An unknown version is deleted.
   - Up to **4** such files, the oldest dropped first, under the same account rule as the page
     cache (`owner.json`). That is at most about 800 KB, inside the overall budget.
   - Grouping a list **offline** works when the whole list is on the card: either a saved group
     file for that query exists, or every page of the list is saved (`total` ≤ saved rows, with
     the series fields if they were fetched). It shows `Offline · saved 2 d ago`.
   - Otherwise grouping asks: `Grouping needs the whole list. Connect and read 142 books?`
     (`Connect and group` / `Cancel`). Grouping never works from a partial set, because the
     counts would be wrong.
   - ⟳ in a grouped view rereads the list (`Reading N of M books…`), and the stamp becomes
     `updated just now`.
6. **Local overlay.** Books on the card show this card's progress and finished state, as in item 4
   change 8. A book finished here counts as finished in the buckets and in the series and author
   counts.
7. **Wording, shared with Android:** `By series`, `By author`, `Series in <list>`,
   `Authors in <list>`, `Reading 54 of 142 books…`, `Not in a series`, `Whole series`,
   `All books`, `All by author`, `<author> · 5 books in <list>`.

### Limits and failure

| Case | Behaviour |
|---|---|
| The list has more than 2,000 books | groups the first 2,000 (in the list's current sort); the header says so |
| PSRAM allocation fails | `Not enough memory to group this list` and the flat list stays; logged with the free PSRAM |
| A read fails part-way | `Couldn't read the whole list` with `Try again` / `Cancel`; nothing partial is shown or saved |
| A server without `seriesId` | group by folded `seriesName`, as on Android |
| A book in two series | under its main series only (Android's known limit) |

RAM, timing and flash are to be measured on an X4 before building on: PSRAM headroom with the
font cache, time per 100 books, and the size on `x4-classic`.

---

## Tests (planned, not written)

Shared fixtures go under `O/shared/fixtures/`. They are recorded responses with titles, names and
ids replaced (`O/shared/fixtures/README.md`).

| File | Content | Read by |
|---|---|---|
| `bookorbit/catalog-dashboard.json` | `GET /koreader/plugin/catalog/dashboard` with board shelves | Android tests |
| `bookorbit/catalog-books-recently-read.json` | `GET …/catalog/books?sort=recently_read&readStatus=reading` | both |
| `localfirst/overlay-cases.json` | rows of {server book, device state, pending/blocked, expected % and status shown, list membership, goal delta, `not synced` shown} | `test_logic.lua` and `xteink/test/localfirst_overlay_test.cpp` |
| `localfirst/stamp-cases.json` | {online, fetched this session, fetchedAt, now, refresh result} → expected stamp text | both |

**Android** (the BookSync plugin's Lua tests, run with `luajit` like the patch's `test_logic.lua` / `test_flows.lua`; the path is set by 8a):

- **Overlay cases** from the shared fixture:
  - a newer device position wins;
  - once acknowledged, a disagreeing server wins (the safety rule);
  - `complete` leaves Continue reading, joins Finished and adds 1 to the goal;
  - an unknown started book is not invented;
  - with auto-sync on and the outbox draining, no `not synced` mark.
- **Stamp cases** from the shared fixture: after a successful refresh with no change, the header
  reads "updated just now" and **only the header** repaints.
- **Cache integrity:** the persisted `catalog_dashboard_cache` equals the server body byte for
  byte after an overlaid paint.
- **Memo:** two builds with no local change return the same table, and the fingerprint is stable.
- **Flows**, with `switchItemTable`, `updateItems`, `boardRefreshTile` and `setDirty` stubbed:
  - open with a cache → exactly one paint;
  - identical refresh → one header repaint and nothing else;
  - one shelf changed → the header plus one `boardRefreshTile` for that tile;
  - tile set changed → one full repaint;
  - hydration with unchanged marks → no repaint;
  - offline → `Offline, saved …`;
  - the ⟳ hit on the board, a list and detail calls `refreshCurrent` once.
- **Sidecar reads:** an unchanged mtime → no `DocSettings:open`; more than 5 changed → 5 before
  paint, the rest scheduled.
- **`plugin_compat.lua`:** every hooked name (now including `BoardUI.statusCluster`,
  `boardHeader`, `boardRun`, `ListView.header`, `listRun`) exists in the pinned plugin; a missing
  one turns local-first off.

**Xteink** (`xteink/test/run-host-tests.sh`):

- **List cache:**
  - the stamp is written and read back;
  - a page without `savedAt` reads as "earlier";
  - an owner mismatch clears the folder;
  - eviction keeps the newest 96, with no age-based eviction;
  - an oversize file is "not saved".
- **Pure decision functions:**
  - `catalogOpensInPlace(hasRoot, isC3, hasCredentials)`;
  - `offlineTapAction(entry, saved, onCard)` → open / `Connect and open` / `Connect and download`;
  - `offlineSearch(query, savedPages, local)` → matches, or the "Not in your saved lists" sheet;
  - `canSortLocally(saved, total)`.
- **Button navigation:** from the first row, Up selects ⟳; Up again selects the last row; Down from
  ⟳ selects the first row; Confirm on ⟳ triggers a refresh.
- **Overlay and stamp cases** from the shared fixtures.
- **Sleep-sync refresh:** it stops when the stop check turns true between requests.
- **Grouping (X4 builds only):** the port of `Group` reads
  `shared/fixtures/localfirst/group-cases.json`, generated from the Android `Group` tests' inputs
  and outputs, so both platforms group identically. It covers:
  - a null `seriesId` grouping by `seriesName`;
  - series order;
  - buckets;
  - "Not in a series" last;
  - the 2,000-book cap.

  The record and string-pool round trip is tested, and so are the group file's version mismatch
  (deleted) and the offline check "whole list saved?". A host build with the switch off proves
  the X3 binary has none of it.

**On the devices** (acceptance, by hand once):

- **M8C and Go Color 7:** open Home after reading → one paint, no second flash; tap ⟳ with no
  change → only the stamp line changes to "updated just now".
- **X3:** the catalog opens offline with no restart in the serial log (heap logged); ⟳ → network
  boot → back on the same view, "updated just now".
- **X4 (button-only):** Up to ⟳ and refresh. Offline grey book → `Connect and download`. Wi-Fi off
  at the router → `Couldn't connect` → `Try again`.

---

## Self-grill log

Each entry: question → options → **decision** → why. All are two-way doors (cheap to change in a
later release) unless marked **one-way**. Entries 1-30 are from draft 1, and entries that draft 2
changed say so. Entries 31-42 are new.

### Android

1. **Where does the overlay apply?** (a) only to the saved body at open; (b) to every body at
   build time. → **(b)**: the server body can lag the device (the outbox drain races the refresh),
   so overlaying only the cache would flip back on refresh, which is the very bug. Two-way.
2. **Persist the overlaid body?** (a) yes, so the next open is right; (b) never. → **(b)**: an
   overlay leaking into `catalog_dashboard_cache` would later be shown as server truth. Local
   state has its own file. Two-way.
3. **Which value wins?** (a) always the device's; (b) always the server's; (c) the device's while
   it is newer or pending, then the server's. → **(c)**: it matches the Xteink Home and converges
   with the server and the web. Two-way.
4. **Where does local state come from?** (a) read every sidecar on every paint; (b) the
   close/suspend snapshot, the outbox and changed sidecars only. → **(b)**: no I/O on the common
   path, and it still covers other apps and auto-sync off. Two-way.
5. **A started book the server's list lacks?** (a) build a row from local metadata; (b) add it only
   if a saved record exists. → **(b)**: no invented covers or ids. Two-way.
6. **Goal count?** (a) the server's only; (b) the server's plus pending local finishes. → **(b)**,
   the Xteink rule. Two-way.
7. **How to avoid the redraw?** (a) compare upstream's fingerprint; (b) our own per-tile content
   key. → **(b)**: the fingerprint includes `tostring(body)`, `stale` and `generatedAt`, so it
   always differs. Two-way.
8. **What repaints on a change?** (a) the whole board; (b) the changed tiles via
   `boardRefreshTile`, and the whole board only if the tile set changed. → **(b)**: one partial
   refresh per tile, and colour panels already get the dithered mode. Two-way.
9. **Unknown tile types?** (a) never repaint them; (b) repaint them when anything in `d` changed.
   → **(b)**: a new upstream widget is never stale. Two-way.
10. **The stamp while online.** *Changed in draft 2.* Draft 1 showed no stamp while online, to save
    the header repaint, and the mockup kept an old "2 h ago" after an update, which the user
    caught. → **The stamp shows the last successful fetch, and a successful refresh always
    repaints the header (`fast`, text only) to "updated just now", even with no other change.**
    Why: a stamp that does not move after a refresh reads as a failed refresh. The cost is the
    same small header repaint the clock already makes every minute. Two-way.
11. **On-device marks on paint 1?** (a) wait for hydration; (b) use the in-memory maps, else a
    small board index, and skip the hydration repaint when nothing changed. → **(b)**. Two-way.
12. **Lists?** (a) Home only; (b) the overlay on lists now, cached-first lists later. → **(b)**: the
    overlay is one function, while cached-first lists need their own row diff. Two-way.
13. **USB-added books, linking downloads?** (a) here; (b) in ROADMAP #7 and #5. → **(b)**: both
    need server matching or a download path. The hook points are noted. Two-way.
14. **Patch or plugin?** *Settled by the user:* the BookSync KOReader plugin (8a). Its wrappers follow
    the patch's once-only `wrap` pattern, and grouping and local-first share one wrapper per
    method.
15. **Compat failure?** (a) partial behaviour; (b) everything off, stock board. → **(b)**: never a
    half-hooked board. Two-way.
16. **Push a book finished while auto-sync was off?** *D1, approved 2026-11-22:* never write to
    the server.
31. **Is there already a refresh button?** Checked: no. The header has status, search and menu
    only. The title-bar refresh icon is stubbed out on the board, lists and detail. "Sync now" is
    the book sync. `refreshCurrent` exists but is buried (see "No refresh button today"). → Add
    a ⟳ to the header. Two-way.
32. **Where does the ⟳ go and how is it hooked?** (a) wrap `boardHeader` and rebuild the header
    row; (b) prepend the ⟳ inside `BoardUI.statusCluster`, which the board and detail headers
    both build, plus a region in the list header. → **(b)**: two small hooks reach every view;
    rebuilding the header row would copy 50 lines of upstream. Two-way.
33. **What does the ⟳ do?** (a) the book sync ("Sync now"); (b) refetch this view
    (`refreshCurrent`). → **(b)**: that is what the user asked for ("connects to wifi and
    refreshes the list"); the book sync keeps its own place. Two-way.
34. **The `not synced` mark with auto-sync on?** (a) show it whenever an upload is pending; (b) only
    when the upload is blocked or retrying, or auto-sync is off. → **(b)**: with auto-sync on, the
    upload lands within seconds, and a mark that blinks on and off is noise. The user confirmed
    auto-sync is the normal case. Two-way.
35. **The stamp's wording.** (a) "saved" everywhere; (b) "updated" while online, and upstream's
    "Offline, saved" while offline. → **(b)**: it reads naturally after a refresh, and it keeps
    upstream's offline wording without patching it. Two-way.

### Xteink

17. **Keep the page cache across sessions?** (a) clear it on each entry (today); (b) keep it and
    clear it on an account change. → **(b)**: the outcome needs it, and the card already holds
    the same kind of data (`bookorbit_home.bin`: titles, covers, highlight text). Two-way.
18. **Cache file format?** (a) a new binary; (b) the existing JSON plus `v` and `savedAt`. →
    **(b)**: the cache stays disposable (an unknown version is deleted), so no format has to be
    migrated forever, and readers on older firmware ignore the new keys. Two-way.
19. **Touch `bookorbit_home.bin` (more shelves or books)?** → **No**: it is upstream's format and
    version number, and extending it risks colliding with upstream's next version. Two-way.
20. **Budget?** *Changed in draft 2.* → **No age limit** (the user: "they can always update if /
    when they want"), only the size cap of 96 pages, at most about 2.3 MB, evicted on exit. Two-way.
21. **Open without Wi-Fi?** *D3, approved 2026-11-22.*
22. **Offline tap on something that isn't saved?** *D2, approved 2026-11-22: ask first, no
    queue.* Draft 2 aligns the wording with the end-of-book work: `Connect and …` connects at once
    on yes; `Couldn't connect` / `Try again` appears only on failure.
23. **How to mark unavailable rows?** (a) a glyph; (b) grey text. → **(b)**: the fonts carry `•`
    but may not carry a cloud glyph, and grey costs no flash. Two-way.
24. **Background refresh?** (a) at the sleep sync; (b) also live on the X4. → **(a)** now and
    **(b)** in phase 2 through patch 0022's task; never live on the X3. Two-way.
25. **Which pages does the sleep sync refresh?** The root, the counts, and page 1 of the 4 most
    recent listings; it runs last in the sync and stops on a wake press. Two-way.
26. **Local progress on rows?** Yes, visible rows only, the same reads Home makes. Two-way.
27. **Which CrossInk line?** 2.x only. Two-way.
28. **X3 flash?** A 4 KB budget. *Draft 2* extends the drop order: row progress → local
    sort/filter → offline search → grey marks. The header ⟳ always stays. Two-way.
29. **Open a book from the catalog offline without the reader restart?** Possible, since no radio
    is up, but it adds code; kept as it is. Two-way.
30. **Android Home drops a finished book at once?** *D4, approved 2026-11-22.* It ships with item 1,
    so the book does not come back.
36. **The "Update" row or a header button?** → **A header ⟳ on every view**, and the row goes (the
    user asked). It also matches Android. Two-way.
37. **How do button-only readers reach the ⟳?**
    - (a) make it focusable: Up from the first row;
    - (b) a long press of Confirm on any row that is not a book;
    - (c) a long press of Back;
    - (d) a menu.

    → **(a)**: the control is visible, so it can be discovered, and the same thing is tapped on
    touch readers and selected on button readers. (b) is hidden and inconsistent, because a long
    press on a book opens its menu (`X1.6/…:1675-1681`). (c) risks colliding with Back's Home
    behaviour on some readers. (d) adds a screen. It changes what Up does on the top row, which
    kids may rely on → *D5, approved 2026-11-22.*
38. **Do touch readers get the ⟳ on every view?** Yes. Today header controls exist only on server
    book lists (`X1.6/…:298, 1061`); the ⟳ goes on all views, with sort and filter left of it
    where they apply. Two-way.
39. **Saved lists never expire: where must the reader still ask?** The cases in change 7: search,
    a sort or filter that isn't saved, paging past the saved pages, Home links to unsaved lists,
    and a saved list that is empty. A stale list is otherwise shown as it is, with its stamp.
    Two-way.
40. **Offline search?** (a) always ask to connect; (b) search the saved pages and the card first,
    always offering the server search last. → **(b)**: it answers most "where's that book I saw"
    searches with no restart, and it never claims a book doesn't exist, because the server search
    row or sheet is always there. Two-way (and the first thing the X3 drops if flash runs out).
41. **A sort or filter that isn't saved?** (a) always ask; (b) sort locally when the whole list is
    saved, otherwise ask. → **(b)**: short lists (series, collections) are usually complete.
    Two-way.
42. **Where does the X3 return after a Connect?** To the same view, with the action finished, by
    extending the existing resume record. Two-way.

### Lists by series and by author (Xteink)

43. **Which readers?** *Settled by the user:* X4 Pro and X4. It is compiled out of the X3 build.
44. **Where does the control live?** (a) a new header control beside ⟳; (b) the top of the Sort
    options, as on Android. → **(b)**: same place and words as Android, no fourth header icon, and
    button readers already reach Sort with Left. Two-way.
45. **Group on the device or on the server?** On the device: the server's sections take no list
    (Android finding). Two-way.
46. **How are drilled-in views fetched?** (a) a request per series or author, as on Android
    (`ids=` capped at 200 for smart scopes); (b) from the held records. → **(b)**: the Xteink rows
    need no covers, so the held records have everything. That avoids the cap, works offline and
    saves requests. Two-way.
47. **RAM?** (a) the 60-row window; (b) compact records in PSRAM, capped at 2,000 books (about
    200 KB). → **(b)**: grouping needs the whole list, and the cap keeps a 10,000-book library from
    exhausting PSRAM. To be measured. Two-way.
48. **Offline?** (a) never; (b) from saved pages only when they hold the whole list; (c) also from
    a saved group file. → **(c)**: once a list has been grouped online, it reopens grouped
    offline, which is the local-first promise. A partial set is never grouped, because its counts
    would be wrong. Two-way (the file is disposable).
49. **Android's chips on a button-only reader?** They become Sort-sheet rows (`All books`,
    `All by author`, `Whole series`): a row of chips can't be reached cleanly with buttons.
    Two-way.
50. **Same rules as Android?** A port of `Group` checked against shared fixtures generated from
    the Android tests. Two-way.
51. **Should Android save its held set for offline too?** Out of scope here. It belongs with
    Android's phase-2 cached-first lists. Two-way.

## One-way doors for the user

None open. D1-D5 are approved (see "Decisions approved by the user"). The grouping section adds no
one-way door: its saved file is a disposable cache, and the user scoped it to the X4 readers.
