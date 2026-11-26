// SPDX-License-Identifier: GPL-3.0-or-later
#include "CacheStore.h"
#include "BulkCatalog.h"
#include "HeapFloor.h"
#include "core/BulkCatalog.h"
#include "core/CatalogWindow.h"

#if CROSSINK_TAILNET_ORBIFY_CACHE
#include <Arduino.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>

#include "BookOrbitCredentialStore.h"
#include "Settings.h"
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

// Whole replies are parsed here (to hash or patch them), never only the view's
// fields: their nodes go to PSRAM, so the TLS session and the UI keep the
// internal heap (X4s only).
class PsramAllocator final : public ArduinoJson::Allocator {
 public:
  void* allocate(size_t size) override { return heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT); }
  void deallocate(void* ptr) override { heap_caps_free(ptr); }
  void* reallocate(void* ptr, size_t size) override {
    return heap_caps_realloc(ptr, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
};
PsramAllocator psram;

// The sleep sync, the background sync (0022) and the catalog's revalidation run
// on their own tasks.
std::recursive_mutex s_lock;
std::map<TaskHandle_t, Mode> modes;
Mode modeForTask() {
  const auto it = modes.find(xTaskGetCurrentTaskHandle());
  return it == modes.end() ? Mode::Open : it->second;
}
uint64_t sdBytes = 0, planBytes = 0;
bool usageKnown = false;
#ifdef SIMULATOR
unsigned repliesSinceClear = 0;
#endif
orbify::mirror::Stop stopReason = orbify::mirror::Stop::None;
bool s_loaded = false;
Index s_index;
// Only the three loaded browser windows need virtual-source stamps in RAM.
struct WindowStamp {uint32_t hash=0;Freshness value;};
WindowStamp windowStamps[3];size_t nextWindowStamp=0;

uint32_t nowSeconds() {
  const time_t t = time(nullptr);
  return t >= static_cast<time_t>(MIN_PLAUSIBLE_EPOCH) ? static_cast<uint32_t>(t) : 0;
}

uint32_t currentOwner() {
  return orbify::ownerKey(BOOKORBIT_STORE.getBaseUrl().c_str(), BOOKORBIT_STORE.getUsername().c_str());
}

std::string entryPath(const uint32_t hash) {
  char path[64];
  snprintf(path, sizeof(path), "%s/%02lx/%08lx.json", DIR, static_cast<unsigned long>(hash >> 24),
           static_cast<unsigned long>(hash));
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
  if (!Storage.exists(path.c_str()) && Storage.exists((path + ".bak").c_str()))
    Storage.rename((path + ".bak").c_str(), path.c_str());
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
  const bool synced = file.sync();
  file.close();
  return ok && synced;
}

bool replaceFile(const std::string& tmp, const std::string& path) {
  const auto backup = path + ".bak";
  // A reset between the two renames leaves the last good file recoverable.
  if (!Storage.exists(path.c_str()) && Storage.exists(backup.c_str()))
    Storage.rename(backup.c_str(), path.c_str());
  Storage.remove(backup.c_str());
  if (Storage.exists(path.c_str()) && !Storage.rename(path.c_str(), backup.c_str())) return false;
  if (!Storage.rename(tmp.c_str(), path.c_str())) {
    Storage.rename(backup.c_str(), path.c_str());
    return false;
  }
  Storage.remove(backup.c_str());
  return true;
}

bool readDocument(const std::string& path, JsonDocument& doc) {
  HalFile file = Storage.open(path.c_str());
  if (!file) return false;
  struct Reader {
    HalFile& file;
    int read() { return file.read(); }
    size_t readBytes(char* out, size_t count) {
      const int n = file.read(out, count);
      return n > 0 ? n : 0;
    }
  } reader{file};
  return !deserializeJson(doc, reader);
}
bool writeDocument(const std::string& path, JsonDocument& doc) {
  const auto tmp = path + ".tmp";
  HalFile file = Storage.open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC);
  if (!file) return false;
  const size_t expected = measureJson(doc);
  const bool ok = serializeJson(doc, file) == expected && file.sync();
  file.close();
  if (!ok) {
    Storage.remove(tmp.c_str());
    return false;
  }
  return replaceFile(tmp, path);
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
  for(auto& stamp:windowStamps)stamp={};
  s_index = Index{};
  s_index.owner = currentOwner();
}

