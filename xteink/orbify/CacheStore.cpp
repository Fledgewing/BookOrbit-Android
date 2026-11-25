// SPDX-License-Identifier: GPL-3.0-or-later
#include "CacheStore.h"

#if CROSSINK_TAILNET_ORBIFY_CACHE
#include <Arduino.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <esp_heap_caps.h>

#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>

#include "BookOrbitCredentialStore.h"
#include "core/LocalFirst.h"

namespace OrbifyCache {
namespace {

using namespace orbify::cache;

constexpr char TAG[] = "ORBC";
constexpr char DIR[] = "/.crosspoint/bookorbit-cache";
constexpr char INDEX_PATH[] = "/.crosspoint/bookorbit-cache/index.bin";
constexpr char INDEX_TMP[] = "/.crosspoint/bookorbit-cache/index.tmp";
constexpr uint32_t MIN_PLAUSIBLE_EPOCH = 1700000000u;  // as BookOrbitHomeStore
constexpr size_t MAX_INDEX_BYTES = 128 * 1024;
constexpr size_t MAX_REPLY_BYTES = 512 * 1024;  // a reply larger than this is not parsed again here

// Whole replies are parsed here (to hash or patch them), never only the view's fields: their
// nodes go to PSRAM, so the TLS session and the UI keep the internal heap (X4s only).
class PsramAllocator final : public ArduinoJson::Allocator {
 public:
  void* allocate(size_t size) override { return heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT); }
  void deallocate(void* ptr) override { heap_caps_free(ptr); }
  void* reallocate(void* ptr, size_t size) override {
    return heap_caps_realloc(ptr, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
};
PsramAllocator psram;

// The sleep sync, the background sync (0022) and the catalog's revalidation run on their own tasks.
std::recursive_mutex s_lock;
Mode s_mode = Mode::Open;
bool s_loaded = false;
Index s_index;

uint32_t nowSeconds() {
  const time_t t = time(nullptr);
  return t >= static_cast<time_t>(MIN_PLAUSIBLE_EPOCH) ? static_cast<uint32_t>(t) : 0;
}

uint32_t currentOwner() {
  return orbify::ownerKey(BOOKORBIT_STORE.getBaseUrl().c_str(), BOOKORBIT_STORE.getUsername().c_str());
}

std::string entryPath(const uint32_t hash) {
  char path[64];
  snprintf(path, sizeof(path), "%s/%08lx.json", DIR, static_cast<unsigned long>(hash));
  return path;
}

std::string pathOf(const std::string& url) {
  const size_t scheme = url.find("://");
  const size_t start = url.find('/', scheme == std::string::npos ? 0 : scheme + 3);
  if (start == std::string::npos) return "/";
  const size_t end = url.find('?', start);
  return url.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

bool readFile(const std::string& path, std::string& out, const size_t cap) {
  HalFile file;
  if (!Storage.exists(path.c_str()) || !Storage.openFileForRead(TAG, path, file)) return false;
  const size_t size = file.fileSize();
  if (size > cap) {
    file.close();
    return false;
  }
  out.resize(size);
  const int n = size ? file.read(&out[0], size) : 0;
  file.close();
  return n == static_cast<int>(size);
}

bool writeFile(const char* path, const std::string& data) {
  HalFile file;
  if (!Storage.openFileForWrite(TAG, path, file)) return false;
  const bool ok = file.write(data.data(), data.size()) == data.size();
  file.close();
  return ok;
}

void save() {
  const std::string bytes = serializeIndex(s_index);
  if (writeFile(INDEX_TMP, bytes)) {
    Storage.remove(INDEX_PATH);
    Storage.rename(INDEX_TMP, INDEX_PATH);
  }
}

void wipe() {
  Storage.removeDir(DIR);
  Storage.mkdir(DIR);
  s_index = Index{};
  s_index.owner = currentOwner();
}

// The index, loaded once; another server or account drops everything first.
Index& index() {
  if (!s_loaded) {
    s_loaded = true;
    Storage.mkdir(DIR);
    std::string bytes;
    if (!readFile(INDEX_PATH, bytes, MAX_INDEX_BYTES) ||
        !deserializeIndex(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), s_index)) {
      if (Storage.exists(INDEX_PATH)) LOG_INF(TAG, "Cache index unreadable: starting empty");
      wipe();
    }
  }
  const uint32_t owner = currentOwner();
  if (s_index.owner != owner) {
    LOG_INF(TAG, "Another server or account: cache dropped");
    wipe();
    save();
  }
  return s_index;
}

bool isHome(const std::string& url) { return pathOf(url).find("/catalog/dashboard") != std::string::npos; }

void evict() {
  Index& idx = index();
  std::vector<EntryInfo> info;
  info.reserve(idx.entries.size());
  for (const auto& e : idx.entries) info.push_back({e.bytes, e.usedAt, isHome(e.url)});
  std::vector<size_t> drop(info.size());
  const size_t n = entriesToEvict(info.data(), info.size(), MAX_BYTES, MAX_ENTRIES, drop.data(), drop.size());
  if (!n) return;
  std::vector<bool> gone(idx.entries.size(), false);
  for (size_t i = 0; i < n; i++) {
    gone[drop[i]] = true;
    Storage.remove(entryPath(idx.entries[drop[i]].hash).c_str());
  }
  std::vector<IndexEntry> kept;
  for (size_t i = 0; i < idx.entries.size(); i++)
    if (!gone[i]) kept.push_back(std::move(idx.entries[i]));
  idx.entries.swap(kept);
  LOG_INF(TAG, "Evicted %u least recently used entries", static_cast<unsigned>(n));
}

// canonicalHash of the reply in `path` (0 when it does not parse).
uint32_t hashReply(const std::string& path) {
  HalFile file;
  if (!Storage.openFileForRead(TAG, path, file)) return 0;
  JsonDocument doc(&psram);
  struct Reader {
    HalFile& f;
    int read() { return f.read(); }
    size_t readBytes(char* b, size_t n) {
      const int got = f.read(b, n);
      return got > 0 ? static_cast<size_t>(got) : 0;
    }
  } reader{file};
  const DeserializationError error = deserializeJson(doc, reader);
  file.close();
  return error ? 0 : canonicalHash(doc.as<JsonVariantConst>());
}

}  // namespace

ScopedMode::ScopedMode(const Mode mode) : previous(s_mode) { s_mode = mode; }
ScopedMode::~ScopedMode() { s_mode = previous; }
Mode currentMode() { return s_mode; }

Lookup lookup(const std::string& url) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Lookup l;
  if (!BOOKORBIT_STORE.hasCredentials() || !isCacheable("GET", pathOf(url))) {
    l.fetch = true;
    return l;
  }
  l.cacheable = true;
  const std::string key = keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", url);
  l.hash = keyHash(key);
  l.path = entryPath(l.hash);
  const IndexEntry* e = index().find(l.hash);
  l.hasEntry = e != nullptr && Storage.exists(l.path.c_str());
  const bool offline = WiFi.status() != WL_CONNECTED;
  const uint32_t now = nowSeconds();
  const ReadPlan plan = planRead(l.hasEntry, l.hasEntry ? e->validatedAt : 0, now, s_mode, offline);
  l.serve = plan.serve;
  l.fetch = plan.fetch;
  // Without a clock the 60 s window can't be measured: online, ask the server.
  if (!offline && now == 0) l.fetch = true;
  return l;
}

bool storeReply(const Lookup& l, const std::string& url, const char* tmpPath) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (!l.cacheable) return false;
  Index& idx = index();
  HalFile probe;
  uint32_t bytes = 0;
  if (Storage.openFileForRead(TAG, tmpPath, probe)) {
    bytes = static_cast<uint32_t>(probe.fileSize());
    probe.close();
  }
  const uint32_t replyHash = bytes <= MAX_REPLY_BYTES ? hashReply(tmpPath) : 0;
  IndexEntry* e = idx.find(l.hash);
  const Revalidated r = revalidate(200, e != nullptr, e ? e->replyHash : 0, replyHash);
  Storage.remove(l.path.c_str());
  if (!Storage.rename(tmpPath, l.path.c_str())) {
    LOG_ERR(TAG, "Couldn't keep the reply for %s", url.c_str());
    if (e) e->validatedAt = 0;
    return false;
  }
  if (!e) {
    idx.entries.emplace_back();
    e = &idx.entries.back();
    e->hash = l.hash;
  }
  const uint32_t now = nowSeconds();
  e->bytes = bytes;
  e->fetchedAt = now;
  e->validatedAt = now;
  e->usedAt = ++idx.clock;
  e->replyHash = replyHash;
  e->flags = 0;
  e->url = url.size() <= 255 ? url : std::string();
  evict();
  save();
  if (r.changed) LOG_INF(TAG, "Changed on the server: %s", pathOf(url).c_str());
  return r.changed;
}

