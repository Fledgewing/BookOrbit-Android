-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Smart Home (android/docs/INTERFACE.md "go home"). What Home does in KOReader.
--   mode: "smart" | HomePlan.SERVER_HOME; in_reader: a book is open; covered: a menu or the
--   plugin's views are over it; on_dashboard: the plugin's BookOrbit home (dashboard) is the
--   top widget; from_other: Home came from another app (or KOReader was just started);
--   reopen: a current book that isn't open now and still exists: the book Home itself closed
--   (home_book), or the one KOReader was killed with (cold start, open_book_at_exit). A book
--   the user closed is never reopened from history.
-- bookorbit_sub: a BookOrbit screen that isn't its main page is on top (BookOrbit.screen).
-- Returns "bookorbit_main" (that BookOrbit main page), "companion" (the companion's launcher page), "dashboard" (close any book,
-- BookOrbit home) or "book" (show the book: close what covers it, or open the last one).
-- Presses in KOReader step book -> BookOrbit home -> companion; Home from another app (the
-- companion included) goes back to the book, so the steps never loop.
HomePlan = {}

function HomePlan.decide(o)
    -- A BookOrbit page past its first (the dashboard's page 2, a list's page 3), nothing over
    -- it: page 1 first; only page 1 leaves (v0.5.4).
    if o.page_above_1 and not o.from_other then return "first_page" end
    -- Any BookOrbit screen other than its main page (a detail, list, search, board, settings,
    -- a sheet or dialog over the catalog): back to the main page (v0.4.9).
    if o.library_sub then return "library_main" end
    if o.on_dashboard and not o.from_other then return "companion" end
    if o.mode ~= "smart" then return "dashboard" end
    if o.in_reader then
        if not o.covered and not o.from_other then return "dashboard" end
        return "book"
    end
    if o.reopen then return "book" end
    return "dashboard"
end

-- KOReader was in the background this long before the command arrived: Home from inside
-- KOReader pauses it for well under this; a stay in another app is longer.
HomePlan.OTHER_APP_S = 2.5

function HomePlan.cameFromOtherApp(from_extra, suspended_s)
    if from_extra == "other_app" then return true end
    if from_extra == "koreader" then return false end
    return suspended_s == nil or suspended_s >= HomePlan.OTHER_APP_S
end

-- The rotation Home keeps (BookOrbit Home must never turn the device from how it is held).
-- On Android, KOReader's rotation is the activity's requestedOrientation (koreader-base
-- ffi/framebuffer_android.lua:78-91: mode 0-3 -> PORTRAIT, LANDSCAPE, REVERSE_PORTRAIT,
-- REVERSE_LANDSCAPE), which turns the whole display. Every new file browser forces its own
-- rotation, fm_rotation_mode or upright (filemanager.lua:63-69, from showFiles :1321: KOReader's
-- start, reader.lua:291, and every book close, readerui.lua:594, since opening a book closes the
-- file browser, readerui.lua:787-788), and BookOrbit Home sits over it.
-- held: the companion's ROTATION extra, the display's orientation when Home was pressed.
HomePlan.ROTATIONS = { portrait = 0, landscape = 1, reverse_portrait = 2, reverse_landscape = 3 }

-- The KOReader rotation mode to set before Home's action, or nil to leave it. o: action
-- (HomePlan.decide), held (ROTATION extra or nil), current (Screen:getRotationMode()), in_reader,
-- locked (KOReader's "Lock auto rotation", lock_rotation). Never in a book: a book keeps its own
-- rotation (readerview.lua:968-975), and one set here would be saved into it (:1220-1222).
function HomePlan.rotation(o)
    local mode = HomePlan.ROTATIONS[o.held or ""]
    if mode == nil or o.locked or o.in_reader then return nil end
    if o.action == "book" or o.action == "companion" then return nil end
    if mode == o.current then return nil end
    return mode
end

-- "<app> is disabled by <launcher label>: re-enable it in <label> › <hint>.", or a neutral text.
-- Pure (tested): disabler is the label read at run time, or nil.
function disabledText(app, disabler, hint)
    if disabler and hint then
        return string.format("%s is disabled by %s: re-enable it in %s › %s.", app, disabler, disabler, hint)
    elseif disabler then
        return string.format("%s is disabled by %s: re-enable it there.", app, disabler)
    end
    return app .. " is disabled by the system: re-enable it in Settings › Apps."
end

-- One additive Android 0.12 cutover; all other settings and ledgers stay untouched.
function HomePlan.migrate012(settings)
    if settings.home_012_migrated then return false end
    local upgrade = next(settings) ~= nil
    settings.home_screen = "booksync"
    settings.news_012_pending = upgrade
    settings.home_012_migrated = true
    return true
end