// Each reply has one small CRC-protected sidecar on SD. A library-sized index
// never sits in internal RAM. The legacy index is migrated once; its covers
// remain bounded.
std::string metaPath(uint32_t hash) { return entryPath(hash) + ".idx"; }
bool loadEntry(uint32_t hash, IndexEntry& out) {
  std::string bytes;
  Index one;
  if (!readFile(metaPath(hash), bytes, 2048) ||
      !deserializeIndex(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), one) ||
      one.entries.size() != 1)
    return false;
  out = std::move(one.entries[0]);
  const auto path = entryPath(hash);
  if (!Storage.exists(path.c_str()) && Storage.exists((path + ".bak").c_str()))
    Storage.rename((path + ".bak").c_str(), path.c_str());
  return out.hash == hash && Storage.exists(entryPath(hash).c_str());
}
uint64_t fileBytes(const std::string& path) {
  HalFile file = Storage.open(path.c_str());
  return file ? file.fileSize64() : 0;
}
bool saveEntry(const IndexEntry& entry) {
  Index one;
  one.entries.push_back(entry);
  const auto bytes = serializeIndex(one);
  const auto path = metaPath(entry.hash), tmp = path + ".tmp";
  Storage.mkdir(path.substr(0, path.find_last_of('/')).c_str());
  if (!writeFile(tmp.c_str(), bytes)) return false;
  const uint64_t before = fileBytes(path);
  const bool ok = replaceFile(tmp, path);
  if (ok) sdBytes = sdBytes - std::min(sdBytes, before) + bytes.size();
  return ok;
}
template <class Visit>
void entriesIn(const char* directory, Visit& visit, bool root = false) {
  HalFile dir = Storage.open(directory);
  while (HalFile file = dir.openNextFile()) {
    char name[80]{};
    file.getName(name, sizeof(name));
    const bool directoryEntry = file.isDirectory();
    file.close();
    if (root && directoryEntry && strlen(name) == 2) {
      const auto path = std::string(directory) + "/" + name;
      entriesIn(path.c_str(), visit);
      continue;
    }
    unsigned long hash;
    if (strlen(name) != 17 || std::string(name + 8) != ".json.idx" || sscanf(name, "%8lx", &hash) != 1)
      continue;
    IndexEntry entry;
    if (loadEntry(static_cast<uint32_t>(hash), entry)) visit(entry);
  }
}
template <class Visit>
void eachEntry(Visit visit) {
  entriesIn(DIR, visit, true);
}
uint64_t directoryBytes(const char* directory) {
  if(!Storage.exists(directory))return 0;
  uint64_t bytes = 0;
  HalFile dir = Storage.open(directory);
  while (HalFile file = dir.openNextFile())
    if (!file.isDirectory()) bytes += file.fileSize64();
  return bytes;
}
void saveUsage() {
  constexpr const char* path = "/.crosspoint/bookorbit-cache/usage";
  constexpr const char* tmp = "/.crosspoint/bookorbit-cache/usage.tmp";
  usageKnown = writeFile(tmp, std::to_string(sdBytes) + "\n" + std::to_string(~sdBytes) + "\n") &&
               replaceFile(tmp, path);
  if (!usageKnown) stopReason = orbify::mirror::Stop::Io;
}
uint64_t treeBytes(const char* directory) {
  uint64_t bytes = 0;
  HalFile dir = Storage.open(directory);
  while (HalFile file = dir.openNextFile()) {
    if (!file.isDirectory())
      bytes += file.fileSize64();
    else {
      char name[80]{};
      file.getName(name, sizeof(name));
      file.close();
      const auto path = std::string(directory) + "/" + name;
      bytes += treeBytes(path.c_str());
    }
  }
  return bytes;
}
void measureUsage() {
  if (usageKnown) return;
  sdBytes = treeBytes(DIR);
  saveUsage();
}
uint64_t extraBytes() {
  return planBytes + OrbifyBulk::bytes() + directoryBytes("/.crosspoint/bookorbit_home") +
         directoryBytes("/.crosspoint/orbify_sleep");
}
uint64_t freeBytes() {
#ifdef SIMULATOR
  if (const char* count = std::getenv("ORBIFY_SIM_SD_FULL_AFTER"))
    if (repliesSinceClear >= strtoul(count, nullptr, 10)) return orbify::mirror::SD_MARGIN - 1;
  if (const char* value = std::getenv("ORBIFY_SIM_SD_FREE_BYTES")) return strtoull(value, nullptr, 10);
#endif
  const auto total = Storage.totalBytes(), used = Storage.usedBytes();
  return total > used ? total - used : 0;
}
uint32_t hashReply(const std::string& path, uint32_t hash);
Index& index() {
  if (!s_loaded) {
    s_loaded = true;
    Storage.mkdir(DIR);
    std::string bytes;
    if (!readFile(INDEX_PATH, bytes, MAX_INDEX_BYTES) ||
        !deserializeIndex(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), s_index)) {
      s_index = Index{};
      s_index.owner = currentOwner();
    }
    for (const auto& entry : s_index.entries) {
      const auto path = entryPath(entry.hash);
      Storage.mkdir(path.substr(0, path.find_last_of('/')).c_str());
      char legacy[96];
      snprintf(legacy, sizeof(legacy), "%s/%08lx.json", DIR, static_cast<unsigned long>(entry.hash));
      if (Storage.exists(legacy) && !Storage.exists(path.c_str())) Storage.rename(legacy, path.c_str());
      saveEntry(entry);
      hashReply(path, entry.hash);  // one-time reverse references for the legacy cache
    }
    s_index.entries.clear();
    save();
    std::string usage;
    unsigned long long value = 0, inverse = 0;
    usageKnown = readFile("/.crosspoint/bookorbit-cache/usage", usage, 64) &&
                 sscanf(usage.c_str(), "%llu\n%llu", &value, &inverse) == 2 &&
                 (value ^ inverse) == UINT64_MAX;
    sdBytes = usageKnown ? value : 0;
  }
  if (s_index.owner != currentOwner()) {
    wipe();
    sdBytes = 0;
    saveUsage();
    save();
  }
  return s_index;
}
bool isHome(const std::string& url) { return pathOf(url).find("/catalog/dashboard") != std::string::npos; }

