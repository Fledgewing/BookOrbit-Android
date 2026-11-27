# BookSync 0.12 · Home, in-book menus and settings · design notes (revision 16, round 10 sign-off)

Prototype: `prototype.html` (one file, no network). Screens: `shots/` (M8C at device scale factor 2, its native 1404×1872; X4 at 480×800).
All books, authors, numbers, battery and storage figures are invented.

**Design goal (maintainer, round 2):** with BookSync settings on the reader, you should rarely if ever need the companion
app. The companion stays for first-time setup on the M8C and for the few things only Android can do (section 8).

**Round 3 in one paragraph.** The hero is one plain bar. Stats has a big Year and a small Battery. "Sync, Wi-Fi & power" is
one group with a mode chooser built on the real settings schema. There is one filter sheet behind every filter button, and it
can save a Book list on Home. Pages can be renamed and name themselves after their first widget. Lists gains a 1×3 size,
the X4 default. The Classic focus ring is visible on black. And there is a BookSync library interface (section 12) so the UI
never names a server. Findings and checks are in sections 14 and 15; round 4 is section 16, round 5 section 17, round 6 section 18, round 7 section 19, round 8 (sign in to your server) section 20.

## 1. Design system

### Two render profiles
| | M8C (Carta, 16 grays) | X4 (black and white + 2 grays) |
|---|---|---|
| Ink | `#000` | `#000` |
| Grays | g1 `#555` meta text · g2 `#8c8c8c` bars, outlines · g3 `#cfcfcf` hairlines · g4 `#ececec` wells | `#808080` bars only · `#c0c0c0` hairlines only |
| Meta text | g1 gray | black at weight 400, never gray |
| Text on the black hero | `#cfcfcf` / `#8c8c8c` | white only |
| Heatmap levels | 5 grays + today ring | 5 levels: white with outline, `#c0c0c0`, `#808080`, black, and a today ring; patterns are added only when cells are ≥ 12 px (X4 Year 2×4 cells are about 17 px) |
| Storage bar | patterns (the same on both) | patterns |
| Behind a panel | optional white wash | no scrim at all: a 2 px border and a 6 px white gutter carry the separation |

Dimming behind panels is optional on both devices. On Carta every panel open is a full-screen redraw anyway, and the panel's
2 px black border is what separates it from the page, so the wash is a nicety, not a requirement.
Nothing animates: downloads and syncs advance in steps, panels appear in place.

### Type
UI sans (Avenir Next in the prototype, Noto Sans on device); book titles and reading text in a serif. Tabular figures.

| Role | M8C (logical px) | X4 (px) |
|---|---|---|
| Caption / meta | 12 | 12 |
| Small / list | 14 | 14 |
| Body / buttons | 16 | 16 |
| Sheet titles | 19 | 18 |
| Page title | 25 | 21 |
| Hero book title (serif) | 31 | 24 |
| Big numbers | 36–52 | 28–46 |

### Spacing, shape, touch
- Home grid: M8C 4 × 8, 12 px gutters, 18 px side margins, 58 px page bar. X4 2 × 7, 8 px gutters, 10 px margins, 56 px page bar.
- **Touch targets: at least 50 logical px on both M8C and X4 Pro** (M8C 50 px = 100 physical px ≈ 8.5 mm). Round 1's
  "44 px" claim was wrong; it is now enforced and measured (section 9). How: whole header rows are the "All ›" target;
  rows are 52 px; switches and segmented controls sit in 52 px rows that are the target; stars are 52 px cells;
  steppers and segments are tap + 3 px; the page indicator is a 52 px bar; hero ⋯ is a 52 px circle; the download
  Cancel is a full-width band under the cover.
- Tiles: 1 px g2 outline (black on X4). The hero is the one solid black tile. Panels and sheets: 2 px black border, inset, no shadow.

### Icons
24-unit grid, 2 px stroke, outline. Every widget has its own glyph (Lists = funnel, Book list sources each have one,
Battery = battery, Library = books, Year = grid, This week = chart, filter = funnel, outlined, filled when a filter is active, …). The bookmark toggle in the top panel is
bookmark-plus; the Bookmarks tile is a bookmark list, so they no longer share a glyph. Font and Size use different glyphs.
Header icons (search, ⋯, sync) are all 50 px **outlined** circles; nothing turns solid black while syncing (the label says
"Syncing…" and the glyph steps). Sync (two arrows) and Updates (arrow into a tray) are different glyphs.
The battery glyph is filled to the actual level everywhere (widget, top panel, status bar, mode card, charges).

### Focus (X4 buttons)
One treatment, chosen by what the focused thing sits on, applied by `focusKind()` in the prototype:
- **On white** (rows, white pills, covers on white): a 3 px black ring, a 2 px white gap and an outer ring.
- **A black control** (Resume on white, black pills, the selected TOC row, the hint strip, the toast action): it **inverts**,
  white with black content, inside a 2 px white gap and a 3 px black ring. The fill change alone is visible across the room.
- **On ink** (anything inside the black hero: Resume, the hero ⋯, covers): white fill with black content, a 4 px black gap
  and a 5 px white ring, so the ring separates from the black around it.
- **Whole tiles** (the 1×2 hero that is all Resume, edit-mode tiles): the ring is **inset on the tile's own edge** (4 px black,
  then 3 px white inside it), so it never collides with a neighbour; an ink tile inverts its content too.
- **Segmented controls** (still used in settings and the reader panels): the same treatment as Apply and the hero: white
  fill, bold black text, a 2 px white gap and a 3 px black ring outside the control; a selected segment keeps a ✓ while
  focused. The filter sheet no longer has segments (round 5).
Black, white only: no grays, so it is identical on the X4. Prev/Next move it in reading order; running off a Home page turns
the page and lands on that page's **first widget** (never the header, never the page dots, which are not focus stops).
Starting points: Resume on Home page 1, the first widget on other pages and in Edit Home, the current chapter in Contents,
the value in Go to, the first choice in the filter sheet.
Verified by `r3/focus.js`: 137 steps over every Home page, a page with the hero at every size, both reader panels, Contents,
End of book, the filter sheet and its Group & sort and Show pickers. It counts as dark anything on ink, any black control, **selected segments**
and **covers whose art is mostly dark**. Each dark step must turn white or invert and carry a black ring (a thin inset alone
fails), and every step must differ from its unfocused self. 15 dark steps, 0 fails; shots in `shots/focus/`, inspected.

### Covers
Synthetic grayscale SVG covers with a 2 px white mat on the black hero. A server-only book has a cloud badge that hangs off
the cover's bottom-right corner, so it never covers the author line.

## 2. Widgets

Every widget lays itself out for its box and lists its sizes; edit mode offers only those. The **X3 fallback** column is the
text-only line each widget becomes on the X3.

| Widget | Ships | M8C sizes | X4 sizes | Rendering | X3 text fallback |
|---|---|---|---|---|---|
| Continue reading | 0.12 | 4×3, 4×2, 2×3, 2×2 | 1×2, 2×3, 2×2 | **One plain solid bar** (maintainer ruling): no chapter ticks, no bracket, no chapter words. The line is "**62%** · 3 h 22 m left" at every size. 4×3: eyebrow, serif title, author, series, big "62%" with "3 h 22 m left", the bar, Resume, and "Done by Saturday" beside Resume. 4×2 and 2×3: the short line over the bar. 2×2: eyebrow "READING". **1×2 (X4 default):** biggest cover, 3-line title, the bar, "62% · 3 h 22 m left"; the whole tile is Resume (one focus stop). Details and Reading now use the same bar. Picker description: "Your current book, big: cover, progress, time left and when you'll finish." | The Lantern Room · 62% · 3 h 22 m left |
| **Book list** | 0.12 | 2×2, 4×2, 2×3, 4×3, 2×1 | 2×2, **1×3**, 1×2, 2×3, 2×4, 2×1 | One widget configured by title, source, style, sort and caption (section 3). Cover shelf: one or two rows of covers that fill the height; a narrow, tall shelf (X4 1×3) is a centred **2×2 mini-grid** that starts right under the header and uses the full height (no gap); a wide shelf shows at least 3 covers. Rows with progress: thumbnails twice round 1's size, title, bar, %, last read; 4-wide becomes a cover strip with bars. | Want to read · 37 · Glasswater, Under a Ninth Moon, … |
| Lists | 0.12 | 2×3, **1×3**, 2×2, 4×2 | **1×3**, 1×2, 2×2, 2×3 | Your saved lists with live counts. Rows ≥ 52 px fill the tile evenly. **1×3 (narrow):** no icon wells, no chevrons, about 4 lists; on the X4 one line with the count on the right; on the M8C (171 px wide) the name takes two lines with "N books" under it. | Lists · Short reads 84 · Unread SF 132 · … |
| Library | 0.12 | 2×1, 2×2, 1×1 | 2×3, 1×2, 2×1, 1×1, 2×2 | Library count on the left. **On device, right-aligned, no divider**, with a thin storage bar and "4.2 GB free of 32" under it (the extra number the maintainer asked about: free space, because space is the constraint people act on). Low space: warning glyph + "Low space · 1.2 GB free". 1×1: count + free figure only. 2×2+: Authors / Series / Collections rows, which open the Library list grouped by author or series. | 2,418 books · 312 on device · 4.2 GB free |
| **Battery** | 0.12 | **2×2** (default), 1×2, 2×1, 4×3, 2×3, 4×2 | **1×2** (default), 1×1, 2×2, 2×3, 2×1 | Small: glyph at the actual level + big level + "**≈ 2 d 6 h at your usual use**" (1-wide sizes: "≈ 2 d 6 h · usual use"); the two other figures are always labelled "reading non-stop" and "standby only"; 2×1 no longer clips (measured in the sweep). Medium (2×2): adds reading 4.1 %/h and standby 0.6 %/h (one decimal), "76% used this week" and the last charge. **No daily bars**, so Stats never has two near-identical bar charts. Large: adds reading ± and standby ± %/h, % per 100 pages, charging rate ±, and the last charge ("Sun 21:10 · 12% → 100% in 2 h 20 m"). Hidden values follow the "—" + what's needed rule. | 78% · ≈ 2 d 6 h at your usual use · reading 4.1 %/h |
| This week | 0.13 | 2×2, 2×3, 2×1, 1×2 | 1×2, 2×2, 2×1 | Every column is the same height; the best-day label floats above its bar, so Saturday (112 min) is now taller than Sunday (95). "Best day" is computed, not typed. | 7 h 8 m this week · best Sat 1 h 52 m |
| Year in reading | 0.13 | **4×3** (default), 4×2 | **2×4** (default), 2×3 | Dot grid, 52 × 7. M8C: 5 grays. X4: five levels (section 1), patterns only when cells are ≥ 12 px. Legend: Less ▢▢▢■ More · ◎ Today. Always the largest tile on Stats. | 257 days read · 41 books · streak 12 |
| When you read | 0.13 (restored on Stats) | 2×2, 2×3, 2×1, 4×1 | 2×1, 2×2, 1×2 | **M8C 2×2 and larger: 24 hourly bars** that touch (no gaps, one gray), the peak hour black with a ▼ "22:00" marker above it, and an hour axis. That makes it unlike This week, which has separate, labelled day columns. **2×1, 4×1 and the X4:** a shaded 24-hour strip, peak ringed. "Evenings · most at 22:00". | Mostly evenings · peak 22:00 |
| Reading records | Later | 3×2, 2×3, 2×2, 4×1 | 2×2, 2×3 | Pages turned as the hero number, a hairline, then four stats; the streak line fills the foot. No empty left column. | 48,210 pages · longest 3 h 12 m · streak 12 |
| Clock | Optional | 1×2, 2×1, 2×2 | 2×2, 1×1, 2×1 | Time and date. Its battery is now only a small link ("▭ 78% ›") into the Battery page. 1×2 fills the column (bigger time, sync line, battery link). | 21:42 · Tue 25 Nov |
| Recommended, Discover | Later | — | — | Picker only. | — |
| Highlight, Buddy, Year ago, Word, Light | Android implemented | 2×1 / 2×2 | — | Companion projections; firmware later. | Device acceptance pending. |

