// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Orbify offline mirror, X4 Pro and X4 (CROSSINK_TAILNET_ORBIFY_MIRROR; docs/design/
// write-through-cache.md "Offline mirror", Xteink section; XTEINK-BUILD-NOTES "Offline mirror").
// A Full refresh: the catalog's root, the first page of each section and of the lists they link to,
// and the details of the books on the reader and their next in series, fetched again whatever the
// cache holds (OrbifyCache::ScopedMode Full), so the catalog then opens offline from the cache.
// One request at a time, from a plan kept on the card that resumes after a wake or a reset.
#include <cstddef>
#include <cstdint>
#include <string>

#include "core/Mirror.h"

namespace OrbifyMirror {

// A mirror finished before: when (epoch s, 0 = never or clock unset).
bool saved();
uint32_t savedAt();
// Only a user action (settings, sync-tile hold, catalog hold) requests a Full refresh.
bool requested();
void request();
orbify::mirror::Due dueNow();
// Cheap recent-items validation, only on the sleep sync's existing Wi-Fi session.
void refreshChanged(bool (*cancelled)());

struct Progress {
  void* context = nullptr;
  // After each request: the one % (core Plan::percent), never lower than the last.
  void (*step)(void* context, unsigned percent) = nullptr;
};

// Wi-Fi up. Runs or resumes the plan until it is finished, cancelled() says stop, the network
// goes, or budgetMs (0 = no limit) is used. Returns true when it finished.
// maxSteps (0 = no limit) and heapFloor: the sleep sync's paced slice (patch 0037): a few requests
// per sleep, each only with OrbifyHeap's floor free, on the connection the sync lends.
bool run(bool (*cancelled)(), unsigned long budgetMs, const Progress* progress = nullptr, size_t maxSteps = 0,
         bool heapFloor = false);

// "Saved for offline · 3 h ago" / "Not saved for offline yet", for the settings row.
std::string savedLine();

// A Full refresh asked for and not finished yet (a hand start, paused by leaving the catalog or the
// refresh boot; the sleep syncs carry it on): its % (core Plan::percent), else -1. Reads the plan.
int pendingPercent();

// A Full refresh walked one request at a time from an activity's loop(), so the reader keeps
// browsing between requests (docs/design/sqlite-cache.md "Xteink: the same rule"). The caller
// holds the connection (the catalog's boot session, or a Session) and checks Wi-Fi.
class Walk {
 public:
  // A user start persists its request; a resume requires an existing user request.
  void begin(bool userStarted = false);
  bool active() const { return started; }
  bool finished() const { return started && (connectionFailed || plan.finished()); }
  // One request, under OrbifyCache's Full mode. Saves the plan; on the last one, the mirror.
  void step();
  unsigned percent() const { return plan.percent(); }
  size_t failures() const { return plan.failures() + (connectionFailed ? 1 : 0); }
  void end() { started = false; }
  // The activity could not open its connection. Keep the request resumable, show one final error.
  void failConnection() { connectionFailed = true; }

 private:
  orbify::mirror::Plan plan;
  bool started = false;
  bool connectionFailed = false;
  unsigned long startedAt = 0;
};

}  // namespace OrbifyMirror
