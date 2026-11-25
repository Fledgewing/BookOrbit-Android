// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// BookSync offline mirror, X4 Pro and X4 (CROSSINK_TAILNET_ORBIFY_MIRROR;
// docs/design/ write-through-cache.md "Offline mirror", Xteink section;
// XTEINK-BUILD-NOTES "Offline mirror"). Full refresh lives in RefreshRunner's
// global task and SD journals. Walk is an activity's progress attachment, or
// the existing one-view Refresh. Leaving an activity does not stop a Full
// refresh. See docs/design/xteink-full-refresh-sd.md.
#include <cstddef>
#include <cstdint>
#include <string>

#include "RefreshRunner.h"
#include "Wifi.h"
#include "core/Mirror.h"

namespace OrbifyMirror {

// A mirror finished before: when (epoch s, 0 = never or clock unset).
bool saved();
uint32_t savedAt();
// Only a user action (settings, sync-tile hold, catalog hold) requests a Full
// refresh.
bool requested();
void request();
// Generic Loading/refresh reboot popups are suppressed throughout this user
// run, including the final return after its request marker is removed. Resets
// naturally at the next boot.
bool quietRestart();
orbify::mirror::Due dueNow();
// Cheap recent-items validation, only on the sleep sync's existing Wi-Fi
// session.
void refreshChanged(bool (*cancelled)());

struct Progress {
  void* context = nullptr;
  // After each request: the one % (core Plan::percent), never lower than the
  // last.
  void (*step)(void* context, unsigned percent) = nullptr;
};

// Legacy sleep-slice hook: Full refresh is owned by the global worker, so this
// never starts a second walker on the sleep sync's stack.
bool run(bool (*cancelled)(), unsigned long budgetMs, const Progress* progress = nullptr, size_t maxSteps = 0,
         bool heapFloor = false);

// "Saved for offline · 3 h ago" / "Not saved for offline yet", for the settings
// row.
std::string savedLine();

// The main-loop worker's in-memory snapshot; no whole-plan read on the UI task.
int pendingPercent();

// Activity attachment for Full refresh, or one-view Refresh.
class Walk {
 public:
  // A user start persists its request; a resume requires an existing user
  // request.
  void begin(bool userStarted = false);
  void beginView(const orbify::mirror::Step& view, int page = 1);
  ~Walk() { end(); }
  bool active() const { return started; }
  bool full() const { return started && !viewOnly; }
  bool finished() const;
  // One request, under OrbifyCache's Full mode. Saves the plan; on the last
  // one, the mirror.
  void step();
  unsigned percent() const;
  size_t failures() const;
  void end();
  // The activity could not open its connection. Keep the request resumable,
  // show one final error.
  void failConnection() { connectionFailed = true; }

 private:
  orbify::mirror::Plan plan;
  bool started = false;
  bool viewOnly = false;
  int viewPage = 1;
  bool wifiHeld = false;
  bool connectionFailed = false;
  unsigned long startedAt = 0;
};

}  // namespace OrbifyMirror
