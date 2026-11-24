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
// Why it should run now: a hand start (the settings row, a hold on ⟳), never saved, the 7-day TTL,
// or a new library version.
bool requested();
void request();
orbify::mirror::Due dueNow();

struct Progress {
  void* context = nullptr;
  void (*step)(void* context, size_t done, size_t total) = nullptr;
};

// Wi-Fi up. Runs or resumes the plan until it is finished, cancelled() says stop, the network
// goes, or budgetMs (0 = no limit) is used. Returns true when it finished.
// maxSteps (0 = no limit) and heapFloor: the sleep sync's paced slice (patch 0037): a few requests
// per sleep, each only with OrbifyHeap's floor free, on the connection the sync lends.
bool run(bool (*cancelled)(), unsigned long budgetMs, const Progress* progress = nullptr, size_t maxSteps = 0,
         bool heapFloor = false);

// "Saved for offline · 3 h ago" / "Not saved for offline yet", for the settings row.
std::string savedLine();

}  // namespace OrbifyMirror
