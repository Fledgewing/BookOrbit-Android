#pragma once
// BookSync: nothing interrupts reading (core/ReadingQuiet). The overlay asks allow() before it draws,
// repaints or restarts on its own; a held event is logged ("ORB Quiet: held ...") and dropped.
//
// Where the overlay asks (xteink/README.md, "Nothing interrupts reading"):
//   - BookOrbitSyncActivity, for a background sync in the reader (patch 0022's task): every
//     repaint it asks for is a BackgroundRender (patch 0031);
//   - the live catalog's "Connecting to Tailscale..." popup: NetworkStatus (TailnetNetPhase.cpp).
// Everything else the overlay shows comes from a screen the reader opened (Settings, Check for
// updates, a sync from the reader's menu, Tailscale login), the End-of-Book page, or the sleep
// sync, and has no update check on a timer.
#include "core/ReadingQuiet.h"

namespace OrbifyQuiet {

// A book is open in the reader: it, or a screen it opened, is on display.
bool reading();

// May this event show now? Logs and returns false when it is held.
bool allow(orbify::quiet::Event event);

}  // namespace OrbifyQuiet