## 3. Book list: one widget, many lists

- **Configuration:** `{title, src, style, sort, cap}`.
  - source: **Custom filter** (any filter sheet result, section 11) · Recently added · Want to read · Reading now (without the Continue reading book) · Finished · On device · any of your Lists · a series · an author;
  - style: Cover shelf or Rows with progress;
  - sort: List order, Title, Author, Last read;
  - caption under each book: none, date added, progress, author.
- **The picker keeps friendly names.** "Also reading", "Recently added", "Want to read" and "Finished" are presets: each adds
  a Book list already configured. "Book list (choose a list…)" adds one and opens its configuration at once. In code
  (`W.booklist`) there is one render function; the presets are configurations, and the layouts store `{w:'booklist', cfg}`.
- **Configuration sheet:** in Edit Home a selected Book list has **Configure** in the toolbar. On the X4 Classic, More on a
  widget opens its options (Pick up to move, Configure, Next size, Remove). The sheet is five rows (Title, Source, Style, Sort,
  Caption, plus **Filter** when the source is Custom filter, which opens the filter sheet) and Cancel/Done; Source opens a second, paged page (Built in, Your lists, Series, Authors) with counts. No scrolling;
  every row is one focus stop. The Classic has no keyboard, so Select on Title steps through suggestions.
- **The shared List screen** is every "All ›": Book lists, Lists rows, Library and On device. Its header has the **filter
  button** (section 11), which holds grouping (None / Author / Series) and sort; active parts show as chips, and there is paging. Grouped by series it shows series headers in name order, books in reading order, and
  the Series page's progress dots; a header opens the Series page. Grouped by author it shows author headers. This is where the
  old Authors and Series organisation lives. A group that shows only some of its books says "All N ›" ("Not in a series" shows
  "All 17 ›"); a group that already shows every book says "N books" with no link (round 4). A series header still opens its
  Series page. Reading now, ungrouped, keeps its Active / Put down sections and pages them.

## 4. Default layout

**M8C, page 1 "Home"**:
```
┌──────────── Continue reading 4×3 ────────────┐
├────────────────────┬─────────────────────────┤
│ Also reading 2×2   │ Lists 2×3               │
├────────────────────┤                         │
│ Library 2×1        │                         │
├────────────────────┼─────────────────────────┤
│ Recently added 2×2 │ Want to read 2×2        │
└────────────────────┴─────────────────────────┘
Header: Home · [✓ Synced 12 min ago · Sync] · Search · ⋯
```
**Lists 1×3 on the M8C (tried, not the default).** It reads well (two-line names, count beneath), but page 1 would then need
a 3-wide partner beside it, and every Book list is 2 or 4 wide. A 1-wide Lists leaves a 1-column hole or forces Library and
Also reading into odd shapes, so page 1 would no longer be filled. The default stays 2×3; 1×3 is offered in Size.

**M8C, page 2 "Stats":** Year in reading **4×3** · Battery **2×2** + When you read 2×2 · This week 2×3 + Reading records 2×3.
One bar chart (This week); Battery shows rates, not bars.

**X4, page 1 "Home":**
```
┌ Continue reading 1×2 ┬ Also reading 1×2 ┐
├ Lists 1×3            ┼ Want to read 1×3 ┤   (narrow Lists ≈ 4 rows; Want to read a 2×2 mini-grid)
├──────── Recently added 2×2 ─────────────┤
```
**X4, page 2 "Library"** (renamed for its contents: the library at a glance): Library **2×2** (count, on card, storage bar,
Authors) · On device 2×3 (books on this reader with progress) · Finished 2×2.
**X4, page 3 "Stats":** Year in reading **2×4** (largest; cells about 17 px, patterns allowed) · Battery **1×2** + This week 1×2 ·
When you read 2×1. Reading records and Clock are in the picker.
Fuzz on these defaults: 400 random edit actions per device, no overlaps, no errors (section 15).

## 5. Edit Home

- Edit mode dims each widget with a dashed outline and a name·size tag in the **bottom-right** corner (never over a header).
- Selected widget: the header shows its name, Configure (Book list), Remove and Done. The **footer becomes the move bar**:
  ← ↑ ↓ → and **Size "4×2 → 2×3"** (current size, then the next one; "no room" if nothing else fits).
- **Move rule.** An arrow moves the widget one cell if the cells are free. If they are not, the widget swaps with the minimal
  band of widgets it must pass: the band is every widget that overlaps its columns (or rows) from its edge onwards, grown until
  no widget crosses the band's far edge. The band shifts back into the space the widget left, keeping its order, and the
  widget lands just past it. Example (maintainer's screenshot): Reading records 4×1 under the hero, Down → Also reading,
  Library and Lists each move up one row, and Records lands directly above Recently added. Arrows are greyed only at the page
  edge. If no valid swap exists (a 1-wide widget under a 2-wide band would overlap its neighbour), the arrow offers
  "Move to page 2" (or "a new page") in a toast with one action. After every move the whole page is checked for overlaps.
- **X4 Classic:** focus starts on the first widget; only the toolbar, widgets, + slots and page controls are focus stops.
  Select picks a widget up; Prev/Next carry it with the same move rule (right, then down at the edge); More steps its
  size; Select drops it; Back cancels and restores the original position and size. A black hint strip in the footer says so.
  "Move to page 2" is taken by pressing Next again. More on an unselected widget opens its options.

- **Edit tips** (side panel and Classic hint strip) state the move rule in one line and say Configure is for Book lists:
  source, title, style, sort, caption.
- **Edit tags** straddle the tile's bottom edge, so they never cover a caption or a cover's title.

### Page names
- **New pages name themselves** from their first widget: Year in reading, Battery, This week, When you read or Records →
  "Stats"; a Book list → its title; Lists → "Lists"; Library → "Library". Until then the page is "Page N". A name you set by
  hand is never overwritten (`named: true`).
- **Rename:** in Edit Home the page name in the header is a button with a pencil (≥ 50 px), and **Rename** sits next to
  **+ Page** in the footer. Both are Classic focus stops. Settings › Home › Page names opens Edit Home with Rename ready.
- **M8C:** a text field typed with **KOReader's own keyboard** (the prototype draws a stand-in), plus suggestion chips.
- **X4 (no keyboard):** a paged list of names: Home, Reading, Library, Lists, Want to read, Stats, Shelves, Series,
  Favourites, Page N. On the Classic, Select on the Name row cycles through them; Prev/Next and Select also work on the list.
- **X3:** the same list as text: `Page 3: Stats  [Select: next name]`.

## 6. In-book

- **Reading page:** the text, the optional clock, and the status line, which now starts with the battery:
  **battery % · chapter title · pages left in chapter · page / total**. Settings → Reading → Status bar shows a live preview.
- **Top panel:** Home · title/author · **Sync** · settings gear · bookmark-plus. Sync is a 50 px icon button in the header
  row (not a sixth tile: the tiles are the book's contents, sync is about the book's state, like the bookmark). Tapping it
  says "Syncing…", then "Synced · p. 211 saved". If the server has a further position: "Your other device is at p. 240 ·
  Jump there / Stay here". Offline: "Offline · will sync when connected". The summary line adds the battery estimate:
  "Chapter 14 of 22 · 62% · 3 h 22 m left in book  ▭ ≈ 2 d 6 h left at your usual use" (the estimate is a link to
  Battery; on the X4 the two parts wrap as whole phrases onto two centred lines).
  The "other device is further" sheet names the device and when: "Your Phone is further · Phone · 2 h ago: p. 240 · This reader: p. 211" (the device name the server reports), with
  Jump there / Stay here, and says which rule decided it (Reading position: Furthest page wins).
  **Why Sync stays here:** the maintainer's round-2 comment asked for manual sync in the in-book top panel; the round-3 ruling
  ("Sync placement: keep header sync; remove Sync now from the ⋯ menu") removed only the duplicate from Home's ⋯ menu, so the
  top panel and the Home header are the two places, one per context.
- **Bottom panel:**
  - Scrubber with chapter ticks and bookmark flags. On the Classic, Select on the scrubber grabs it; Prev/Next then move one
    chapter, Select or Back lets go.
  - **Quick-settings presets.** Font, Margins, Line spacing and Contrast each show three choices: two presets plus Custom.
    Font: Book's own (the publisher's embedded font) · your chosen font · Custom. Custom applies your own saved values
    (it shows them, e.g. "Custom · 46 px") and never opens KOReader. Once Custom is picked it shows a pencil: tap it again
    to edit it (§23). The presets and the custom values live in Settings → Reading. Size
    stays a stepper. Every font specimen is named.
  - **All steppers wrap** (X4 Font/Size/Margins/Spacing/Contrast rows, the M8C Size stepper, the Settings steppers):
    past the last option goes to the first and back. No arrow is ever greyed. Sliders (front light, warmth) and the Classic
    Go to stepper stay bounded.
  - "More reading settings… KOReader's style menu" and "Edit presets" (to Settings → Reading) close the M8C panel.
  - X4: the "no front light" line is gone; Status bar and Clock are 52 px switch rows.
- **Contents** pages by whole rows (a section header never ends a page; `pagedSpan`). The scrubber's grab hint sits 14 px
  below the track, clear of the focus ring.
- **Sheets:** Contents focuses the current chapter; Go to focuses the value. Classic Go to is a ‹ value › stepper:
  Prev/Next step, More cycles the step (1, 10, a chapter), Select goes.
- **End of book:** rating (52 px stars), next in the series, "Add *next title* to Want to read" (a checkbox row), Home and a
  "Back to book" text button.
- **Series page:** rows show status only (Read ★★★★ / 45% reading / On device / On server); the Back button has room to
  breathe on the Classic.

## 7. BookSync settings

Reachable from Home ⋯ › BookSync settings and from the gear in the top panel. On the X4 these are the device's own settings
for the same items. One page of **eight** groups (icon, name, current value); each group is a paged list of rows with plain labels
and visible current values. No scrolling. Every row is one focus stop: Select steps a choice (wrapping), flips a switch, or opens.