std::string refsPath(int64_t id) {
  char path[112];
  snprintf(path, sizeof(path), "%s/refs/%02x/%lld", DIR, static_cast<unsigned>(id & 255),
           static_cast<long long>(id));
  return path;
}
void rememberBooks(JsonVariantConst value, uint32_t hash) {
  if (value.is<JsonObjectConst>()) {
    const auto object = value.as<JsonObjectConst>();
    const auto id = object["id"].as<int64_t>();
    if (id > 0 && !object["authors"].isUnbound()) {
      const auto path = refsPath(id);
      Storage.mkdir(path.substr(0, path.find_last_of('/')).c_str());
      char row[16];
      snprintf(row, sizeof(row), "%08lx\n", static_cast<unsigned long>(hash));
      bool present = false;
      HalFile existing = Storage.open(path.c_str());
      char line[10]{};
      while (existing && existing.read(line, 9) == 9)
        if (strncmp(line, row, 9) == 0) {
          present = true;
          break;
        }
      existing.close();
      if (!present) {
        HalFile refs = Storage.open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND);
        if (!refs || refs.write(row, 9) != 9 || !refs.sync())
          stopReason = orbify::mirror::Stop::Io;
        else
          sdBytes += 9;
      }
    }
    for (JsonPairConst field : object) rememberBooks(field.value(), hash);
  } else if (value.is<JsonArrayConst>()) {
    for (JsonVariantConst item : value.as<JsonArrayConst>()) rememberBooks(item, hash);
  }
}

// canonicalHash of the reply in `path` (0 when it does not parse).
uint32_t hashReply(const std::string& path, uint32_t hash) {
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
  if (!error) rememberBooks(doc.as<JsonVariantConst>(), hash);
  return error ? 0 : canonicalHash(doc.as<JsonVariantConst>());
}

}  // namespace

ScopedMode::ScopedMode(const Mode mode) {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  if(mode!=Mode::Open)for(auto& stamp:windowStamps)stamp={};
  previous = modeForTask();
  modes[xTaskGetCurrentTaskHandle()] = mode;
}
ScopedMode::~ScopedMode() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (previous == Mode::Open)
    modes.erase(xTaskGetCurrentTaskHandle());
  else
    modes[xTaskGetCurrentTaskHandle()] = previous;
}
Mode currentMode() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  return modeForTask();
}

