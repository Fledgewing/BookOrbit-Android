// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <ArduinoJson.h>
#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace orbify::bulk {
// Protocol state is deliberately independent of HTTP, FreeRTOS and SD. A page and its
// next cursor must be committed by the caller before advance() is called.
class ManifestCursor {
 public:
  std::string cursor;
  bool complete = false;
  unsigned restarts = 0;
  bool accept(JsonVariantConst page, std::string& error) {
    if (page["restartRequired"] == true) {
      if (++restarts > 1) { error = "manifest repeatedly restarted"; return false; }
      cursor.clear(); seen.clear(); complete = false; return true;
    }
    if (!page["items"].is<JsonArrayConst>()) { error = "manifest items missing"; return false; }
    const bool more = page["hasNext"] | false;
    const std::string next = page["nextCursor"] | "";
    if (more && (next.empty() || next == cursor || seen.count(next))) {
      error = "manifest cursor did not advance"; return false;
    }
    if (!cursor.empty()) seen.insert(cursor);
    cursor = next;
    complete = !more;
    return true;
  }
 private:
  std::set<std::string> seen;
};
inline std::string status(const std::string& value) {
  if (value == "reading" || value == "rereading" || value == "on_hold") return "reading";
  if (value == "finished" || value == "read" || value == "skimmed" || value == "abandoned") return "finished";
  return "unread";
}
// Summary equality is not a member-set digest. A replacement writes books.updatedAt in
// the pinned server. Reconcile an affected old/new membership, never all primary lists.
inline bool needsSecondary(size_t primary, size_t server, bool ambiguous = false) {
  return ambiguous || primary != server;
}
inline bool reconcileSecondary(bool haveSaved, size_t savedCount, size_t currentCount,
                               bool affectedRecordChanged) {
  return !haveSaved || savedCount != currentCount || affectedRecordChanged;
}

// Progress survives discovery and a resumed run. A base publication is usable, but does
// not claim completion while the later secondary-series phase is unfinished.
struct Progress {
  unsigned shown = 0;
  bool basePublished = false, complete = false;
  void phase(unsigned value) { shown = std::max(shown, std::min(99u, value)); }
  void publishBase() { basePublished = true; phase(90); }
  void finish(bool allRequiredPublished) {
    complete = allRequiredPublished;
    if (complete) shown = 100;
  }
};
}  // namespace orbify::bulk