| Group | Rows |
|---|---|
| **Your server** (section 20) | Signed in: Signed in as · Your server · Connection · What BookSync set up ("Sync login: found · OPDS: created · stats from all your devices") · Sign in again… · Sign out (asks first). Signed out: Sign in to your server · Until you sign in (stats from this reader only) |
| **Sync, Wi-Fi & power** | Sync now · **Mode** card · (Back to Balanced, only when Custom) · What the mode does: Wi-Fi, Off after idle, Sync while reading, Sync when the reader sleeps, Sleep sync limit, Sync when it wakes · Android only: Let BookSync switch Wi-Fi for syncs, Wake VPN for syncs · Reading position · Power: Sleep after, Battery › |
| Library & downloads | Storage › · Download folder · Keep downloaded copies current · Offline catalog storage · Mirror covers · Full refresh |
| Reading | **Font choices** (one merged row; its subtitle shows what the panel offers: Book's own · your font · Custom with its value) · Margin, Line spacing and Contrast presets (custom presets show their value, e.g. "Custom · 14 px") · Custom font / margins / line spacing / contrast, each opening its editor · Use KOReader's current values (M8C) · Status bar · Status bar shows · Status bar size · End of book sheet |
| Home | Edit layout · Reset layout · Home screen (BookSync / Server plugin's Home; the summary reads "BookSync Home · 2 pages") · **Page names ›** |
| Sleep screen | Cover shown · Never show · Text · Battery level · Text placement |
| Updates | **Update channel** (one row: "Update channel · RC" with the channel's one-line description; it opens a picker) · Check now · **Installed: BookSync 0.12.0-rc.2 · RC** · What's new. Summary: "RC channel · 0.12.0-rc.2" |
| About & help | Version (**BookSync 0.12.0-rc.2 · RC**, the same string as Updates › Installed; summary the same) · This reader · Help and guides · Advanced: open companion app (Android only) |

Update channels are chosen in a **picker**, the same pattern as the filter sheet's single-value pickers (maintainer: "picking
channel should be a dropdown not selector"): radio rows, each with its one-line description, the current one marked and
the installed build's channel labelled "installed build". Picking one returns to Updates; Back returns without changing it.
On the Classic, Select on the row opens it with focus on the current channel. The channels: **Stable**, the releases most people should run; **RC**, the builds about to become Stable, for people who
want fixes a week early; **Preview**, every test build, which may break. The installed row always names the channel of the
build you have.

### How Sync, Wi-Fi & power works
- **One mode on top, every setting visible below.** The Mode card (Battery saver / Balanced / Always up to date) shows the
  battery impact at your usual use: ≈ 2 d 11 h / ≈ 2 d 6 h / ≈ 1 d 8 h (estimated: Wi-Fi-on reading is not measured yet). Under it,
  "What Balanced does" lists the rows it sets, with their values. Classic: Select on the card steps to the next mode.
- **Changing any row makes the mode Your own settings**: the card says "Your own settings" and a **Back to Balanced** row appears.
  Nothing is locked: a row that has no effect in the current mix stays changeable and says why ("Only used when Wi-Fi is
  Just in time"), with an info glyph.
- **Real settings** (`shared/settings/schema.json`):

| Row | Setting | Choices | Balanced (= schema default) | Depends on |
|---|---|---|---|---|
| Wi-Fi | `wifi_mode` | Always on / Off while reading / Just in time | Just in time | — |
| Off after idle | `wifi_idle_min` | 1, 2, 5, 10 min | 2 min | Wi-Fi = Just in time |
| Sync while reading | `reading_schedule` | Off · every 10/15/30/60 min · every 25/50/100 pages · each chapter / 2 chapters | Off | Off while reading: syncs wait until you close the book (said inline) |
| Sync when the reader sleeps | `sync_on_sleep` | on/off | on | — |
| Sleep sync limit | `sleep_cap` | 10 / 15 / 20 s | 20 s | Sync when the reader sleeps |
| Sync when it wakes | `sync_on_wake` | on/off | on | — |
| Reading position | `sync_mode` | Furthest page wins / KOReader decides (M8C) | Furthest page wins | X4: shown as info, no choice |
| Let BookSync switch Wi-Fi / Wake VPN for syncs | `wifi_via_companion`, `wake_tailscale` | on/off | — | **Android only: hidden on the X4 and X3** (not applicable in the schema) |

- **The reading-position rule** is its own row: *Furthest page wins*: BookSync keeps the furthest place you have read on any
  device and asks before jumping. *KOReader decides* (M8C only) leaves it to KOReader's own progress-sync rules; the X4 shows
  the rule as information, since there is nothing else to pick. (position-sync.md §6 hides sleep and wake rows under this
  preset on the companion; we keep them visible so nothing is hidden.)
- **X4:** `sleep_cap` and `sync_on_wake` are partial on the X4 firmware (it sleeps hard): they are shown and work as
  best effort there; this is a notes-only caveat, not on screen. "Wi-Fi off while reading" is a Wi-Fi choice, not a standby rate: the Battery page's standby rates are by
  Wi-Fi mode, one decimal.
- **Paged**, Select cycles on the Classic, swipe turns the page.

### Battery page
From the Battery widget, the top-panel estimate, the Clock's battery link, and Settings → Wi-Fi & power. Four tabs:
- **Overview:** level and "≈ 2 d 6 h left at your usual use", then how the estimate is made: reading non-stop 19 h = 78 % ÷
  4.1 %/h; standby only 5 d 22 h; "Your usual use: screen on 25% of the time, last 7 days" (the share that blends the two). Then per 100 pages, per 100 full refreshes (X4: "— 64 of 100
  refreshes needed"), charging rate. Export (both); Compare with another reader (Android only, imports an export).
- **Rates:** reading by content, Wi-Fi mode and front light (M8C); standby by Wi-Fi mode; each ± its standard error, hidden
  values as "— 0.4 h of 1 h needed".
- **Daily:** 14 days, 7 per page: % used as a bar, screen-on time, pages, full refreshes, a bolt on charge days.
- **Charges:** the last five charges as glyph + from → to + duration, and the charging rate.
Definitions follow STATS-DESIGN.md "Statistics (exact definitions)" (time left = level ÷ (f·R_reading + (1−f)·R_standby)).

### Storage page
From the Library widget's storage bar and Settings → Library & downloads. One stacked bar of the device (M8C) or SD card
(X4): Books (solid), Covers and offline catalog (hatched), Apps and system / Other files on the card (dotted), Free (white).
Patterns, not grays, so it reads on the X4. Under it, each action says **what it frees**: Remove books not opened in 6
months (2.4 GB · 41 books), Remove finished books (84 MB · 9 books), Clear cover cache (40 MB), Catalog cache limit. Every
removal says server copies and progress are kept, and once done the row disappears and the figures update everywhere
(widget, page, bar).
**Low space only warns.** Below 10 % free the Library widget and Storage page say "Low space: 1.2 GB free. Downloads still
work. Free 2 GB more to get back above 10 % (3.2 GB)". **A download is blocked only when it would leave less than 200 MB**:
then Download next 3 says "Not enough space · free 180 MB" and its sheet gives **needed vs freed**: "This needs 8 MB, and
BookSync always leaves 200 MB free so the reader keeps working. Only 180 MB is free. Removing books you haven't opened in 6
months frees 2.4 GB." The shell's Space control has Normal / Nearly full / Below the floor, and the demo numbers agree on
every screen.

### Home header sync
"✓ Synced 12 min ago · Sync" is the button: "Syncing…", then "Synced just now". Offline it is the Offline chip and not
tappable. It is its own focus stop on the Classic. **"Sync now" is no longer in the ⋯ menu** (the header is the one place).

## 8. Companion is rarely needed

Day to day, everything is on the reader: account, sync, downloads, storage, reading presets, status bar, Home, sleep screen,
Wi-Fi and power, battery, updates.

**Signing in** is one sign-in with your server account (section 20):
- **M8C (Android):** the form on the reader, typed with KOReader's keyboard. The companion still does first-time install
  (KOReader and defaults).
- **X4:** typing a password with five buttons is impractical, so Sign in shows **"Sign in from your phone"**: a short code
  (K7Q 4M2) and a QR. The phone, on the same Wi-Fi, scans it (it opens the reader's own sign-in page, served by the
  firmware's File Transfer web server) or enters the code in the companion app under **Add a reader**; you sign in to your
  server there and the reader finishes by itself. "Type it on this reader instead" opens the same form with the firmware's
  keyboard. This replaces round 3's `/settings` page as the main path.
- **X3:** `Sign in: on your phone open the companion app › Add a reader › code K7Q 4M2`, then a line that changes to
  `Signed in as reader`.

The companion is still needed (M8C only) for:
| Task | Why only the companion |
|---|---|
| First-time setup on the M8C | BookSync isn't configured yet, so there is no reader UI to do it in |
| Set the Android Home app | Android only lets a regular app request the Home role through system settings |
| Battery optimisation exemption | An Android system permission |
| VPN / Tailscale | Android VPN service, outside KOReader |
| Compare battery with another reader | Imports another device's export file; Android-only by design |
| Anything KOReader can't do | Outside KOReader's process |

## 9. Why we page, not scroll
E-ink redraws are slow and ghost; a scroll is dozens of partial refreshes that smear and drain battery, while a page turn is
one clean refresh you can predict. Paging also gives the Classic's buttons a natural unit (Prev/Next page) and makes
positions stable ("Page 2 of 3"). So **every** list and sheet pages: Home, settings groups, lists, Contents, the filter
sheet and its pickers, Rename. **A horizontal swipe turns the page** on every one of them (the same as the ‹ › buttons), and
paging never splits a row or leaves a section header alone at the bottom of a page.

## 10. X3 text fallbacks
The X3 has text only. Each item becomes a line; the cursor is `>`.
- **Widgets:** the X3 column in section 2.
- **Battery tabs:** `Battery 78% ~2d6h | [Overview] Rates Daily Charges`, then lines such as `Reading 4.1 %/h ±0.3`,
  `Standby 0.6 %/h ±0.1`, `Mon 9%  2h10m  212p`, `Sun 21:10 12%→100% 2h20m`.
- **Storage bar:** `Books 6.8G | Cache 0.25G | System 23.8G | Free 1.2G` then `Low space: 1.2 GB free (warn only)`.
- **Settings rows:** `Wi-Fi: Just in time  [Select: next]`, `Sleep sync limit: 20 s (only with sleep sync)`,
  `Mode: Balanced ~2d6h`.
- **Filter sheet:** see section 11.
- **Rename:** section 5.
- **Sign in:** section 8.

## 11. The filter sheet (a reusable building block)
One component, `filterView`, behind **every** filter button: List screens (any "All ›"), Search, a List's own view,
Reading now, and the library grouped by Series or Authors. It is also a Book list's **Custom filter** source.

**One screen, no paging, on every device (round 5).** Every part of the filter is one row that shows its current value and
opens a picker page. Rows, in this order (a row a context doesn't use is hidden):

| Row | Picker | Default |
|---|---|---|
| Show | radio: All / Unread / Reading / Finished / Want to read (this absorbs the old "Want to read only" switch) | All |
| Where | radio: Anywhere / On this device / Server only (hidden in On device, where it can't change anything) | Anywhere |
| Author | checkboxes with counts, paged only when it doesn't fit one page, Clear N | Any |
| Series | checkboxes with counts | Any |
| Tags | checkboxes with counts | Any |
| Length | radio: Any / Short (under 250 pages) / Medium (250 to 450) / Long (over 450) | Any length |
| Rating | radio: Any / 3★ and up / 4★ and up / 5★ only | Any rating |
| Added | radio: Any time / This week / This month / This year | Any time |
| Group & sort | Group (Not grouped / By author / By series), then Sort by (context-dependent; Search adds Best match, its default), then Order; one page | "Not grouped · List order" |

- **Every row works the same way:** tap or Select opens its picker; Back returns. No row cycles in place. Multi-value
  pickers keep checkboxes; single-value pickers use radio rows.
- **One counting rule for every picker (round 6):** each option's count is the number of books you would get with **every
  other filter applied and this picker's own choice left out** (`fApply(books, {...filter, [this]: none})`, then match the
  option). So with Length = Short, Author shows only the short books per author, and "Short · under 250 pages · 3" is
  three books under the other filters. Values with no books under the other filters sort **last, in gray, with no number**;
  a value that is already ticked always stays in the list.
- **One source for every number on a list screen:** the list's subtitle, the footer's "Show N books" and every picker count
  all come from the same query (`books.query`; `fApply` in the prototype), so they always agree. The prototype's browsable
  sample is 30 books; the Home widgets' headline totals (2,418 in the library, 312 on the device) are illustrative scale
  and are not wired to the sample. In the real build both come from the library interface (`library.summary()` and
  `books.query`).
- Pickers show a page bar only when they have more than one page (no "Page 1 of 1" with dead arrows). Choosing a radio option returns to the sheet at once; the Group &
  sort picker stays open until Back, since it holds three choices.
- **At a glance:** a row at its default shows its value in normal weight; a changed row shows it **bold with a small dot**.
  One thin black divider separates the filters from Group & sort; no section headers.
- **Footer:** "+ Save as a Book list on Home" as a small secondary action, then **Reset** and **Show N books** (live count).
  Reset returns to the context's defaults.
- **Fits:** 9 rows of 58 px (X4) or 64 px (M8C), plus header and footer, inside the 460×740 card on the X4's 480×800 screen,
  measured by `flows3.js` (every row ends above the footer; none is under 50 px).
- **Active filters** appear as removable chips in one row under the list's header; no row at all when nothing is active.
  The filter icon is filled when active, and the subtitle summarises it: "2 books · Unread · on device · by author".
- **Save as a Book list on Home** adds a device-local Book list with source *Custom filter* (in the first space that fits,
  otherwise on a new page that auto-names after it), with a toast to go there. There is no "Save to server lists" row in 0.12
  (section 12).
- **Classic:** focus starts on Show; Prev/Next move across the rows and the footer; Select opens a picker (focus on the
  current choice); in a picker Select chooses (radio, which returns) or toggles (checkbox); **Back closes the picker, then the
  sheet, and applies.**
- **Output:** a neutral filter object, `{show, where, author[], series[], tags[], len, rating, added, group, sort, dir, q}`,
  which is handed to `books.query` (section 12).
- **X3:** the same nine lines as text, `Show: Unread*`, `Where: Anywhere`, … `Group & sort: By author · Title A–Z*` (`*` =
  changed), Select opens a numbered list, Back applies.

## 12. BookSync library interface (what the UI needs)
**The UI never names a server API.** Every screen talks to one BookSync library interface; a **BookOrbit adapter** and a
**Grimmory adapter** implement it. Each operation is marked local (device only), server (via the adapter) or both (cached
locally, refreshed from the server).

| Operation | Where | Used by |
|---|---|---|
| `library.summary()` | both | Library widget, header counts |
| `books.query(filter, group, sort, page)` | both | every list, Search, Book lists, the filter sheet's live count |
| `books.get(id)` | both | Details, Series rows |
| `lists.list()` / `lists.query(id, …)` | both | Lists widget, a List's view |
| `lists.save(filter)` | server, **capability-gated** | (not in 0.12, see below) |
| `series.get(id)` | both | Series page, Download next 3 |
| `downloads.start / cancel / remove` | local (fetch from server) | covers, Details, Series, Storage |
| `progress.sync(book)` / `progress.remote(book)` | server | header sync, top-panel sync, the "other device" sheet |
| `reading.stats()` | local | Year, This week, When you read, Records |
| `battery.stats()` | local | Battery widget and page, mode estimates |
| `storage.summary()` / `storage.free(action)` | local | Storage page, low-space sheets |
| `account.status()` / `account.signIn(server, user, password)` / `account.pairCode()` / `account.signOut()` | server | Your server, sign-in sheets; `signIn` returns what it set up (`{sync: found|created, opds: found|created}`) or an error code (`wrongPassword`, `unreachable`, `twoStep`, `tooOld`) |
| `updates.check(channel)` | server (release feed) | Updates |

- **Capabilities, not server names:** the adapter reports `lists.save`, `ratings`, `wantToRead`, `customFields`, …. A missing
  capability **hides** its row rather than greying it, unless seeing it is worth teaching (none in 0.12).
- **Filters:** the filter sheet builds the neutral filter object; the adapter translates what its server can express, and
  anything it cannot (always *On this device* and *Group*) runs locally on the cached catalog. Results are identical either
  way; only the speed differs.
- The UI says **Lists** everywhere. Adapter note: *BookOrbit: Smart Scopes.*

### Saving lists to the server (researched, off in 0.12)
The BookOrbit adapter could implement `lists.save / update / delete` (name, icon, filter, sort; no group-by). Most filter
fields map to server fields; *On this device* and *Group* always stay local; lists are always saved **private**. It is **off
in 0.12**: the KOReader sync credential BookSync uses cannot write lists, and no write key is added in this release. So 0.12
offers only "Save as a Book list on Home" (device-local, source Custom filter); "Save to server lists" is hidden behind
`lists.save` (no disabled row).
**Later:** an optional "Allow BookSync to save lists to your server" grant in Your server would create a revocable write
key on the server; lists saved through it are always private, and *On this device* and *Group* stay on the device.

## 13. Critic round-1 findings: what changed

| # | Finding | Change |
|---|---|---|
| 1 | Classic edit mode focused Resume; Select opened the book | Edit mode focus stops are only toolbar, widgets, + slots and page bar; focus starts on the first widget; carry mode with a hint strip (section 5). |
| 2 | Targets under 50 px | Everything ≥ 50 px on M8C and X4 Pro; measured: 0 undersized targets on every screen (section 10). |
| 3 | This week bars wrong; "Saturday" hard-coded | Equal-height columns, floating label; best day computed. |
| 4 | Page names didn't match content | Want to read on M8C page 1; X4 pages Home / Library / Stats. |
| 5 | Barcode progress bar; poor contrast | Round 2: one solid bar with chapter ticks. Round 3 (ruling): one plain bar, no ticks or chapter words; white mat on the cover. |
| 6 | Classic Contents/Go to focused Close | Current chapter and the value get focus; Go to stepper; scrubber grab. |
| 7 | X4 render profile | Black/white + 2 grays, heatmap patterns, black meta text, no gray on black, no wash, X3 fallbacks (section 2). |
| 8 | Edit tags over headers; shared icons | Tags bottom-right; unique icons. |
| 9 | Size label read as current | "Size 4×2 → 2×3" (current, then next). |
| 10 | Hero eyebrow truncation; X4 forecast wrap | "READING" at 2×2; "3 h 22 m · by Sat". |
| 11 | Badges over author lines | Badge hangs off the cover corner. |
| 12 | Also reading stamps | Rows ≥ 64 px: two books with covers twice as large. |
| 13 | Dead space | Lists rows fill evenly; Records reflowed; Clock 1×2 filled; list grids 5 (M8C) / 4 (X4) columns = 3 rows. |
| 14 | M8C bottom panel | Named specimens; "More reading settings…" link; bookmark-plus vs bookmark-list. |
| 15 | X4 bottom panel | Light copy removed; Font and Size glyphs differ; Today legend swatch. |
| 16 | End of book | "Add *next* to Want to read"; "Back to book". |
| 17 | Series page | Status-only rows; Back spacing. |
| 18 | Notes on dimming | Section 1. |

## 14. Critic round-2 findings: what changed

| # | Finding | Change (round 3) |
|---|---|---|
| 1 | Low space blocked too early | Below 10 % it only warns; it blocks only below the 200 MB floor; the sheet shows needed vs freed; demo figures agree on every screen (section 7, Storage). |
| 2 | X4 sign-in; section 8 contradicted itself | X4 reuses the firmware keyboard and File Transfer (QR + `/settings`, settings PIN); section 8 rewritten per device. |
| 3 | X4 heatmap | Five levels (white with outline, `#c0c0c0`, `#808080`, black, today ring); patterns only at ≥ 12 px cells. |
| 4 | Classic pages 2 and 3 | Focus starts on the first widget; header rings drawn inside the header; page dots are not focus stops. Cover focus keys are now scoped per tile, so the same book on two shelves no longer traps focus (found by c2.js). |
| 5 | When you read gone | Back on Stats as a shaded strip (M8C 2×2, X4 2×1). |
| 6 | Battery 2×1 clipping; glyph | Fixed and in the sweep; the glyph is filled to the real level everywhere. |
| 7 | Rates | "Wi-Fi off while reading" moved out of Standby (it is a Wi-Fi choice); one decimal. |
| 8 | Header icons | All 50 px outlined; no solid black while syncing; separate Sync and Updates glyphs. |
| 9 | Presets; fonts | Custom presets show their value; "Font choices" and "Your font" merged into one Font choices row. |
| 10 | Bar on Details and Reading now | The same plain bar as the hero. |
| 11 | Small targets | 0 under 50 px on every measured screen (section 15). |
| 12 | Edit tags over captions | Tags straddle the tile's bottom edge. |
| 13 | X4 Contents; grab hint; Library dead band | Contents pages whole rows; the grab hint sits 14 px clear of the ring; Library no longer 2×3 on the X4 (2×2, filled). |
| 14 | "Other device" sheet | Names the device and when ("Your Phone is further · Phone · 2 h ago: p. 240") and the rule. |
| 15 | X3 fallbacks | Section 10. |
| 16 | "Not in a series" | Shows its count and "All 17 ›". |
| 17 | Leftover toasts | `shoot.js` clears toasts before every shot. |
| 18 | Stale side-panel text | `explain()` rewritten: no server names, no chapter ticks or "greyed out"; covers the filter sheet, Rename, the plain bar, the sign-in and Sync modes. |
| 19 | Edit tips | State the move rule and what Configure does. |

Maintainer additions this round: Lists 1×3 (section 2 and 4), X4 defaults (section 4), page rename (section 5), Classic focus
on dark (section 1), the filter sheet (section 11), the library interface (section 12), server lists (section 12).

## 15. Verification

Headless Chromium with Playwright on M8C, X4 Pro and X4 Classic. **No console errors anywhere.**

| Check | Result |
|---|---|
| `critic-shots/measure.js` (M8C: home, top, bottom, TOC, marks, end, edit) | 0 targets under 50 px on every screen |
| `critic-shots/classic.js` | edit focus on tile-0; Select picks up, Back cancels; Contents on the current chapter; Go to on the value; ERR [] |
| `critic-shots/r2/m2.js` (DEV=m8c and x4pro) | 0 small, 0 overflow on every screen; ERR [] |
| `critic-shots/r2/c2.js` | page 1 → 2 → 3 walk starts on each page's first widget; sign-in sheet reachable; ERR [] |
| `critic-shots/r2/c3.js` | sign-in focus stops and reader settings; ERR [] |
| `critic-shots/r5/f5.js`, `p5.js` (also with Q=1, on x4c and m8c), `cl5.js`, `ser.js`, `bat.js` (run with SP set to the scratchpad) | f5: no clipped or out-of-card rows, no pager in any sheet; p5: no row out of the card, no "Page 1 of 1"; cl5: Classic walk, pickers and Back work, errs []; ser: Series walk has no dead arrows; bat: the estimate fits every tile (overR −12 and −27 px) |
| `critic-shots/r3/dark.js`, `filt.js`, `filt2.js` and `r2/c4.js` | run clean, ERR []; filt and filt2 now assert one page, 9 rows, every row opens a picker, no cycling rows, and that Length, Rating, Added and Group & sort open pickers; c4: no duplicate focus keys, Next walks pages 1 → 2 → 3 |
| `critic-shots/r2/fuzz.js` | m8c 136 moves / 264 no-ops, x4pro 143 / 257: 0 overlaps, ERR [] |
| `pwtools/verify.js` | all round-1 flows pass; no errors |
| `pwtools/sweep.js` | every widget at every size on both screens: no overflow, no clipped text; and the Battery estimate at every size says "at your usual use" (or "· usual use" only on narrow tiles) and is not clipped |
| `pwtools/r2/move.js` | 14/14 |
| `pwtools/r2/bl.js` | 35/35 (grouping through the filter sheet; headers counted as rows, since complete groups have no link) |
| `pwtools/r2/flows.js` | 63/63 (8 settings groups; low space blocks only below the floor) |
| `pwtools/r2/sync.js` | 45/45 |
| `r3/flows3.js` | 147/147 (round 7 adds: Updates has one channel row ≥ 50 px and no inline radios; the picker has 3 radio rows with descriptions, current marked; picking Preview returns to Updates showing it; Classic: Select opens on the current channel, Select picks and returns, Back returns. Round 6 added: footer = list subtitle; author counts equal the other-filters rule with Length = Short; zero-count authors last with no number; a ticked zero-count author stays; page bar only with more than one page; Series has none; no Where row in On device. Round 5 added: the sheet is one page of 9 rows ≥ 50 px that all end above the footer, every row opens a picker, no cycling rows or segments, changed rows are marked; Show, Where, Length, Rating and Added pickers are radio rows with counts; Author, Series and Tags are checkbox rows; Group & sort is one page with Group, Sort by, Order; Classic: Select opens the picker on the current choice, choosing returns, Back closes the picker and then the sheet. Round 4 added: a complete author group has no "All N"; no BookOrbit / Tailscale / Grimmory / tailnet text on any page of any settings group; About, Updates › Installed and the Updates summary show one version). Earlier: add a page → "Page 4" → add Year → "Stats" → rename → pager; Settings › Page names; filter on Recently added (count, chips, subtitle, filled icon, chip removal, save to Home); Search (Best match, chip, save); Source › Custom filter; Classic Next/Select/Back |
| `r3/focus.js` | 141 steps (now including the channel picker), 15 dark (ink, black controls, selected segments, dark covers), 0 fails; walks the filter sheet and its pickers |

Test fixtures updated for deliberate round-3 changes (not to hide failures): `move.js` builds the 2-wide-band layout it
tests (the X4 default changed); `bl.js` groups via the filter sheet; `flows.js` expects 8 groups, enters a password before
Sign in, and uses the below-floor space state.

## 16. Critic round-3 findings (REVISE): what changed in round 4

| # | Finding | Change |
|---|---|---|
| 1 | Focused selected segment too weak on the Classic (thin white inset) | White fill, bold black text, 2 px white gap and 3 px black ring outside the control, ✓ kept on the chosen one; `focus.js` now counts selected segments and dark covers as dark and fails any weak treatment. |
| 2 | Server and vendor names on screen | Home screen: "BookSync / Server plugin's Home" (summary to match); "Wake VPN for syncs"; About sub line "VPN" only. `flows3.js` scans every settings page. |
| 3 | Sync in the top panel | Kept; section 6 cites both maintainer comments. |
| 4 | Hero picker text | "Your current book, big: cover, progress, time left and when you'll finish." |
| 5 | Versions disagreed | One string, BookSync 0.12.0-rc.2 · RC, on About and Updates › Installed; Updates summary "RC channel · 0.12.0-rc.2". |
| 6 | M8C screenshots at 1x | All M8C shots at scale factor 2 (1404×1872), including the new flow shots. |
| 7 | "All N ›" on complete author groups | Hidden when the group shows every book; it shows "N books". |
| 8 | Gap under X4 Want to read 1×3 | The mini-grid is top-aligned and uses the full height, so the covers are bigger. |
| 9 | When you read vs This week | M8C 2×2+ uses gap-free hourly bars with a peak marker; strip kept for 2×1, 4×1 and the X4; This week stays labelled day columns. |
| 10 | Real-looking LAN address | 192.0.2.10 (documentation range) in the notes and the prototype. |

## 17. Round 5: what changed

| Ask | Change |
|---|---|
| "Why is length, rating, and added not like author or series?" | Every Refine row opens a picker page in one style; single-value pickers are radio rows with counts; no row cycles in place. |
| "Can we get it slimmed down to one screen somehow?" | Nine rows (Show, Where, Author, Series, Tags, Length, Rating, Added, Group & sort) on one screen on every device; Show absorbs Want to read; Group, Sort and Order share one picker; Save is a small footer action; changed rows are bold with a dot. |
| Battery estimate says what it assumes | "≈ 2 d 6 h at your usual use" on every widget size ("· usual use" on 1-wide tiles), "left at your usual use" in the top panel and on the Battery page, "at your usual use" on the mode card and settings row. The Battery page row reads "Your usual use: screen on 25% of the time, last 7 days", and the other two figures are "reading non-stop" and "standby only". The sweep checks the phrase at every size. |

## 18. Round 6: what changed (critic REVISE on round 5)

| # | Finding | Change |
|---|---|---|
| 1 (major) | Author, Series and Tags counts ignored the other filters | One rule for all pickers: count with every other filter applied, this picker's own choice left out; zero values last, gray, no number; ticked values kept (section 11). |
| 2 | Footer total and picker counts disagreed (2,418 vs 30) | The list subtitle, the footer and the picker counts all come from one `fApply` path; Home headline totals are noted as illustrative. |
| 3 | "Page 1 of 1" with dead arrows in checkbox pickers | The page bar appears only when there are 2+ pages, so the Classic never stops on dead arrows. |
| 4 | Where can't change anything inside On device | Hidden there. Reading now keeps it: books in progress can be on the server only. |
| — | "1 books" in the list subtitle | "1 book". |

## 19. Round 7: Update channel picker

| Ask | Change |
|---|---|
| "picking channel should be a dropdown not selector like you did" | Settings › Updates shows one row, "Update channel · RC", with the channel's description. It opens a picker of three radio rows, each with its line; the current one is marked and focused first; picking returns to Updates. Same pattern as the filter sheet's single-value pickers. X3: `Update channel: RC  [Select: choose]`, then a numbered list. |

## 20. Round 8: sign in to your server

> Round 9 (§21) replaces the signed-out wording, the "What BookSync set up" row, the sign-out text and the shell's Server
> control. The form, the errors table and the stats label below still hold.

Maintainer: BookSync asks for the real server account once, then uses it for everything: stats across every device, and it
sets up the sync login and the OPDS login itself.

**Settings › Your server** (renamed from Account & server; the summary says "Signed in as reader · connected" or "Not signed
in · stats from this reader only").
- **Signed out:** "Sign in to your server" (once, with your server account; BookSync then sets up sync and OPDS) and
  "Until you sign in: stats come from this reader only, and your place doesn't sync".
- **Signed in:** Signed in as reader · Your server · Connection · **What BookSync set up**: "Sync login: found · OPDS: created ·
  stats from all your devices" · Sign in again… · **Sign out**, which asks first: "Your downloaded books and your place in them
  stay on this reader. Sync, and stats from your other devices, stop until you sign in again. The sync and OPDS logins
  BookSync set up stay on your server." Focus starts on Stay signed in.

**The form (M8C; also "type it here" on the X4):** Server, User name, Password rows, each opening the keyboard ("Each row
opens the keyboard"; the toast says "The keyboard typed…"). "KOReader" is named here only on the M8C, where it helps
recognise the login (see §21); Sign in is off until all three are filled. Pressing it shows **Signing in…** in place of the buttons
and locks the rows. **Back during Signing in… cancels the attempt:** the sheet returns to its rows with "Sign-in cancelled",
and a late answer from the server is dropped. Then either a result sheet, "Signed in as reader", listing what BookSync set up (Sync login: found,
already on your server / created for this reader; OPDS login: the same; Stats: from all your devices), or an error box at the
top of the form, in plain words:

| Error | What the reader says | Then |
|---|---|---|
| Wrong password | "That user name and password didn't work. Check both and try again. Passwords are case-sensitive." | Password cleared, focus on it |
| Can't reach | "Can't reach your server. Check the address, and that this reader is on Wi-Fi. If your server is only reachable over a VPN, turn that on first." | Focus on Server |
| Two-step account | "This account uses two-step sign-in. The reader can't show the second step. Sign in from your phone instead…" | Offers "Sign in from your phone or companion app" |
| Server too old | "Your server is too old for this. It can't set up sync and OPDS by itself. Update your server and try again. Until then, stats come from this reader only." | — |

**X4: sign in from your phone.** The sheet shows the QR and the code K7Q 4M2 ("lasts 10 minutes"), "Waiting for your phone…",
and rows **I've signed in on my phone** (focus starts here; the real reader also checks by itself) and **Type it on this reader
instead**, then Cancel. The same busy state, result sheet and errors apply.

**Where stats come from.** Signed in, stats are from all your devices and nothing extra is shown. Signed out, Year in reading,
This week, When you read and Reading records each carry a small outlined "This reader only" label beside their title (the
header's secondary text gives way to it; on 1-wide tiles it wraps under the title). Battery is always this reader's, so it
never carries the label.

**No server names on screen:** "your server" everywhere; flows3 checks the four sign-in sheets for product names.

**Prototype controls:** the shell has "Server: Signed in / Signed out" and "Sign-in result: Works / Wrong password / Can't reach
server / Two-step account / Server too old".

**Checks:** `flows3.js` 184/184 (round 8 adds, per device: signed-in rows and the setup line; Sign out asks first with focus on
Stay signed in; signed-out rows; "This reader only" on every Stats widget only when signed out; M8C: Sign in off until filled,
each of the four errors shows Signing in… then its plain-words message, wrong password clears and focuses the password,
two-step offers the phone; X4: code, QR, companion app, focus on the check row, "type it here" opens the form, an error, the
busy state; success lists Sync login, OPDS login and Stats; back to Your server signed in; no product names). `focus.js` 155
steps, 19 dark, 0 fails (adds the phone sheet, the form, the result sheet and the sign-out confirm). `sweep.js` now also
renders the four Stats widgets signed out at every size: the label is present and never clipped. `pwtools/r2/flows.js` 66/66
(re-sign-in now waits for the result sheet and checks it names the OPDS login).

## 21. Round 9: three logins, two signed-out states, sign-out honours how you signed in

Maintainer: "Sign in should ALSO support entering your KOReader and/or OPDS credentials separately", and "honor how they
signed in. If I click 'Sign out' and I used it to sign in, it should sign out all the accounts". The critic (REVISE on
rounds 7-8) also found the signed-out page contradicting Home ("your place doesn't sync" beside "Synced 12 min ago").

**Model.** Your server holds three logins, each optional and set on its own:

| Login | What it does | States |
|---|---|---|
| Server account | Stats from all your devices; sets up the other two | Signed in / Not signed in |
| Sync login | Position sync (on the M8C: "the one KOReader uses for your place") | Set up by your account · Set by you · Not set |
| OPDS login | Catalog browsing and downloads | Set up by your account · Set by you · Not set |

A login the account found already on your server counts as the account's. Signing in fills only the logins that are Not set;
one you entered stays, and the result sheet says "Kept: the one you set" with a pointer to **Replace with the account's**
(an explicit row on that login's form, shown only when signed in and the login is yours).

**Settings › Your server.** Account rows first, then a "Logins" heading with Sync login and OPDS login, each showing its state
on the right and opening its own small form: a state chip, one line on what it does ("It works with or without your server
account"), Server / User name / Password rows (empty server reads "Your server address"), then, when set, "Replace with the
account's" (if it applies) and "Remove sync login…", then Cancel / Save. Save shows Signing in…, and a wrong password or an
unreachable server gets the same plain-word boxes as the account form. Remove asks first ("Remove the sync login? This
reader stops syncing your place until a sync login is set again. Nothing changes on your server.", focus on Keep it).
Cancel, Back, Save and Remove all return focus to that login's row.

**Signed-out states (shell: Server = Signed in / Signed out · own logins / Nothing set up; plus Sync login and OPDS login
controls).**
- **Signed out, your own sync login set:** sync works as before; Home keeps "Synced 12 min ago". Your server says "Not signed
  in · Position sync uses your sync login · Stats from this reader only", then "Sign in to your server: for stats from all
  your devices and automatic setup".
- **Nothing set up:** Home's status line reads "Not signed in · Sign in" and opens Your server; the reader's top panel Sync
  button becomes a "Sign in to sync" pill; Sync, Wi-Fi & power's first row is "Sign in to sync" with the note "Not signed in,
  so nothing syncs: not your place, highlights or new books." Its group summary says "not signed in".
- **Signed in but no sync login** (you removed it): the same places say "No sync login · Set up" / "Set up sync", and open the
  Sync login form.
- **No OPDS login:** tapping a book that isn't on the reader says "No OPDS login · set one in Your server to download".

**Sign-out honours how each login was set.** The confirmation lists exactly what stops, built from the three states:
"Signs out of your account, and removes the sync login and the OPDS login it set up. Sync stops on this reader. Browsing and
downloading from your server stop." With your own sync login: "…removes the OPDS login it set up. … Your own sync login
stays, so sync keeps working." Afterwards the page shows the true state: nothing set up, or only your own logins. The Sign out
row's sub line says "Also removes the logins your account set up".

**X4: one phone path for all three.** Sign in, and any login that is Not set, opens the code + QR sheet ("Enter the sync
login from your phone"); a set login opens its form, where "Enter it from your phone" is the first row under the fields. "Type it on this
reader instead" opens the matching form. On a single-login sheet the check row reads "I've entered it on my phone".

**Phone-sheet errors in phone words.** Wrong password: "Your phone couldn't sign in. Try again on the phone, or get a new
code." with a **Get a new code** row (shows a fresh code). Can't reach: "Your phone couldn't reach your server…". Too old:
the error with a single **Close** (focus on it) in place of the waiting rows. A two-step account succeeds on the phone sheet,
since the phone does the second step.

**Wording.** "Sync login" and "OPDS login" everywhere. "KOReader" appears on the M8C only, where it helps recognise the
login: the Sync login row and the Sync login form's description. Keyboards are just "the keyboard". No server or
product names (flows3 checks the login forms).

**Classic focus.** Stay signed in returns to Sign out; Back from the question does too; after signing out focus is on Sign in.

**Removed:** the dead second sign-in branch (the old Sign in again sheet left inside the What's new block).

**Checks:** `flows3.js` 288/288 (round 9 adds, per device: both signed-out states on Home, Your server, Sync, Wi-Fi & power and
the top panel; the three sign-out cases (account only: nothing works; your sync login + account: sync stays; mixed: sign-in
keeps your OPDS login, Replace, Remove asks first); X4 phone path for a login; phone errors, Get a new code, Too old Close,
two-step succeeds; Back cancels Signing in…; empty server hint; Classic focus returns; "KOReader" only on the M8C).
`focus.js` 171 steps, 23 dark, 0 fails (adds the login form, Remove, the login phone sheet and Too old). The critic's r8
scripts (si, form, lab, so, so2) join the check set (run on M8C and X4 Classic) via `r3/all.sh`.

Critic r8 scripts are exploratory (no pass/fail): all run with no page errors on M8C and X4 Classic. Two of their probes now
report "cannot reach" by design: si.js X4 after Two-step (the phone sheet now signs in, so there is no Sign in row left) and
form.js's last probe for "Sign in again" on the signed-out page. so.js uses Server = Signed out, which is now "own logins",
so Home correctly still says Synced. Full run: `zsh r3/all.sh` (log `r3/all-r13.log`). Round 9 screens: `shots/*-r9-*.png`.

## 22. Round 9 sign-off minors (rev 14)

Critic approved round 9 and the maintainer signed off. Five minors from `critic-shots/r9/`:
1. Keyboard wording: "Each row opens the keyboard" and the toast "The keyboard typed…"; "KOReader" only on the M8C Sync
   login row and form description.
2. Classic focus after Done on the sign-in result goes to the first login the account set up (Sync login, else OPDS
   login), or to Sign in again when it changed none.
3. Home's "No sync login · Set up" opens the Sync login form, like the top panel's "Set up sync".
4. The single-login phone sheet says "I've entered it on my phone".
5. Tapping a server-only book with no OPDS login: toast "No OPDS login, so it can't download" with a **Set up** action that
   opens the OPDS login form.

Also: a "Set by you" form shows that login's own user name (reader-sync / reader-opds in the demo), not the account's; §21
now places "Enter it from your phone" where the form shows it (first row under the fields).
Checks: `flows3.js` 303/303 (adds each minor); full `r3/all.sh` plus the critic's r9 scripts.

## 23. Round 10: what "Custom" means, and editing it

Maintainer: "if I select 'custom' does it open the KOReader settings? … how would I edit those custom items? I'd expect to be
able to click on them". "Custom" had three meanings; each is now explicit.

**1. Quick settings (Font, Margins, Line spacing, Contrast), the third choice.** It is your own saved value and always says
it: on the M8C the segment reads "Custom" over its value ("46 px", "1.42", "Darker 0.2"; Font: "Custom" and "Baskerville +1" under its Aa); on the X4
the stepper reads "Custom · 26 px". Picking it applies the value straight away; nothing opens KOReader. Once it is picked, a
pencil appears on it, and tapping it again (Select on the Classic, where the value becomes its own stop between ‹ and ›)
opens its editor over the panel; Done or Back returns to that choice with the panel still open. Decision (two-way door, the
coordinator's lean): keep "Custom · value" rather than rename to "Yours": the value is what makes it clear, and "Yours"
collides with "Your own settings" in Sync. Long press was not used: not discoverable, and the Classic has none.

**2. Settings › Reading: every choice in one place.** Rows in the panel's order: Font choices (the middle font) · **Custom
font** · Margin choices (the preset pair) · **Custom margins** · Line spacing choices · **Custom line spacing** · Contrast
choices · **Custom contrast** · (M8C) **Use KOReader's current values**, then the status bar rows. Each Custom row shows its
value and opens its editor:
- **Custom font:** radio list of fonts, each in its own face (Baskerville, Literary, Classic, Clean), plus a Weight stepper
  (−1 … +2), with a preview line.
- **Custom margins / line spacing / contrast:** one stepper (− value +, focus starts on +; margins 10–80 px on the M8C,
  6–48 on the X4, step 2, **stored per device** since the screens differ; spacing 1.00–2.00, step 0.02; contrast reads
  "Lighter 0.5" … "Normal" … "Darker 0.5", step 0.1) with a live preview line (margins drawn as shaded gutters at
  page scale). "Changes apply straight away"; if the book is on Custom it updates behind.
- **Use KOReader's current values** copies what you last set in KOReader's style menu into Custom, once ("Later changes
  there don't follow"); the toast has Undo. M8C only (the X4 has no KOReader).
- The "From KOReader" wording is gone.

**3. The other two meanings, renamed.** The sync mode card's computed state is now **Your own settings** ("You changed a
setting below. Each one keeps your choice.") with Back to Balanced as before. Reading position's second choice is **KOReader
decides** on the M8C; on the X4 the row is information only ("Furthest page wins"), since there is nothing to choose.

**Checks:** `flows3.js` 335/335 (round 10 adds, per device: no "From KOReader"; each of the four editors opens from its row,
has a live preview, its stepper changes the value, Done returns to the row, targets ≥ 50 px; panel Custom applies first,
then edits live and returns to the panel; the KOReader copy is one-time with Undo (M8C) and absent on the X4; "Your own
settings" with no "Custom"; Reading position wording per device; Classic: Select opens the stepper, Prev/Next reach − and +,
Select steps, Back returns to the row). `focus.js` 214 steps, 27 dark, 0 fails (adds Settings › Reading, the four editors and
the panel with Custom picked). Screens: `shots/*-r10-*.png`.

**Rev 16 (critic approved round 10; four minors):** the margins, line spacing and contrast editors open with focus on +;
the M8C Font Custom segment shows its value ("Baskerville +1"); contrast values read Lighter / Normal / Darker instead of
"Dark ±"; §23 now says Custom margins are stored per device. `flows3.js` 338/338. The critic's r10 scripts join `r3/all.sh`.


### Android first run and upgrade review (pass 3, 2026-11-26)

Owned Home is the Android 0.12 default on both fresh installs and upgrades. The
legacy Home selector is retired from the shared settings schema and Settings;
old internal navigation remains only for compatibility while transport moves.
The existing `logic/layout.lua:181` defaults follow §4: Home and Stats on the M8C, including Also reading, Recently
added and Want to read. On device and Finished remain Book list presets.
A saved layout (including class overrides) remains authoritative; this cutover
never resets it or copies catalogs, logins, outbox or reading intents.

Reuse: `ko/settings.lua:52` owns the existing settings record;
`logic/home_plan.lua:81` owns the additive Home migration; `ko/home_host.lua:15` reads layouts
through `ko/home_editor.lua:14`; `ko/store.lua:1` remains the file boundary.
`ko/library.lua:15` owns paint budgets, and `logic/home_host.lua:46` projects
small immutable snapshots. The companion's `SettingsStore.kt:51` already
persists replacements before removing old setting keys; no parallel migration
or persistence store was added.

Before applying defaults, an additive migration records whether a settings
record already exists, selects owned Home, and saves the pending-news bit with
its completion marker in one reader-settings flush. A crash before that flush
reruns the same operation; later starts preserve acknowledgement. Existing 0.11
`sync_mode=custom` and its timestamp are untouched. Upgrade news opens above the
next explicit Home opening, never on plugin load or over foreground reading;
Done or dismissal marks it seen and flushes. Fresh installs have no pending news.
The five static rows inherit a named zero-byte, zero-worker, zero-network and
zero-subprocess screen budget and log one info timing span. Other screens and
widgets retain their caller budgets; host tests do not establish device timing.

Missing catalog windows on a signed-out reader offer Sign in rather than an
unfinishable Loading/Retry cycle. Cached rows still draw, and directly entered
logins retain their normal loading behavior without an account. Empty saved shelves say No books here yet;
an empty Continue reading card says Open a book to start reading, without Retry.
Version skew blocks Home before constructing the host, naming the companion or
plugin that needs updating. X4 Pro, X4 and X3 cutover remains deferred by the
maintainer's Android-first ruling; no firmware setting or migration changes.

The upgrade sheet uses pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`
`frontend/ui/widget/buttondialog.lua:339` (`onClose`) and `:68`'s
`tap_close_callback`, which
handles both Back and outside taps; Done acknowledges explicitly before closing.
The regression double follows that native path rather than InfoMessage's separate
`dismiss_callback`. The compatibility guard now requires the native callback field.

The upgrade sheet's Done action declares a 50 px content height, in addition to
native padding/borders. Pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`
`frontend/ui/widget/buttontable.lua:88` forwards an explicit height; without it,
`frontend/ui/widget/button.lua:111` derives height from the font. The regression
checks the action's minimum target as well as its acknowledgement lifecycle.

### Android implementation of §23 (F12-M, 2026-11-26)

The rev 16 editor builds on `ko/menu.lua:236` (Reading group),
`logic/settings_ui.lua:21` (computed mode label), `ko/reader_panel.lua:30`
(reader sheet and library paint), `ko/endsheet.lua:135` (measured rows),
`logic/sheet_layout.lua:23` (bounded layout), `ko/settings.lua:61`
(device-local settings), and `ko/library.lua:15` (caller budgets). No companion
read-model or server operation is needed: these are user-selected native styles.

`S.custom_reading` is one device-local record outside shared settings: pixel margins
never travel to another device. Per-book choices use KOReader's in-memory document
settings and normal flush. Editing Custom updates only changed, selected styles;
native margin application owns its position update. Reopening a book using Custom
reads the latest local record. Closing the reader discards the editor and its return callback.

Each editor has a named budget in `logic/budgets.lua`: at most 12 display rows, one
local record per read, zero decoded bytes, network, subprocesses and companion
round-trips. Library calls inherit the caller's screen budget. Paints and style
reads/apply/save/copy log info timing spans. Device targets remain unconfirmed;
deterministic host checks are not an M8C timing result.

Native behavior was checked at pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`:
`frontend/apps/reader/modules/readerfont.lua:163` loads the face and configurable
weight/spacing/gamma; `:212`, `:221` and `:269` notify, so the adapter uses their
document setters quietly. `frontend/apps/reader/modules/readertypeset.lua:541`
scales margins and reserves the footer; reuse preserves vertical margins and the
BookSync strip hook. `frontend/ui/data/creoptions.lua:581` supplies the gamma table;
Custom selects the nearest engine gamma to 1 + its displayed contrast value.
`frontend/ui/widget/touchmenu.lua:658` returns to a row by ID without dismissing Reading.

Font choices resolve preferred installed faces through the native adapter, with
bundled Noto Serif / FreeSerif / Noto Sans fallbacks matching the prototype's fallback
intent. No fonts are downloaded or installed. Copy retains any installed face name.
The compact native-widget preview illustrates weight and contrast; the open EPUB
receives the supported engine weight, spacing, margin and gamma values. PDFs retain
the existing KOReader-menu escape. Android comes first under the 2026-11-25 approval;
X4 Pro, X4 and X3 remain deferred, with their own device margin ranges.
## Android F12-N implementation

The approved §20–§22 forms now reuse the neutral library and companion account worker;
see [F12-N implementation notes](F12-N-NOTES.md). Each screen/widget declares a strict
budget inherited by library calls: bounded rows/decoded bytes, zero subprocesses and
render-path network, ≤1 batch per Home paint and ≤16 KiB per widget. The companion owns
heavy work. Account results redraw only a visible initiating form; cancellation drops stale
results and clears transient password fields. X4 phone setup remains a labelled stub.


CI integration exposed a pre-existing simulator-test race in `heap_floor_waits`:
a fixed nine-second QUIT could stop the refresh worker after its delayed manifest
reply and before its heap decision. The test now waits for the explicit heap-floor
log marker with a bounded deadline; its request assertions are unchanged. The
shared host harness tests marker stopping, missing markers and visible crashes.
The repaired X4 Pro case passes against an isolated synthetic server. This is a
test-harness fix only; no firmware product code is changed by F12-M.


KOReader's `scaleBySize` rounds upward (`koreader-base` pin
`6e4bc81af4e04f78d81677a323a780a71b29702a`, `ffi/framebuffer.lua:414`).
The native adapter calibrates its inverse at a large size rather than treating
`scaleBySize(1)` as an exact factor. Fractional-scale tests verify that displayed
physical pixel margins survive apply and one-time copy unchanged.
### F12-P Android implementation (2026-11-26)

Book lists reuse the Home editor draft, shared filter sheet and single Book list
renderer. Friendly picker presets become `widget="booklist"` placements whose
`settings` hold the approved cfg (`title`, `src`, `style`, `sort`, `cap`, neutral
`query` for Custom filter). The layout engine's existing versioned placement
format is retained; no second preset widget type or layout store is introduced.
Source pages offer Built in, Your lists, Series and Authors. The companion
materializes names, opaque source keys and counts; the plugin reads six rows and
at most 16 KiB through `Library:sources` in one paint/batch. Empty or unavailable
counts remain unknown. Reading now excludes the Continue reading book in the
companion before filtering, sorting and paging, including after a sort change.
The owned list, filter-sheet facets and saved Custom filter context carry the
same exclusion, keeping their book counts consistent.

Settings use a zero-read `booklist-config` budget; source pages have the bounded
`booklist-sources` budget. Both log one draw span, and source reads also log the
library call/paint spans. Editor moves remain geometry only. The existing widget
budget limits each Book list snapshot to 16 KiB, with zero subprocesses and
render-path network calls. Host tests enforce deterministic limits; the <500 ms
Home, <50 ms widget and <100 ms editor targets still need device confirmation.

Cancel discards configuration; Done updates the editor draft, and the editor's
Done uses its existing atomic save. Saving a filter from an owned list persists a
device-local widget and names the destination in the confirmation. Saving from
configuration adds to the same editor draft, retains the selected widget and
reports the destination plus the need to finish the editor. Classic More uses the
same card, focusable source rows and Back paths; Title offers suggestions without
a keyboard. Firmware implementation for X4 Pro, X4 and X3 follows Android under
the maintainer's Android-first ruling. No device work or release is authorized.

Reuse evidence: `logic/home_editor.lua:3` owns the draft and existing add/page
operations; `ko/home_editor.lua:24` owns atomic layout saving;
`ko/filter_sheet.lua:4` provides the shared sheet and callbacks;
`logic/home_host.lua:90` provides Save to Home placement;
`ko/home_widgets.lua:40` retains the one Book list renderer;
`ko/library.lua:38` enforces bounded reads through the existing adapter;
`LibraryReadModel.kt:24` publishes projections in the existing cache database.
Paths without a directory prefix are under `android/koreader/orbit.koplugin/`;
the companion file is under
`android/companion/app/src/main/java/net/fledgewing/orbitcompanion/`.

Copy maps a known installed face back to its preset index. An imported face outside
the four presets appears as the selected copied choice, drawn in that face. It adds
at most one row, keeping the font editor within its 12-row budget; choosing a preset
replaces the imported face, and Undo restores the previous index and face exactly.

The companion `BookOrbitLibrary` implementation lives in
`server/bookorbit/BookOrbitLibrary.kt`, accessed through the neutral server adapter
and owned read-model publisher. There is no root-package backend alias. Package
and protocol guards enforce that boundary across production source variants.


### Android design review pass 4 (2026-11-26)

[The comparison ledger](REVIEW-PASS-4.md) records baseline file/line findings,
regressions, retained native behavior and unfinished staged prototype surfaces.
Home/reader Settings and Battery destinations, list Back, page titles, hero
percentages and touch targets are repaired using the existing host and library.
Every screen/widget retains its strict inherited budget: companion-owned heavy
work, bounded ready-to-draw rows/bytes, zero render network/subprocesses, one Home
batch and at most 16 KiB per widget. Flow geometry is not device typography or
latency acceptance; the complete revision-16 prototype remains the target.


### Android Storage implementation (2026-11-26, g-storage)

The Library widget now consumes `library.summary` plus one `storage.summary`
row in the existing Home batch. Known local storage figures remain visible before
the remote catalog is saved. Storage, its confirmation and folder chooser
share a one-row/16 KiB screen budget; Collections pages contain at most six
companion-projected rows/16 KiB. All paints and library calls log timing spans.
No render network, subprocess, catalog scan or capacity calculation runs in Lua.
The <500/<50/<30 ms device targets remain unconfirmed by host tests.

`ko/home_widgets.lua:126`, `ko/home_host.lua:41`, `ko/library.lua:16` and
`ko/menu.lua:243` retain their existing owners. `LibraryReadModel.kt:5` publishes
local storage through the existing cache database, and `BookOrbitLibrary.kt:36`
normalizes its existing account-scoped Copies ledger through `ServerAdapter`.
The companion measures volume capacity/free bytes with StatFs and actual file
sizes; an unavailable measurement has no capacity bar. Books count only tracked
files; untracked files belong to the unmanaged remainder. A missing reading
history is not proof that a book was unopened for six months. Old-book removal
therefore requires a recorded last-open time older than six calendar months.
The foreground book is excluded from removal candidates. Confirmations bind to
an exact file preview and preserve sidecars, server copies and progress.
Busy actions stay disabled; a covered page adopts a completed snapshot on its next
visible paint, with no additional library read. Closed pages discard results.

Android supports the owned Storage page, patterned bar, warning, removal,
Collections index and folder chooser. Firmware follows the authorized later
pass. Small Library cards retain only the links that fit 50 px targets; M8C
2×2 cards expose Authors, Series and Collections. The folder chooser persists
its selection in the companion and sets KOReader's download directory through
the library interface after success. This is unreleased foundation work;
real-device typography, touch and timing acceptance still follow.
## Android reader-panel implementation

The reader slice extends the existing panel, Library, Custom and status-strip
owners with the header action arrangement and a separate bottom scrubber/quick
settings panel. Native actions stay behind Library; the companion projects the
bounded marker/position snapshot. Every screen and widget keeps its named
budget, zero render network/subprocesses and ≤16 KiB widget snapshots. Native
capture copies at most 64 cached entries per marker kind, never a full TOC or
sidecar. See [implementation and pinned native citations](G-READER-NOTES.md).
Host flow tests do not establish physical font fit or device latency.


### Android Series and grouped catalog presentation (2026-11-26)

The owned Home host now opens Series from grouped Library/Search headers and
Book info/Details. `SeriesUI.show(opaqueKey)` is the entry for the later end sheet;
it does not depend on end-of-book transport. Back restores the initiating list,
its query, page and exclusion context. Search from Series returns to that Series;
Book info/Details entries return to their initiating panel.
Primary and secondary membership comes from the existing adapter's saved catalog
and context, not from title matching in the UI. Incomplete secondary publication
says “Not saved yet”; missing identity and errors remain distinct from empty data.

The companion owns reading order, author/name grouping, counts, status-only labels,
full-Series progress dots and the exact next three unsaved titles. Group windows
preserve Search predicates, put unassigned books last, distinguish same-named
series keys, and show “All N” only when the cover preview omits members. Series
headers always open Series; complete author/unassigned groups have no link.
The neutral `without_series` filter keeps an unassigned drilldown and its removable
chip within the same Library/Search/filter owner.

Series inherits `budgets.lua`'s Series screen budget; grouped Library/Search inherit
the Library family budget. Every screen/widget must declare a strict budget and
library reads inherit it. Nested cover and next-book previews are charged as rows,
not hidden behind one group/summary row. Each cached result is at most 16 KiB;
there is one batched companion dispatch, no render network/subprocess, and one
info timing span per call/paint. Dots are capped at 24 with a range label on long
Series; books page by the available height. Filtering, joining and sorting stay
in the companion. Host tests do not establish the device latency targets.

This presentation does not fabricate cached covers, file sizes, storage capacity
or a working bulk transfer. The current adapter explicitly advertises
`series.downloadNext=false`: the Series page shows exact next-title previews and
“Downloads unavailable for this source”. Enabling the approved Download next N
control requires the transport owner to provide its job/cancellation/storage
contract; it must not be routed back through legacy Lua. The roadmap retains that
outcome; Android is partial in the feature matrix. X4 Pro, X4 and X3 follow later
under the maintainer's Android-first authorization.

Reuse evidence at the slice's base `4d082fa0`: `ko/home_host.lua:27` owns navigation,
`ko/home_widgets.lua:17`–`:32` owns native drawing helpers, `ko/library.lua:29`
owns bounded reads, `logic/filter_sheet.lua:15` owns neutral context,
`LibraryReadModel.kt:26` publishes through the existing cache, and
`server/bookorbit/BookOrbitProjection.kt:155` already owns worker filtering/joins.
Plugin-relative paths are under `android/koreader/orbit.koplugin/`; companion paths
are under `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/`.


### Android Settings presentation follow-through (g-settings)

The approved revision-16 Settings card, row order, installed-channel/reader summaries
and bounded sleep choices now reuse the existing group/library/sleep owners.
See [implementation and acceptance limits](F12-G-SETTINGS.md). Every screen/widget
keeps a declared budget inherited by Library: six sleep choices and 16 KiB per
page, zero render network/subprocesses; device settings are a lifecycle-cached row.
Counts and choice decoding stay in the companion; paints/calls log info timing
spans. Device latency and Android power-policy acceptance remain pending.

### Android local picker widgets (2026-11-26)

The authorised Android-first build installs Word of the day, Reading buddy and Light
in both prototype picker sizes (2×1 and 2×2); defaults are unchanged. Word is a daily
KOReader vocabulary snapshot with context/source and native lookup. Buddy uses only
local statistics, labelled On this reader; it does not imply account completion or
achievements. Light uses native frontlight capability and cached intensity, with
50 px decrease/increase actions; unsupported hardware has an explicit explanation.
Highlight and A year ago now use the neutral source-aggregating personal reading
interface, starting with device sidecars and KOReader page-stat history. Both Android
picker sizes are installed. Later remote providers register behind ServerAdapter without
changing the UI. Recommended and Discover remain separate staged work.

Maintainer ruling (2026-11-26), verbatim:
"I would build it so that all UI calls for that kind of data go through our interface, which then chooses where to fetch / aggregate data from. We start with on-device info and can extend to server but the ui never needs to change."
See [source implementation and limits](F12-G-SOURCES.md).

Each widget inherits one row, 16 KiB, zero subprocesses/render network and one shared
Home batch from budgets.lua. Selection, count and messages stay in the companion;
Lua draws immutable windows. Timing spans remain device evidence, not host acceptance.
See [local widget implementation](F12-G-LOCAL-WIDGETS.md) for pinned source evidence.

### Pass 3 follow-ups (Android, 2026-11-26)

The M8C uses §4's two default pages, Home and Stats, with the exact approved
placements; the X4's three-page default remains a later firmware slice. Existing
saved layouts remain authoritative, including any saved Library page.

Existing device-entered logins are imported as `user` (§21–§22): they predate
account sign-in, remain independent, and survive account sign-out. This differs
from a connector found on the server during an explicit account sign-in, which
has account provenance. `ServerAdapters.kt:29` composes the worker-only import;
`server/bookorbit/ServerCredentials.kt:16` checkpoints both logins and the marker
in the existing encrypted vault, preserving newer logins and the legacy catalog
identity. A crash before or after that atomic save is safe to retry. No source
credential file or legacy position/lifecycle queue is changed. Native OPDS source:
pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`,
`plugins/opds.koplugin/main.lua:15`, `:63` and `opdsbrowser.lua:248`. Existing
sync source: pinned BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`koreader-plugin/bookorbit.koplugin/main.lua:145`, `:155` and `:264`.

Signed-out projections use the reserved device owner without claiming or reading
a previous account's catalog. Reuse `LibraryReadModel.kt:30` for materialization,
`ReadingStats.kt:24` and `LibraryFilter.kt:30` for local stats and filtering, and
`DeviceStorage.kt:19` for local folder choices. Native metadata and custom covers
are read only by the companion; the plugin receives bounded windows. All existing
caller budgets and info timing spans apply: zero network/subprocess work while
painting, at most one batch per Home paint, at most 24 display rows and 16 KiB per
widget. Host test timings do not establish device performance acceptance.

## F12-endsheet implementation (2026-11-26)

Android's existing finish sheet now opens the owned Series page through the BookSync
interface. The companion's saved finish snapshot supplies an opaque series key; the
UI never chooses a source or scans membership. Last book and unknown series order
still allow View series; no membership omits it. Back restores the sheet only while
the initiating document remains open. The existing Home-host reader-leave checkpoint
and deferred sole finish writer remain intact; viewing never requests a download.

Reuse: `server/bookorbit/FinishLogic.kt:12` selects saved next/suggestion cards;
`ko/finish.lua:42` reads the bounded finish projection; `ko/endsheet.lua:77` draws
its rows; `ko/series.lua:154` owns Series entry/Back. PersonalReading's highlight
and anniversary registry is unrelated to catalog series membership and remains unchanged.
The existing end-of-book and Series screen/widget budgets apply: at most three
finish rows, 16 KiB per snapshot, zero subprocesses/network on paint and at most
one batched companion round-trip. No additional read or row is needed for the key.
AGENTS.md's screen/widget performance rule remains binding. Firmware implementation
and physical-device visual/timing acceptance follow Android; this is not a release.


## F12-recdisc: Android Recommended and Discover implementation

The 2026-11-26 slice authorization builds these formerly staged picker entries.
Recommended uses the prototype's 4×2 and 2×2 sizes; Discover uses 2×1 and 2×2.
They are optional installed widgets, with no default-layout changes.
The UI requests personal-reading kinds through BookSync Library; source registration,
local/mirror aggregation, dedupe, series/history ranking and daily choice stay in the
companion. Device data precedes the saved catalog. No server recommendation source
is installed; the existing PersonalReadingSource seam has an independent toy-provider test.

Both widgets inherit one display-book/16 KiB budgets in logic/budgets.lua, zero
subprocesses and network on paint, and the host's single batched companion request.
The interface persists Discover's Another offset locally; the companion applies it
to a deterministic daily shuffle of unread identities. Cached data remains usable
offline; loading, empty, missing offline data and errors have explicit cards.
Device font metrics and latency remain acceptance work. X4 Pro, X4 and X3 follow
the Android-first authorization; no firmware implementation is claimed.
See [implementation evidence](F12-RECDISC.md).

## F12-cards: Android book cards (2026-11-26)

Continue reading and Book list reuse the existing host/window and personal-reading
source registry for saved covers, series labels and ready-to-draw local time-left
and finish forecasts. Source choice and cover acquisition remain behind Library;
book actions reflect available adapter operations. No alternate status sync writer
or generic file-delete fallback is introduced. See [implementation and remaining
acceptance](F12-CARDS.md).

The existing per-widget row/16 KiB limits and one Home batch remain authoritative;
no extra cover lookup is added to paint. Bitmap preparation is deferred, encoded
input is capped at 512 KiB, and stale deliveries are canceled. Overflow declares a
five-row static budget with zero decoded bytes/round-trips. Info timing spans cover
paint, read-model publication and deferred decode. Device targets remain unverified.

## F12 architecture: bounded publication lifecycle (2026-11-27)

The maintainer-selected architecture slice deepens the existing LibraryReadModel, not the
Library UI or ServerAdapter protocol. It owns local/account context, bounded publication,
retained-window selection and changed-event ordering. Storage removal republishes affected
windows for the reserved device owner and current account; unrelated stats and battery
snapshots stay retained. Aggregation stays lazy per batch and never survives an owner change.
Adapter-specific projection construction remains in ServerAdapters.

Reuse evidence at review commit `6a49570d` (companion source package):
`LibraryReadModel.kt:33` already composes projections and lazy aggregates, `:72` enriches
bounded cards and `:112` refreshes file joins; `server/bookorbit/CacheWorker.kt:364` owns the sole
cache writer and event spool. The slice removes the inconsistent caller-owned context and
notification choreography described in the selected review. Lifecycle tests use the existing
SQLite/JDBC store and neutral fake adapter, publishing a batch, removing a download and
reading the retained windows again for both owners. Pace, finish forecast and provenance
survive for remaining books; removed file references disappear.

Every screen/widget still inherits its existing row/byte budget: at most 24 display rows,
16 KiB per snapshot, zero render-path network/subprocesses and at most one Home batch.
The existing publication timing span remains. No firmware implementation, new feature,
release or physical-device timing acceptance is claimed; X4 Pro/X4/X3 follow Android.