Lookup lookup(const std::string& url) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Lookup l;
  if (OrbifyBulk::networkFetch()) { l.fetch = true; return l; }
  if (!BOOKORBIT_STORE.hasCredentials() || !isCacheable("GET", pathOf(url))) {
    l.fetch = true;
    return l;
  }
  l.cacheable = true;
  l.bulkGeneration = OrbifyBulk::generation();
  const std::string key = keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", url);
  l.hash = keyHash(key);
  l.path = entryPath(l.hash);
  index();
  IndexEntry entry;
  const IndexEntry* e = loadEntry(l.hash, entry) ? &entry : nullptr;
  l.hasEntry = e != nullptr && Storage.exists(l.path.c_str());
  if (l.hasEntry && !OrbifyBulk::detailCurrent(url,l.path)) l.hasEntry = false;
  if (modeForTask() == Mode::Open && !(l.hasEntry&&OrbifyBulk::wasObserved(url,l.bulkGeneration)) && OrbifyBulk::available(url,l.hasEntry)) {
    l.bulk = true; l.hasEntry = true; l.serve = true; l.fetch = false; l.cacheable = false;
    return l;
  }
  const bool offline = WiFi.status() != WL_CONNECTED;
  const uint32_t now = nowSeconds();
  const ReadPlan plan = planRead(l.hasEntry, l.hasEntry ? e->validatedAt : 0, now, modeForTask(), offline);
  l.serve = plan.serve;
  l.fetch = plan.fetch;
  if (l.hasEntry && modeForTask() == Mode::Open) l.fetch = false;
  // Without a clock the 60 s window can't be measured: online, ask the server.
  if (!l.hasEntry && !offline && now == 0) l.fetch = true;
  return l;
}

bool readWindow(const std::string& url, JsonVariantConst filter, JsonDocument& out) {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  if (modeForTask()!=Mode::Open || !BOOKORBIT_STORE.hasCredentials()) return false;
  index();
  IndexEntry exact;
  const auto account=BOOKORBIT_STORE.getUsername();
  const bool hadExact=loadEntry(keyHash(keyForUrl(account,"GET",url)),exact);
  std::pair<uint32_t,uint32_t> oldest{UINT32_MAX,UINT32_MAX};
  uint32_t validated=UINT32_MAX;bool notUpdated=false;
  JsonDocument window(&psram);
  const bool ok=orbify::catalog::readCachedWindow(url,[&](const std::string& source,JsonDocument& doc) {
    IndexEntry entry;
    if(!loadEntry(keyHash(keyForUrl(account,"GET",source)),entry) ||
       !readDocument(entryPath(entry.hash),doc) || !doc["items"].is<JsonArray>() ||
       (doc["size"]|size_t(100))!=orbify::catalog::FETCH_SIZE) return false;
    oldest=std::min(oldest,std::make_pair(entry.fetchedAt,entry.usedAt));
    validated=std::min(validated,entry.validatedAt?entry.validatedAt:entry.fetchedAt);
    notUpdated|=(entry.flags&FLAG_NOT_UPDATED)!=0;
    return true;
  },window,&psram);
  // A later explicit 20-row refresh wins over an older 100-row source.
  if(!ok || (hadExact && std::make_pair(exact.fetchedAt,exact.usedAt)>=oldest)) return false;
  out.clear();orbify::bulk::project(window.as<JsonVariantConst>(),filter,out.to<JsonVariant>());
  if(!out.overflowed())windowStamps[nextWindowStamp++%3]={keyHash(keyForUrl(account,"GET",url)),{true,validated,notUpdated}};
  OrbifyHeap::logHeap("after saved catalog window");
  return !out.overflowed();
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
  IndexEntry entry;
  const bool hadEntry = loadEntry(l.hash, entry);
  IndexEntry* e = hadEntry ? &entry : nullptr;
  measureUsage();
  stopReason = orbify::mirror::budget(sdBytes + extraBytes(), e ? e->bytes : 0, bytes + 4096ULL,
                                      OrbifySettings::storageBytes(), freeBytes());
  if (stopReason != orbify::mirror::Stop::None) {
    Storage.remove(tmpPath);
    return false;
  }
  const uint32_t replyHash = bytes <= MAX_REPLY_BYTES ? hashReply(tmpPath, l.hash) : 0;
  if (stopReason != orbify::mirror::Stop::None) {
    Storage.remove(tmpPath);
    return false;
  }
  const uint32_t oldBytes = e ? e->bytes : 0;
  const Revalidated r = revalidate(200, e != nullptr, e ? e->replyHash : 0, replyHash);
  Storage.mkdir(l.path.substr(0, l.path.find_last_of('/')).c_str());
  if (!replaceFile(tmpPath, l.path)) {
    LOG_ERR(TAG, "Couldn't keep the reply for %s", url.c_str());
    stopReason = orbify::mirror::Stop::Io;
    return false;
  }
  if (!e) {
    e = &entry;
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
  if (!saveEntry(*e)) {
    stopReason = orbify::mirror::Stop::Io;
    return false;
  }
  sdBytes = sdBytes - std::min<uint64_t>(sdBytes, oldBytes) + bytes;
  saveUsage();
  if(modeForTask()!=Mode::Full)OrbifyBulk::noteObserved(url,l.bulkGeneration);
#ifdef SIMULATOR
  ++repliesSinceClear;
#endif
  if (r.changed) LOG_INF(TAG, "Changed on the server: %s", pathOf(url).c_str());
  return r.changed;
}

void markNotUpdated(const Lookup& l) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  IndexEntry e;
  if (l.cacheable && loadEntry(l.hash, e)) {
    e.flags |= FLAG_NOT_UPDATED;
    saveEntry(e);
  }
}
void markUsed(const Lookup&) {}  // Opening a saved page makes no SD write and never revalidates it.