void markNotUpdated(const Lookup& l) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (IndexEntry* e = l.cacheable ? index().find(l.hash) : nullptr) {
    e->flags |= FLAG_NOT_UPDATED;
    e->usedAt = ++index().clock;
    save();
  }
}

void markUsed(const Lookup& l) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (IndexEntry* e = l.cacheable ? index().find(l.hash) : nullptr) {
    e->usedAt = ++index().clock;
    save();
  }
}

void afterWrite(const char* method, const std::string& url, const char* body, const size_t bodyLength,
                const int status) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (!BOOKORBIT_STORE.hasCredentials()) return;
  JsonDocument payload;
  if (body && bodyLength) deserializeJson(payload, body, bodyLength);
  const WriteEffect effect = writeEffect(method, pathOf(url), status, payload.as<JsonVariantConst>());
  if (!effect.homeStale && effect.bookId <= 0) return;
  Index& idx = index();
  char needle[32];
  snprintf(needle, sizeof(needle), "\"id\":%lld", static_cast<long long>(effect.bookId));
  unsigned patched = 0;
  for (auto& e : idx.entries) {
    if (effect.homeStale && isHome(e.url)) e.validatedAt = 0;
    if (effect.bookId <= 0) continue;
    const std::string path = entryPath(e.hash);
    std::string text;
    if (!readFile(path, text, MAX_REPLY_BYTES)) continue;
    // Only replies that list the book are parsed.
    bool listed = false;
    for (size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + 1)) {
      const char next = at + strlen(needle) < text.size() ? text[at + strlen(needle)] : '\0';
      if (next < '0' || next > '9') {
        listed = true;
        break;
      }
    }
    if (!listed) continue;
    JsonDocument doc(&psram);
    if (deserializeJson(doc, text)) continue;
    if (!patchBook(doc.as<JsonVariant>(), effect.bookId, effect.fields.as<JsonObjectConst>())) continue;
    text.clear();
    serializeJson(doc, text);
    if (writeFile(path.c_str(), text)) {
      e.bytes = static_cast<uint32_t>(text.size());
      e.replyHash = canonicalHash(doc.as<JsonVariantConst>());
      patched++;
    } else {
      Storage.remove(path.c_str());
      e.validatedAt = 0;
    }
  }
  save();
  LOG_INF(TAG, "%s %s -> %d: %u saved replies patched%s", method, pathOf(url).c_str(), status, patched,
          effect.homeStale ? ", Home due" : "");
}

