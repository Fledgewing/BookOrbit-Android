// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Orbify write-through cache, the firmware side
// (docs/design/write-through-cache.md, "Xteink"): the entries on the SD card
// and the hooks CrossInk calls (overlay patch 0029). The rules are
// core/CatalogCache's. X4 Pro and X4 only: built with
// CROSSINK_TAILNET_ORBIFY_CACHE, and every hook that calls it sits behind the
// same switch, so the X3 keeps today's catalog and none of this code.
//
//   - Reads: fetchJson asks lookup() before the request and either parses the
//   saved reply
//     (offline, checked in the last 60 s) or downloads as before; a 2xx reply
//     is kept with storeReply() instead of being deleted. A failed request
//     falls back to the saved one.
//   - Writes: sendBookOrbitRequest calls afterWrite() with the status: a
//   read-status or rating
//     patches the book wherever a saved reply lists it, and Home is checked on
//     its next read.
//   - Covers: coverRecord()/coverStored() keep each cover's version and ETag
//   (the Home covers'
//     <ver> is the same hash), so a metadata-only edit costs a 304.
#include <ArduinoJson.h>
#include <CrossInkTailnetCuts.h>

#include <cstdint>
#include <string>

#include "core/CatalogCache.h"
#include "core/RefreshPlan.h"

namespace OrbifyCache {

// The mode of the catalog requests made while it is in scope (⟳ = Refresh, hold
// = Full).
class ScopedMode {
 public:
  explicit ScopedMode(orbify::cache::Mode mode);
  ~ScopedMode();

 private:
  orbify::cache::Mode previous;
};
orbify::cache::Mode currentMode();

struct Lookup {
  bool cacheable = false;
  bool hasEntry = false;
  bool serve = false;  // parse `path` now
  bool fetch = false;  // ask the server
  uint32_t hash = 0;
  std::string path;  // the saved reply
};
Lookup lookup(const std::string& url);
// The reply at tmpPath answered `url` with a 2xx: keep it (renamed, not
// copied). Returns true when the view's content changed (always false for a
// first fetch).
bool storeReply(const Lookup& lookup, const std::string& url, const char* tmpPath);
// The server did not answer: the saved reply is served and its stamp says "Not
// updated".
void markNotUpdated(const Lookup& lookup);
// Served from the saved file: no write, eviction or revalidation.
void markUsed(const Lookup& lookup);

void afterWrite(const char* method, const std::string& url, const char* body, size_t bodyLength, int status);

// The freshness of the reply `url` is answered from: fetchedAt/validatedAt in
// epoch seconds, 0 = none.
struct Freshness {
  bool saved = false;
  uint32_t validatedAt = 0;
  bool notUpdated = false;
};
Freshness freshness(const std::string& url);

// Covers
// -------------------------------------------------------------------------------------

// The version and ETag kept for book `bookId`'s cover; false when none is kept.
bool coverRecord(int32_t bookId, orbify::cache::CoverRecord& out);
// A 200 stored the cover at `version` with this ETag (empty: the server sent
// none), or a 304 confirmed the kept file, which the caller renamed to
// `version`.
void coverStored(int32_t bookId, uint32_t version, const std::string& etag);

// Signed out, or another server or account: the cache directory goes.
void dropAll();
// Merge changed fields from the last recently_updated head into already saved
// book rows.
std::vector<int64_t> mergeRecent();
uint64_t bytesOnSd();
void setPlanBytes(uint64_t bytes);
orbify::mirror::Stop storageStop();
void clearStorageStop();
bool roomForReply();

}  // namespace OrbifyCache
