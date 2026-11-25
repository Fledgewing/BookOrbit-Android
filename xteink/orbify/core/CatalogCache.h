// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Orbify write-through cache in front of BookOrbit (docs/design/write-through-cache.md, ROADMAP
// item 4): the rules, as pure functions. The firmware glue (CatalogCacheStore, the hooks in
// fetchJson, sendBookOrbitRequest and the cover downloads) only stores and moves files.
// xteink/test/cache_test.cpp checks these against shared/fixtures/cache/cases.json, the table
// Android's tests read too.
#include <ArduinoJson.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace orbify {
namespace cache {
// Match book rows by id and update only shared fields. Returns whether anything changed.
bool mergeRecentBooks(JsonVariant saved, JsonArrayConst recent);

// Reads checked less than this long ago are served without asking the server again (self-grill 4).
constexpr uint32_t REVALIDATE_WINDOW_S = 60;
// X4 budget (the design's "Size" row): bytes and entries on the SD card.

// Open: a view opened (served from the cache, checked after 60 s). Refresh: ⟳ or an automatic
// check (checked now). Full: Full refresh (the server's answer replaces the entry).
enum class Mode : uint8_t { Open, Refresh, Full };

// --- keys ------------------------------------------------------------------------------------

using Query = std::vector<std::pair<std::string, std::string>>;
// account + server + method + path + query, normalised: the server lower-case without a trailing
// "/", query parameters sorted, empty values dropped.
std::string makeKey(const std::string& account, const std::string& server, const std::string& method,
                    const std::string& path, const Query& query);
// The same from a full request URL ("https://host[:port]/path?query").
std::string keyForUrl(const std::string& account, const std::string& method, const std::string& url);
// FNV-1a 32 of a key: the entry's file name.
uint32_t keyHash(const std::string& key);
// Only catalog GETs are cached: never auth, version, progress, sync, thumbnails or downloads.
bool isCacheable(const std::string& method, const std::string& path);

// --- reads -----------------------------------------------------------------------------------

struct ReadPlan {
  bool serve = false;  // answer from the cache now
  bool fetch = false;  // ask the server (in the background when serve is set)
};
ReadPlan planRead(bool hasEntry, uint32_t validatedAt, uint32_t now, Mode mode, bool offline);
// What a read does with its plan (fetchJson, patch 0040): parse the saved reply with no request,
// make the request (its reply is kept; the saved one stands in if it fails), or neither: offline
// with nothing saved, the read fails at once and the caller connects or shows its error. Before,
// that last case made the request anyway: with Wi-Fi never started (the cache-first catalog, X4
// Pro .194) the lookup panicked in lwIP, whose TCP/IP stack did not exist yet.
enum class ReadStep : uint8_t { Saved, Request, Miss };
inline ReadStep readStep(const ReadPlan& plan) {
  if (plan.fetch) return ReadStep::Request;
  return plan.serve ? ReadStep::Saved : ReadStep::Miss;
}

// A hash of a JSON value in canonical form (object keys sorted), so a reply whose keys come in
// another order reads as the same reply. A top-level generatedAt and discover are left out: they
// change on every request.
uint32_t canonicalHash(JsonVariantConst value);

struct Revalidated {
  bool stored = false;   // the entry is written (or re-stamped)
  bool changed = false;  // the view showing this key redraws
};
// A server reply to a check of an entry with hash cachedHash (hadEntry false: none cached).
Revalidated revalidate(int status, bool hadEntry, uint32_t cachedHash, uint32_t replyHash);

// --- writes ----------------------------------------------------------------------------------

struct WriteEffect {
  int64_t bookId = 0;      // > 0: patch this book's fields wherever a cached body lists it
  bool homeStale = false;  // the Home body revalidates on its next read
  JsonDocument fields;     // {"readStatus": "read"} or {"rating": 4}
};
// What a write that came back with `status` does to the cache. A failed write does nothing.
WriteEffect writeEffect(const std::string& method, const std::string& path, int status, JsonVariantConst body);
// Sets `fields` on every object in `doc` whose "id" is bookId and that already has the field.
// Returns true when something changed.
bool patchBook(JsonVariant doc, int64_t bookId, JsonObjectConst fields);

// --- covers ----------------------------------------------------------------------------------

// The cover version: FNV-1a 32 of the book's updatedAt as the server lists it (the X4 Home covers'
// <ver>, BookOrbitHomeStore). Reading never changes it.
uint32_t coverVersion(const char* updatedAt);

enum class CoverFile : uint8_t { Missing, Ok, Empty, Corrupt };
struct CoverOnDisk {
  bool present = false;     // a file of this book is on the card (any version)
  uint32_t version = 0;
  CoverFile file = CoverFile::Missing;
  bool hasEtag = false;     // the server's ETag stored with it
};
enum class CoverAction : uint8_t { None, Download, Conditional };
struct CoverPlan {
  CoverAction action = CoverAction::None;
  bool removeFirst = false;  // the file on the card is broken: delete it before the download
};
// failedBefore: this book's cover failed earlier in the session (retried by Refresh, not by Open).
CoverPlan planCover(Mode mode, bool listedWithCover, uint32_t listedVersion, const CoverOnDisk& disk,
                    bool failedBefore);

// --- size --------------------------------------------------------------------------------------

struct EntryInfo {
  uint32_t bytes = 0;
  uint32_t usedAt = 0;   // last served or stored
  bool pinned = false;   // the Home body, the open book's detail: never evicted by a list page
};
// Which entries to drop, least recently used first, so the rest fit maxBytes and maxEntries.
// Fills `drop` with indexes; returns how many.
size_t entriesToEvict(const EntryInfo* entries, size_t count, uint32_t maxBytes, size_t maxEntries,
                      size_t* drop, size_t capacity);


// --- the index on the card ------------------------------------------------------------------

struct IndexEntry {
  uint32_t hash = 0;         // keyHash: the entry's file is <hash>.json
  uint32_t bytes = 0;
  uint32_t fetchedAt = 0;    // epoch seconds of the reply stored (0: clock not set)
  uint32_t validatedAt = 0;  // last time the server confirmed it; 0 = due (a write made it stale)
  uint32_t usedAt = 0;       // a counter: larger = used more recently
  uint32_t replyHash = 0;    // canonicalHash of the stored reply
  uint8_t flags = 0;         // FLAG_*
  std::string url;           // the request, for a revalidation that has no view open (<= 255 bytes)
};
constexpr uint8_t FLAG_NOT_UPDATED = 1;  // the last check failed: "Not updated · saved …"

struct CoverRecord {
  int32_t bookId = 0;
  uint32_t version = 0;  // coverVersion of the file on the card
  std::string etag;      // the thumbnail's ETag when it was fetched (<= 63 bytes), or empty
};

struct Index {
  uint32_t owner = 0;    // LocalFirst ownerKey(server, account): another owner drops the cache
  uint32_t clock = 0;    // the usedAt counter
  std::vector<IndexEntry> entries;
  std::vector<CoverRecord> covers;

  IndexEntry* find(uint32_t hash);
  CoverRecord* cover(int32_t bookId);
};
constexpr size_t MAX_COVER_RECORDS = 256;

// "OCI1", version, CRC-32 trailer. A torn or foreign file reads as false (the cache starts empty).
std::string serializeIndex(const Index& index);
bool deserializeIndex(const uint8_t* data, size_t size, Index& out);

}  // namespace cache
}  // namespace orbify
