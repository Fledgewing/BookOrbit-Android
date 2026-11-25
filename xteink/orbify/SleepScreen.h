#pragma once
// Orbify sleep screen, X4 Pro and X4 (docs/design/lock-screen.md, ROADMAP 11; the rules are
// core/SleepPick and core/SleepLayout). CrossInk calls it from overlay patch 0039:
//
//   - BookOrbit Pick, a Sleep Screen choice (Settings > Display > Sleep Screen): a recommended
//     cover from a batch of up to 24 kept ready in /.crosspoint/orbify_sleep/ (screen-size BMPs). The
//     sleep draws only from the card: it never waits on the network (R3, F7).
//   - The sleep sync tops the batch up by a few covers on the connection it lends, within
//     its own time budget, and decodes them with the radio off into PSRAM-backed buffers.
//   - The extras, text and battery level at sleep, in a band (Bar) or on plates (Overlay), on every
//     bitmap sleep screen and the default one (L3-L5).
//
// Switch (tailnet_build.py): CROSSINK_TAILNET_ORBIFY_SLEEP (0,1,1): the X3 builds none of it (design
// "The X3"; its settings strings are left out of the X3's i18n too).
#include <CrossInkTailnetCuts.h>

#include <cstdint>
#include <string>

#if CROSSINK_TAILNET_ORBIFY_SLEEP
#include "core/SleepLayout.h"
#include "core/SleepPick.h"

class GfxRenderer;

namespace OrbifySleep {

// --- settings (Settings > Display > Sleep Screen; the web settings page) -------------------------------

struct Settings {
  bool pick = false;              // BookOrbit Pick is the sleep screen (orbifySleep, S4)
  std::string from = "up_next";   // Pick From: a set, one item per line (core normalizeSources, R1c)
  std::string leaveTags;          // Leave Out Tags, comma-separated
  std::string leaveScopes;        // Leave Out Scopes: "library", "scope:<id>", "collection:<id>", one per line
  int hours = orbify::sleep::DEFAULT_HOURS;  // Change Every; 0 = Every sleep
  std::string text;               // Sleep Text (60 code points)
  bool battery = false;           // Battery on Sleep Screen
  orbify::sleep::Style style = orbify::sleep::Style::Bar;
  orbify::sleep::TextPos textPos = orbify::sleep::TextPos::Right;
  orbify::sleep::Corner batteryCorner = orbify::sleep::Corner::BottomLeft;
};
const Settings& settings();
// The settings to change, then save() (/.crosspoint/orbify_sleep/settings.json).
Settings& edit();
void save();

// The smart scopes and collections the account sees, as the last sleep sync saved them (scopes.tsv).
struct Scope {
  bool collection = false;
  bool library = false;
  uint32_t id = 0;
  int count = 0;
  std::string title;
};
bool readScopes(void (*each)(const Scope&, void* ctx), void* ctx);

// --- at sleep (SleepActivity) -------------------------------------------------------------------------------

// BookOrbit Pick is on.
bool active();
// The cover to draw at this sleep: its BMP path, or false (no ready cover: the caller draws CrossInk's
// Cover screen, then the default one, F1). redraw: the sleep sync's second pass (the same cover, and
// the time may be known now, R6). Logs "ORB Sleep: <mode> -> <shown> (<why>)".
bool pickCover(bool redraw, std::string& bmpPath);
// The chosen cover's file did not draw (F6): it leaves the batch, the next sync fetches it again.
void coverFailed(const std::string& bmpPath);

// The extras are on (text or battery).
bool extrasOn();
// The band's height when the Bar style shows (0 otherwise): the cover fits above it (L3).
int bandHeight(const GfxRenderer& renderer);
// Draws the band or the plates into the current render mode's buffer (once per grey plane). The
// battery is the level at sleep; a redraw draws the level its first pass recorded.
void drawExtras(const GfxRenderer& renderer, bool redraw);

// --- the sleep sync (BookOrbitSyncActivity::runSleepSync) --------------------------------------------------

// On the lent connection, after the next cover: the scope names, Leave out's member lists, the source
// list or bag, then up to FETCH_PER_SYNC covers. openBookPath: the book open at sleep (never picked).
void topUp(const std::string& openBookPath, bool (*stop)(), unsigned long budgetMs = 40000);
void drawPlaceholder(const GfxRenderer& renderer, bool redraw);
// With the radio off: fetched covers become screen-size BMPs (renderer: the panel's tone profile).
void decodeCovers(const GfxRenderer& renderer, bool (*stop)());

}  // namespace OrbifySleep
#endif
