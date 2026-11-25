#pragma once
// BookSync: nothing interrupts reading (the user's standing rule, both platforms). While a book is
// open in the reader, nothing the reader did not ask for may draw over it, repaint it, restart the
// device or take the screen: a message, an "update available" prompt, a sync or WiFi status, a
// background repaint. Those are held: the caller drops them or shows them at the next screen that
// is not the book (Home, the catalog, the Library). Shown anyway: the End-of-Book page (reached
// by reading), a menu or screen the reader opened, and what happens behind the sleep screen.
// The table is shared/fixtures/reading-quiet/cases.json (no Android test reads it yet: REGISTRY.json).
namespace orbify::quiet {

enum class Event {
  BackgroundRender,  // a screen that is not on display asks for a repaint (the background sync)
  Message,           // a toast or popup nobody asked for
  UpdatePrompt,      // "an update is available"
  NetworkStatus,     // WiFi or Tailscale coming up, going down, failing
  SyncStatus,        // a sync's progress or result
  Restart,           // a restart into another boot
  EndOfBook,         // the End-of-Book page
  UserOpened,        // a menu or screen the reader opened, and what it shows
  DuringSleep,       // behind the sleep screen
};

// reading: a book is open in the reader (it, or a screen it opened, is on display).
bool mayShow(Event event, bool reading);

// The fixture's names ("message", "update-prompt", ...); false when unknown.
bool eventFromName(const char* name, Event& out);
const char* eventName(Event event);

}  // namespace orbify::quiet
