# Nothing interrupts reading

**Principle (v0.11.1).** While a book is open in the foreground, nothing from BookSync, BookSync
Companion or BookOrbit (as far as we can intercept it) appears on screen, restarts KOReader or
takes focus. Whatever would have shown waits for the next moment nobody is reading, or is dropped
once it has gone stale.

Exceptions, only where the reader acts inside the book: menus they open (and what those menus
show), the end-of-book sheet (they reached the end), and Sync and sleep (they asked; it runs as
the screen goes off).

One exception the user asked for outside that rule: the Full refresh's % badge
(`ko/badge.lua`, [sqlite-cache.md "Progress display"](sqlite-cache.md#progress-display-the-users-design)).
In a book it is a few characters in the bottom-left corner, a toast that every tap goes through,
never taking focus and redrawn only in its own rectangle at most every 3 s. Its start popup and
its full message still go through the gate.

Another: BookSync position sync's Yes / No popup when another reader's place turns up after the page rendered
(`ko/orbismart.lua`, [position-sync.md](position-sync.md) ruling 1): one draw, no animation, one at a time.

## The gate

**Plugin.** `reading()` (`ko/home.lua`) is true when a document is open, KOReader is in front
(`Wifi.state().foreground`), BookOrbit is not over the book, no reader menu is open and the
end-of-book sheet isn't showing. "BookOrbit over the book" (`bookorbitOverBook`, v0.11.2) walks the
window stack down to the ReaderUI: BookOrbit's catalog (Home or any list) or one of its views,
menus or dialogs (`bookorbit_*` widgets) anywhere above the book counts, whatever floats over them
(its loading pills, KOReader's messages: v0.11.1 held the Full refresh progress "while reading"
with Home on screen). Its status pills alone over the book don't. Just in time Wi-Fi's "done in a
book" off uses the same test (`ko/wifi.lua`). `Gate.show(what, fn, max_age_s)` runs `fn` at once when
not reading, else queues it (one entry per kind, the newest wins). `Gate.drain` shows what is
queued when BookOrbit Home comes on top, a book closes, and KOReader resumes; entries older than
their `max_age_s` (default 10 min, BookOrbit toasts 2 min) are dropped and
logged.

**Background notices on Home and browse.** `ko/notices.lua` marks automatic start, resume,
book-open and periodic sync, copies, mailbox replies, storage and cache repaints as background
work. That scope follows scheduled callbacks, native queued sync jobs and Trapper coroutines;
it is local to each coroutine so a suspended job cannot silence a concurrent user action.
Background notices are dropped rather than held for later. Native BookOrbit `show`, `error`
and `loading` pills, our own notes, direct InfoMessages/Notifications and Trapper progress text
all use the same suppression boundary as Full refresh. Thumbnail downloads and automatic clock
repaints are silent too. Every shown or suppressed message logs its text. Invisible Trapper
input traps still operate, and suppressed loading pills still return a closeable handle.
Explicit user actions retain their notices; Full refresh retains its tagged progress popup and
badge, and position-sync choices retain their dialog. Start/wake/copies, delayed and yielding
callbacks, cancellation, and foreground actions are covered in `test_flows.lua`.

**Companion.** A `Reading` gate mirrors the plugin from `STATS`: the plugin adds `reading=1|0`
to every `STATS` (0 on `close` and `suspend`); older plugins are read from `open` and
`resume`/`suspend`. Notifications and activity starts the companion makes by itself wait while
reading and are posted at the next non-reading moment (KOReader suspended or in the background,
the book closed, BookOrbit Home, a companion page in front). Never at screen-off: nobody would see
them. Posted quietly: no heads-up, no sound.

## Restarts after an update

| Update | When KOReader restarts |
|---|---|
| The reader asked (Update in the menu, Install in the companion) | at once, book or not: saved through KOReader's own close, the book reopens at its place, BookOrbit Home comes back if it was on top, the version remains in update status |
| Automatic (background check, the companion's daily job) | only when KOReader is out of the way: the screen goes off (restart), or another app is in front (KOReader saves and quits; the new plugin loads at its next start). Never on a closed book, BookOrbit Home or a list: the reader is still using KOReader |

`RestartPlan.decide` (`logic/prompts.lua`) and `UpdateFlow.restart` (companion `Logic.kt`) hold
these rules; `test_logic.lua` and `LogicTest` cover each trigger.

## Audit: plugin

Every `UIManager:show`, BookOrbit toast, `Jni.startActivity` and restart in `ko/*.lua` carries a
`-- gate: <why>` comment; `test_logic.lua` "reading gate" fails on a new one without it.

| Where | What | Gate |
|---|---|---|
| `ko/home.lua` `orbitNote` | short notes: "Applied N recommended settings", "Updated to vX" | `Gate.show`; a toast, so Home logic sees through it (`topWidget` skips it) |
| `ko/home.lua` `maybeRestart` | "close KOReader and open it again" (no companion) | `Gate.show` |
| `ko/home.lua` `restartForCompanion` | relaunch window, restart, quit | `RestartPlan` (manual, screen off, background) or the companion's own restart, which follows the same rule |
| `ko/home.lua` setup box | ConfirmBox | `SetupPrompt.decide` never shows it in a book; its buttons are user actions |
| `ko/home.lua` sign-in notes | "Signed in", "plugin isn't loaded" | user action (Setup's sign-in) |
| `ko/start.lua` `showWakeBanner` | "Can't reach BookOrbit" | background notice: suppressed and logged |
| `ko/endofbook.lua` next-sync downloads | "Downloaded: title" | `Gate.show` |
| `ko/endofbook.lua` sheet and its notes | end-of-book sheet | exception: the reader reached the end |
| `ko/badge.lua` Full refresh % badge | "37%", "Done" | exception: passive toast, the user's design |
| `ko/orbismart.lua` BookSync position sync popup | "Continue from Boox, p. 214? Yes / No" | exception: the user's ruling ([position sync](position-sync.md) ruling 1), one draw |
| `ko/cache.lua` `OC.note` | BookOrbit toasts | `Gate.installToast` wraps `bookorbit_toast.show`/`error` |
| `ko/cache.lua` offline miss | "This page isn't saved" ConfirmBox | user action (paging a list) |
| `ko/localfirst.lua` Remove | "This book is open" | user action |
| `ko/recommended.lua`, `ko/menu.lua`, `ko/companion_ui.lua`, `ko/test_sync_path.lua` | menus and their results | user action (menus) |
| `ko/sleep.lua` Sync and sleep | "Syncing…", "Synced" | user action; the screen goes off |
| BookOrbit toasts (sync results, conflicts shown as toasts) | `bookorbit_toast` | `Gate.installToast` |
| Wi-Fi "Connecting…" | KOReader's turn-on message | not shown: `wifi_backend.lua` brings the network up quietly |

BookOrbit's own modal dialogs (sync conflict, "further ahead") are not intercepted yet: they come
from its sync, which BookSync runs at wake and sleep, not mid-book.

## Audit: companion

One gate: `Reading.show(ctx, key, what) { post }` (`Reading.kt`, pure part `ReadingLogic.kt`). A
"reading" report lapses after 6 min without a new `STATS`. Held items post 1.5 s after a
non-reading moment with the screen on, and are dropped when their reason is gone. The guard test
`ReadingGuardTest` fails on a new `notify(` or `startActivity(` outside its allow-list (file, line
text, count, why).

| Where | What | Gate |
|---|---|---|
| `Attention.kt` setup reminder | notification | `Reading.show`; re-evaluated on release, so a step fixed meanwhile posts nothing |
| `Updater.kt` update ready (background check) | notification | `Reading.show`; dropped on install or when no longer newer. The Status page shows "Update ready · Install" any time |
| `Updater.kt` install prompt | activity | only for a check the reader started |
| `OrbitService.kt` Tailscale alert | notification | `Reading.show`; dropped when the VPN comes up |
| `OrbitService.kt` status | ongoing notification | low importance, never pops up |
| `OrbitKeys.kt` keyboard | notification | `Reading.show`; at once only when the reader focused a text field |
| `Installers.kt` KOReader install prompt | activity | `Reading.show`; dropped on success |
| `Core.kt` KOReader starts | activity | Home press, Setup taps, `RELAUNCH`; restarts follow the rule above |
| `Attention.kt`, `Pin.kt`, `Ui.kt`, `Launcher.kt`, `Clicker*.kt`, `Mode.kt`, `Pages.kt`, `ClickerService.kt` | pages, PIN | user actions |

Notification channels are quiet: no sound, no vibration, no heads-up (`updates_quiet`,
`alerts_quiet`; the old channels are deleted, since a channel's sound can't change).

## Xteink

The firmware should match: while a book is open, no OTA prompt, sync result banner or Tailscale
notice draws over the page; they show on the library or home screen, or after the next wake on a
non-reading screen. Automatic OTA installs only from the library screen or at sleep.

## Repainting an already visible owned modal

A ready response may inherit the background-notice scope. `Gate.show` accepts the
previous owned modal for replacement: it verifies that this widget is still
frontmost and `reading()` is false before running the replacement. A hidden modal
cannot authorize a show. The old dialog closes inside the approved operation, so
suppressing a replacement leaves the existing control intact. Source pickers also
wait while covered and retire their observer/timers on close. This does not change
the rule while a book is in the reading foreground.

For initial entry to that existing control, the explicit editor action supplies
its visible origin. The same frontmost/not-reading checks apply; catalog notice
suppression cannot disable a control the user is opening from the editor. An
automatic job has no such visible originating action.