Freshness freshness(const std::string& url) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Freshness f;
  if (!BOOKORBIT_STORE.hasCredentials()) return f;
  const IndexEntry* e = index().find(keyHash(keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", url)));
  if (!e) return f;
  f.saved = true;
  f.validatedAt = e->validatedAt ? e->validatedAt : e->fetchedAt;
  f.notUpdated = (e->flags & FLAG_NOT_UPDATED) != 0;
  return f;
}

bool coverRecord(const int32_t bookId, CoverRecord& out) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  const CoverRecord* c = index().cover(bookId);
  if (!c) return false;
  out = *c;
  return true;
}

void coverStored(const int32_t bookId, const uint32_t version, const std::string& etag) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Index& idx = index();
  CoverRecord* c = idx.cover(bookId);
  if (!c) {
    if (idx.covers.size() >= MAX_COVER_RECORDS) idx.covers.erase(idx.covers.begin());
    idx.covers.push_back({bookId, version, etag});
  } else {
    c->version = version;
    c->etag = etag;
  }
  save();
}

void mergeRecent() {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Index& idx = index();
  JsonDocument recent(&psram);
  for (const auto& e : idx.entries) {
    if (e.url.find("sort=recently_updated") == std::string::npos) continue;
    std::string text;
    if (readFile(entryPath(e.hash), text, MAX_REPLY_BYTES)) {
      const auto error = deserializeJson(recent, text);
      if (error) LOG_ERR(TAG, "Catalog incremental: recent page parse failed (%s)", error.c_str());
    }
    break;
  }
  const JsonArrayConst items = recent["items"].as<JsonArrayConst>();
  if (items.isNull()) {
    LOG_INF(TAG, "Catalog incremental: no saved recent-items page (%u entries)", static_cast<unsigned>(idx.entries.size()));
    return;
  }
  unsigned changed = 0;
  for (auto& e : idx.entries) {
    if (e.url.find("sort=recently_updated") != std::string::npos) continue;
    std::string text;
    if (!readFile(entryPath(e.hash), text, MAX_REPLY_BYTES)) continue;
    JsonDocument doc(&psram);
    if (deserializeJson(doc, text) || !mergeRecentBooks(doc.as<JsonVariant>(), items)) continue;
    text.clear();
    serializeJson(doc, text);
    // Keep the previous reply if a write is interrupted: use a side file first.
    const std::string path = entryPath(e.hash);
    const std::string tmp = path + ".tmp";
    if (!writeFile(tmp.c_str(), text)) continue;
    Storage.remove(path.c_str());
    if (!Storage.rename(tmp.c_str(), path.c_str())) continue;
    e.bytes = static_cast<uint32_t>(text.size());
    e.replyHash = canonicalHash(doc.as<JsonVariantConst>());
    ++changed;
  }
  if (changed) save();
  LOG_INF(TAG, "Catalog incremental: %u saved replies changed (one recent-items page)", changed);
}

void dropAll() {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  s_loaded = true;
  wipe();
  save();
}

}  // namespace OrbifyCache

// The hook sendBookOrbitRequest calls (lib/BookOrbitSync, declared weak there).
void orbifyCacheAfterWrite(const char* method, const std::string& url, const char* body, const size_t bodyLength,
                           const int status) {
  OrbifyCache::afterWrite(method, url, body, bodyLength, status);
}

#endif  // CROSSINK_TAILNET_ORBIFY_CACHE