void afterWrite(const char* method, const std::string& url, const char* body, const size_t bodyLength,
                const int status) {
  if (!BOOKORBIT_STORE.hasCredentials()) return;
  JsonDocument payload;
  if (body && bodyLength) deserializeJson(payload, body, bodyLength);
  const WriteEffect effect = writeEffect(method, pathOf(url), status, payload.as<JsonVariantConst>());
  if (!effect.homeStale && effect.bookId <= 0) return;
  {
    std::lock_guard<std::recursive_mutex> guard(s_lock);
    index();
    if (effect.homeStale) {
      const auto homeUrl = BOOKORBIT_STORE.getBaseUrl() + "/plugin/catalog/dashboard";
      const auto homeHash = keyHash(keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", homeUrl));
      IndexEntry home;
      if (loadEntry(homeHash, home)) {
        home.validatedAt = 0;
        saveEntry(home);
      }
    }
  }
  if (effect.bookId > 0) OrbifyBulk::patch(effect.bookId,effect.fields.as<JsonObjectConst>());
  unsigned patched = 0;
  const auto patch = [&](IndexEntry& e) {
    // A write visits only replies which list this book. Hold the cache mutex for
    // one reply, never for a library scan beside foreground cached navigation.
    std::lock_guard<std::recursive_mutex> guard(s_lock);
    const auto path = entryPath(e.hash);
    JsonDocument doc(&psram);
    if (!readDocument(path, doc) ||
        !patchBook(doc.as<JsonVariant>(), effect.bookId, effect.fields.as<JsonObjectConst>()))
      return;
    if (writeDocument(path, doc)) {
      const auto bytes = measureJson(doc);
      sdBytes = sdBytes - std::min<uint64_t>(sdBytes, e.bytes) + bytes;
      e.bytes = static_cast<uint32_t>(bytes);
      e.replyHash = canonicalHash(doc.as<JsonVariantConst>());
      saveEntry(e);
      ++patched;
    }
  };
  if (effect.bookId > 0) {
    HalFile refs = Storage.open(refsPath(effect.bookId).c_str());
    char row[10]{};
    while (refs && refs.read(row, 9) == 9) {
      IndexEntry entry;
      {
        std::lock_guard<std::recursive_mutex> guard(s_lock);
        if (!loadEntry(static_cast<uint32_t>(strtoul(row, nullptr, 16)), entry)) continue;
      }
      patch(entry);
      delay(1);
    }
  }
  {
    std::lock_guard<std::recursive_mutex> guard(s_lock);
    saveUsage();
  }
  LOG_INF(TAG, "%s %s -> %d: %u saved replies patched%s", method, pathOf(url).c_str(), status, patched,
          effect.homeStale ? ", Home due" : "");
}

Freshness freshness(const std::string& url) {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  Freshness f;
  if (!BOOKORBIT_STORE.hasCredentials()) return f;
  index();
  IndexEntry entry;
  const IndexEntry* e =
      loadEntry(keyHash(keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", url)), entry) ? &entry : nullptr;
  if(OrbifyBulk::available(url,false)&&!(e&&OrbifyBulk::wasObserved(url,OrbifyBulk::generation()))) {
    f.saved=true;f.validatedAt=OrbifyBulk::savedAt();return f;
  }
  const auto hash=keyHash(keyForUrl(BOOKORBIT_STORE.getUsername(),"GET",url));
  for(const auto& stamp:windowStamps)if(stamp.hash==hash&&stamp.value.saved)return stamp.value;
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

std::vector<int64_t> mergeRecent() {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  index();
  JsonDocument recent(&psram);
  orbify::mirror::FacetQuery q;
  q.sort = "recently_updated";
  const auto url = BOOKORBIT_STORE.getBaseUrl() + orbify::mirror::booksPath(q, 1, 20, false);
  const uint32_t hash = keyHash(keyForUrl(BOOKORBIT_STORE.getUsername(), "GET", url));
  readDocument(entryPath(hash), recent);
  const auto items = recent["items"].as<JsonArrayConst>();
  std::vector<int64_t> details;
  unsigned changed = 0;
  // Reverse references are built as each reply lands. Only pages which contain
  // a changed book are opened; the incremental pass never scans/parses the
  // library.
  for (JsonObjectConst book : items) {
    const int64_t id = book["id"] | 0LL;
    if (id <= 0) continue;
    HalFile refs = Storage.open(refsPath(id).c_str());
    char row[10]{};
    while (refs && refs.read(row, 9) == 9) {
      IndexEntry e;
      if (!loadEntry(static_cast<uint32_t>(strtoul(row, nullptr, 16)), e) || e.hash == hash) continue;
      const auto path = entryPath(e.hash);
      JsonDocument doc(&psram);
      if (!readDocument(path, doc)) continue;
      if (doc["id"].as<int64_t>() == id && doc["files"].is<JsonArray>()) {
        if (doc["updatedAt"] != book["updatedAt"] &&
            std::find(details.begin(), details.end(), id) == details.end())
          details.push_back(id);
        continue;  // details are fetched only when their version changed
      }
      if (!mergeRecentBooks(doc.as<JsonVariant>(), items)) continue;
      const auto bytes = measureJson(doc);
      if (orbify::mirror::budget(sdBytes + extraBytes(), e.bytes, bytes + 4096ULL,
                                 OrbifySettings::storageBytes(), freeBytes()) != orbify::mirror::Stop::None)
        continue;
      if (!writeDocument(path, doc)) continue;
      sdBytes = sdBytes - std::min<uint64_t>(sdBytes, e.bytes) + bytes;
      e.bytes = static_cast<uint32_t>(bytes);
      e.replyHash = canonicalHash(doc.as<JsonVariantConst>());
      saveEntry(e);
      ++changed;
    }
  }
  if (changed) saveUsage();
  LOG_INF(TAG,
          "Catalog incremental: %u saved replies changed (one recent-items "
          "page), %u changed details",
          changed, static_cast<unsigned>(details.size()));
  return details;
}

void setPlanBytes(uint64_t bytes) {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  planBytes = bytes;
}
uint64_t bytesOnSd() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  index();
  measureUsage();
  return sdBytes + extraBytes();
}
orbify::mirror::Stop storageStop() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  return stopReason;
}
void setStorageStop(orbify::mirror::Stop reason) {std::lock_guard<std::recursive_mutex> guard(s_lock);stopReason=reason;}
void clearStorageStop() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  stopReason = orbify::mirror::Stop::None;
#ifdef SIMULATOR
  repliesSinceClear = 0;
#endif
}
bool roomForReply() {
  std::lock_guard<std::recursive_mutex> guard(s_lock);
  index();
  measureUsage();
  stopReason =
      orbify::mirror::budget(sdBytes + extraBytes(), 0, 0, OrbifySettings::storageBytes(), freeBytes());
  return stopReason == orbify::mirror::Stop::None;
}

void dropAll() {
  const std::lock_guard<std::recursive_mutex> guard(s_lock);
  s_loaded = true;
  wipe();
  OrbifyBulk::dropAll();
  sdBytes = 0;
  saveUsage();
  save();
}

}  // namespace OrbifyCache

// The hook sendBookOrbitRequest calls (lib/BookOrbitSync, declared weak there).
void orbifyCacheAfterWrite(const char* method, const std::string& url, const char* body,
                           const size_t bodyLength, const int status) {
  OrbifyCache::afterWrite(method, url, body, bodyLength, status);
}

#endif  // CROSSINK_TAILNET_ORBIFY_CACHE
