#include "FinishSync.h"
#include "HeapFloor.h"

#include <CrossInkTailnetCuts.h>

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HalStorage.h>
#include <Logging.h>

#include <cstring>
#include <ctime>
#include <memory>
#include <new>
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
#include <JpegToBmpConverter.h>

#include <string>
#include <vector>

#include "CacheStore.h"
#include "core/EndPageLayout.h"
#include "core/NextCover.h"
#include "network/BookOrbitCatalogClient.h"
#endif

#include "BookOrbitCredentialStore.h"
#include "BookOrbitDownloadIndex.h"
#include "BookOrbitSyncClient.h"
#include "CrossPointSettings.h"
#include "KOReaderDocumentId.h"
#include "activities/reader/BookReadingStats.h"
#include "core/FinishQueue.h"
#include "core/SeriesCard.h"
#include "sync/BookSyncFile.h"

namespace OrbifyFinish {
namespace {

using orbify::FinishJob;
using orbify::FinishQueue;

constexpr char TAG[] = "ORB";
// Two slots (core/FinishQueue.h, slot::): each save overwrites the older one.
constexpr const char* SLOT_PATHS[2] = {"/.crosspoint/orbify_finish.bin", "/.crosspoint/orbify_finish.bak"};
constexpr char REPLY_PATH[] = "/.crosspoint/orbify_reply.json";
constexpr size_t SLOT_BYTES = FinishQueue::MAX_PAYLOAD_BYTES + orbify::slot::TRAILER_BYTES;

// The queue as last read: which slot was newest, and its sequence.
struct Loaded {
  int newest = -1;
  uint32_t seq = 0;
};

size_t readSlot(const char* path, uint8_t* buf) {
  if (!Storage.exists(path)) return 0;
  HalFile file;
  if (!Storage.openFileForRead(TAG, path, file)) return 0;
  const size_t size = file.fileSize();
  const int n = size <= SLOT_BYTES ? file.read(buf, size) : -1;
  file.close();
  return n > 0 && static_cast<size_t>(n) == size ? size : 0;
}

bool load(FinishQueue& queue, Loaded& loaded) {
  std::unique_ptr<uint8_t[]> buf(new (std::nothrow) uint8_t[SLOT_BYTES]);
  if (!buf) return false;
  uint32_t bestSeq = 0;
  int best = -1;
  for (int i = 0; i < 2; i++) {
    uint32_t seq = 0;
    const size_t size = readSlot(SLOT_PATHS[i], buf.get());
    const size_t payload = size ? orbify::slot::decode(buf.get(), size, seq) : 0;
    if (!payload) continue;
    FinishQueue candidate;
    if (!candidate.deserialize(buf.get(), payload)) continue;
    if (best < 0 || seq > bestSeq) {
      best = i;
      bestSeq = seq;
      queue = candidate;
    }
  }
  loaded.newest = best;
  loaded.seq = bestSeq;
  return true;
}

bool save(const FinishQueue& queue, Loaded& loaded) {
  std::unique_ptr<uint8_t[]> buf(new (std::nothrow) uint8_t[SLOT_BYTES]);
  if (!buf) return false;
  const size_t payload = queue.serialize(buf.get(), SLOT_BYTES);
  const size_t size = orbify::slot::encode(buf.get(), payload, loaded.seq + 1, buf.get(), SLOT_BYTES);
  const int target = loaded.newest == 0 ? 1 : 0;
  HalFile file;
  Storage.mkdir("/.crosspoint");
  if (!size || !Storage.openFileForWrite(TAG, SLOT_PATHS[target], file)) return false;
  const bool ok = file.write(buf.get(), size) == size;
  file.sync();
  file.close();
  if (ok) {
    loaded.newest = target;
    loaded.seq++;
  } else {
    LOG_ERR(TAG, "Finish queue not saved (%s)", SLOT_PATHS[target]);
  }
  return ok;
}

bool isEpub(const std::string& path) {
  const size_t n = path.size();
  return n > 5 && strcasecmp(path.c_str() + n - 5, ".epub") == 0;
}

// Parses the saved reply through an ArduinoJson filter.
bool parseReply(JsonDocument& filter, JsonDocument& doc, size_t* outBytes = nullptr) {
  HalFile file;
  if (!Storage.openFileForRead(TAG, REPLY_PATH, file)) return false;
  if (outBytes) *outBytes = file.fileSize();
  struct Reader {
    HalFile& f;
    int read() { return f.read(); }
    size_t readBytes(char* b, size_t n) {
      const int r = f.read(b, n);
      return r > 0 ? static_cast<size_t>(r) : 0;
    }
  } reader{file};
  const bool ok = !deserializeJson(doc, reader, DeserializationOption::Filter(filter));
  file.close();
  return ok;
}

uint32_t nowEpoch() {
  const time_t now = time(nullptr);
  return now >= static_cast<time_t>(orbify::MIN_PLAUSIBLE_EPOCH) ? static_cast<uint32_t>(now) : 0;
}

// --- the transport over BookOrbitSyncClient ---------------------------------------

int matchCheckCode() {
  const int http = BookOrbitSyncClient::lastHttpCode;
  return http > 0 ? http : -1;
}

class SyncTransport : public orbify::FinishTransport {
 public:
  int bookStates(const FinishJob& job, const bool withStatus, const bool withRating) override {
    std::string body;
    {
      JsonDocument doc;
      doc["deviceId"] = BookOrbitSyncClient::deviceId();
      doc["deviceModel"] = SETTINGS.getEffectiveDeviceName();
      doc["pluginVersion"] = "crossink-bo-1";
      JsonObject book = doc["books"].add<JsonObject>();
      book["hash"] = job.hash;
      if (withStatus) book["status"] = "complete";
      char day[11];
      if (job.finishedOn && orbify::formatDay(job.finishedOn, day)) book["statusModified"] = day;
      if (withRating && job.rating > 0) book["rating"] = job.rating;
      if (withRating && job.rating < 0) book["ratingCleared"] = true;
      serializeJson(doc, body);
    }
    return BookOrbitSyncClient::orbifyRequest("POST", "/plugin/book-states", body.c_str(), nullptr);
  }

  int matchCheck(const char* hash, int64_t& outBookId) override {
    outBookId = 0;
    const BookOrbitSyncClient::MatchQuery query{hash, nullptr, nullptr};
    char libraryVersion[BookOrbitSyncClient::LIBRARY_VERSION_SIZE] = {};
    const auto result = BookOrbitSyncClient::matchCheck(
        SETTINGS.getEffectiveDeviceName(), &query, 1,
        [](const char*, const int64_t bookId, int64_t, void* context) { *static_cast<int64_t*>(context) = bookId; },
        &outBookId, libraryVersion);
    return result == BookOrbitSyncClient::OK ? 200 : matchCheckCode();
  }

  int readStatus(const int64_t bookId, orbify::ServerStatus& outStatus) override {
    outStatus = orbify::ServerStatus::Unknown;
    const std::string path = "/plugin/catalog/books/" + std::to_string(bookId) +
                             "?deviceId=" + BookOrbitSyncClient::deviceId();
    const int code = BookOrbitSyncClient::orbifyRequest("GET", path, nullptr, REPLY_PATH);
    if (code >= 200 && code < 300) {
      JsonDocument filter;
      filter["readStatus"] = true;
      JsonDocument doc;
      if (parseReply(filter, doc)) outStatus = orbify::parseServerStatus(doc["readStatus"].as<const char*>());
    }
    Storage.remove(REPLY_PATH);
    return code;
  }

  int setRead(const int64_t bookId) override {
    return BookOrbitSyncClient::orbifyRequest("PUT", "/plugin/catalog/books/" + std::to_string(bookId) + "/read-status",
                                              R"({"status":"read"})", nullptr);
  }

  int setRating(const int64_t bookId, const int8_t rating) override {
    char body[24];
    if (rating > 0) {
      snprintf(body, sizeof(body), "{\"rating\":%d}", rating);
    } else {
      snprintf(body, sizeof(body), "{\"rating\":null}");
    }
    return BookOrbitSyncClient::orbifyRequest("PUT", "/plugin/catalog/books/" + std::to_string(bookId) + "/rating",
                                              body, nullptr);
  }
};

bool s_lastAtEnd = false;

// --- the series card (item 2) ------------------------------------------------------------

constexpr char CARD_DIR[] = "/.crosspoint/orbify_series";

std::string cardPath(const int64_t bookId) { return std::string(CARD_DIR) + "/" + std::to_string(bookId) + ".bin"; }

bool loadCardById(const int64_t bookId, orbify::SeriesCard& out) {
  if (bookId <= 0) return false;
  const std::string path = cardPath(bookId);
  if (!Storage.exists(path.c_str())) return false;
  std::unique_ptr<uint8_t[]> buf(new (std::nothrow) uint8_t[orbify::CARD_BYTES]);
  if (!buf) return false;
  HalFile file;
  if (!Storage.openFileForRead(TAG, path.c_str(), file)) return false;
  const int n = file.read(buf.get(), orbify::CARD_BYTES);
  file.close();
  // A card written before version 3 is the shorter record (core/SeriesCard legacyCardBytes).
  return n > 0 && orbify::deserializeCard(buf.get(), static_cast<size_t>(n), out);
}

// Bumped by every card written this boot: an open End-of-Book page reloads when it moves.
uint32_t s_cardGeneration = 0;

int64_t bookIdOf(const std::string& bookPath) {
  int64_t bookId = 0;
  if (!BookOrbitDownloadIndex::bookIdForPath(bookPath, bookId)) bookId = 0;
  BookOrbitDownloadIndex::unload();
  return bookId;
}

bool writeCard(const orbify::SeriesCard& card) {
  std::unique_ptr<uint8_t[]> buf(new (std::nothrow) uint8_t[orbify::CARD_BYTES]);
  if (!buf) return false;
  const size_t size = orbify::serializeCard(card, buf.get(), orbify::CARD_BYTES);
  Storage.mkdir("/.crosspoint");
  Storage.mkdir(CARD_DIR);
  const std::string path = cardPath(card.bookId);
  HalFile file;
  if (!size || !Storage.openFileForWrite(TAG, path.c_str(), file)) return false;
  const bool ok = file.write(buf.get(), size) == size;
  file.close();
  if (!ok) Storage.remove(path.c_str());
  return ok;
}

#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
#if !CROSSINK_TAILNET_ORBIFY_CACHE
#error "CROSSINK_TAILNET_ORBIFY_EOB_COVER keeps its ETags in the cache (CROSSINK_TAILNET_ORBIFY_CACHE)"
#endif
// --- the next book's cover ------------------------------------------------------------------

namespace cover = orbify::cover;
// The Home store's limits for a cover transfer and for the JPEG decoder (BookOrbitHomeStore.cpp).
#if CROSSINK_TAILNET_TLS_PSRAM
constexpr uint32_t MIN_FREE_HEAP_FOR_COVER = 20 * 1024;  // wolfSSL in PSRAM (HeapFloor.h)
#else
constexpr uint32_t MIN_FREE_HEAP_FOR_COVER = 42 * 1024;
#endif
#if CROSSINK_TAILNET_TLS_PSRAM
constexpr uint32_t MIN_MAX_ALLOC_FOR_COVER = 4 * 1024;  // all of wolfSSL in PSRAM
#else
constexpr uint32_t MIN_MAX_ALLOC_FOR_COVER = 20 * 1024;
#endif
constexpr uint32_t MIN_MAX_ALLOC_FOR_DECODE = 54 * 1024;

// What storeCard last found for the next book; refreshCard asks that book itself when no section
// listed it.
int64_t s_nextId = 0;
cover::Lookup s_nextLookup = cover::Lookup::NotListed;
bool s_coverPending = false;

bool coverBmp(const int64_t bookId, const uint32_t version, char* out, const size_t size) {
  return cover::bmpPath(cover::DIR, bookId, version, orbify::eob::COVER_WIDTH, orbify::eob::COVER_HEIGHT, out, size);
}

// The cover files in a directory, by name (listed first: nothing is removed while it is open).
template <typename Visit>
void forEachCoverFile(const char* dirPath, Visit visit) {
  HalFile dir = Storage.open(dirPath);
  if (!dir || !dir.isDirectory()) return;
  std::vector<std::string> names;
  char name[48];
  HalFile entry;
  cover::Name parsed;
  while ((entry = dir.openNextFile())) {
    const size_t length = entry.getName(name, sizeof(name));
    entry.close();
    if (length > 0 && cover::parseName(name, parsed)) names.emplace_back(name);
  }
  dir.close();
  for (const std::string& n : names) {
    if (cover::parseName(n.c_str(), parsed)) visit(std::string(dirPath) + "/" + n, parsed);
  }
}

// Removes this book's cover files: all of them (version 0), or those stale at this version.
void removeCovers(const int64_t bookId, const uint32_t version) {
  forEachCoverFile(cover::DIR, [&](const std::string& path, const cover::Name& n) {
    if (n.bookId != bookId) return;
    if (version && !cover::isStale(n, bookId, version, orbify::eob::COVER_WIDTH, orbify::eob::COVER_HEIGHT)) return;
    if (Storage.remove(path.c_str())) LOG_INF(TAG, "Next cover: removed %s", path.c_str());
  });
}

// A BMP the Home store keeps of this book at this version, the largest one.
bool homeBmp(const int64_t bookId, const uint32_t version, std::string& out) {
  int best = 0;
  forEachCoverFile(cover::HOME_DIR, [&](const std::string& path, const cover::Name& n) {
    if (n.jpg || n.bookId != bookId || n.version != version || n.width <= best) return;
    best = n.width;
    out = path;
  });
  return best > 0;
}

bool copyFile(const std::string& from, const char* to) {
  HalFile in;
  HalFile out;
  if (!Storage.openFileForRead(TAG, from.c_str(), in)) return false;
  bool ok = Storage.openFileForWrite(TAG, to, out);
  uint8_t buf[512];
  while (ok) {
    const int n = in.read(buf, sizeof(buf));
    if (n <= 0) break;
    ok = out.write(buf, static_cast<size_t>(n)) == static_cast<size_t>(n);
  }
  if (out) out.close();
  in.close();
  if (!ok) Storage.remove(to);
  return ok;
}

// The next book's own detail: its hasCover and updatedAt, for a card whose sections did not list it.
void refreshNextCoverVersion(const int64_t bookId, const int64_t nextId) {
  const std::string path = "/plugin/catalog/books/" + std::to_string(nextId) + "?deviceId=" + BookOrbitSyncClient::deviceId();
  const int code = BookOrbitSyncClient::orbifyRequest("GET", path.c_str(), nullptr, REPLY_PATH);
  uint32_t version = 0;
  cover::Lookup lookup = cover::Lookup::NotListed;
  if (code >= 200 && code < 300) {
    JsonDocument filter;
    filter["id"] = true;
    filter["hasCover"] = true;
    filter["updatedAt"] = true;
    JsonDocument doc;
    if (parseReply(filter, doc)) lookup = cover::versionOf(doc.as<JsonObjectConst>(), version);
  }
  Storage.remove(REPLY_PATH);
  std::unique_ptr<orbify::SeriesCard> card(new (std::nothrow) orbify::SeriesCard());
  if (lookup == cover::Lookup::NotListed || !card || !loadCardById(bookId, *card) || card->nextBook.id != nextId) {
    LOG_INF(TAG, "Next cover: book %lld not looked up (http %d)", static_cast<long long>(nextId), code);
    return;
  }
  card->nextBook.coverVer = version;
  if (writeCard(*card)) {
    LOG_INF(TAG, "Next cover: book %lld version %08lx (its own detail)", static_cast<long long>(nextId),
            static_cast<unsigned long>(version));
  }
}
#endif

// Loads the queue, applies change to this book's job, saves when change returns true.
template <typename Change>
bool withJob(const std::string& bookPath, Change change) {
  if (!isEpub(bookPath) || (!Storage.exists(SLOT_PATHS[0]) && !Storage.exists(SLOT_PATHS[1]))) return false;
  const std::string hash = KOReaderDocumentId::calculate(bookPath);
  if (hash.size() != 32) return false;
  std::unique_ptr<FinishQueue> queue(new (std::nothrow) FinishQueue());
  if (!queue) return false;
  Loaded loaded;
  if (!load(*queue, loaded)) return false;
  FinishJob* job = queue->find(hash.c_str());
  if (!job) return false;
  if (change(*job)) save(*queue, loaded);
  return true;
}

}  // namespace

bool autoMarkEnabled() { return BOOKORBIT_STORE.getOrbifyMarkAtEnd(); }

bool reachedEnd(const bool atEndOfBook) {
  const bool edge = atEndOfBook && !s_lastAtEnd;
  s_lastAtEnd = atEndOfBook;
  return edge;
}

void onFinishedChanged(const std::string& bookPath, const bool finished) {
  if (!isEpub(bookPath) || !BOOKORBIT_STORE.hasCredentials()) return;
  const std::string hash = KOReaderDocumentId::calculate(bookPath);
  if (hash.size() != 32) {
    LOG_ERR(TAG, "Finish: no document hash for %s", bookPath.c_str());
    return;
  }
  std::unique_ptr<FinishQueue> queue(new (std::nothrow) FinishQueue());
  if (!queue) return;
  Loaded loaded;
  if (!load(*queue, loaded)) return;

  if (!finished) {
    // Undo, or marked unfinished: the newest local intent wins. A job already sent stays
    // sent on the server (S9); only the local hold is released.
    if (queue->remove(hash.c_str())) {
      save(*queue, loaded);
      LOG_INF(TAG, "Finish: %s unmarked, job removed", hash.c_str());
    }
    return;
  }

  FinishJob job;
  memcpy(job.hash, hash.c_str(), 32);
  int64_t bookId = 0;
  if (BookOrbitDownloadIndex::bookIdForPath(bookPath, bookId)) job.bookId = bookId;
  BookOrbitDownloadIndex::unload();
  const std::string cachePath = BookSyncFile::cachePathFor(bookPath);
  if (!cachePath.empty()) {
    const BookReadingStats stats = BookReadingStats::load(cachePath);
    if (stats.finishedDate.isValid()) {
      job.finishedOn = stats.finishedDate.year * 10000u + stats.finishedDate.month * 100u + stats.finishedDate.day;
    }
    job.pagesAtFinish = stats.totalPagesTurned;
  }
  // The server's status when the book was finished (G4), from the card when there is one.
  orbify::SeriesCard card;
  if (loadCardById(job.bookId, card)) job.statusSeen = card.status;
  job.createdAt = nowEpoch();
  job.finalPermille = 1000;
  queue->upsert(job);
  if (save(*queue, loaded)) {
    LOG_INF(TAG, "Finish: %s queued (book %lld, day %u, %u pending)", hash.c_str(), static_cast<long long>(job.bookId),
            static_cast<unsigned>(job.finishedOn), static_cast<unsigned>(queue->pending()));
  }
}

void drain(const std::string& knownHash, const bool manual, bool (*stop)()) {
  if (!BOOKORBIT_STORE.hasCredentials()) return;
  if (!Storage.exists(SLOT_PATHS[0]) && !Storage.exists(SLOT_PATHS[1])) return;
  std::unique_ptr<FinishQueue> queue(new (std::nothrow) FinishQueue());
  if (!queue) return;
  Loaded loaded;
  if (!load(*queue, loaded) || queue->pending() == 0) return;

  orbify::DrainOptions options;
  options.now = nowEpoch();
  options.manual = manual;
  options.knownHash = knownHash.c_str();
  options.sendRatings = CROSSINK_TAILNET_ORBIFY_RATING != 0;
  SyncTransport transport;
  bool changed = false;
  for (size_t i = 0; i < queue->size(); i++) {
    if (stop && stop()) break;
    FinishJob& job = queue->at(i);
    const orbify::DrainOutcome outcome = orbify::drainOne(job, transport, options);
    if (outcome == orbify::DrainOutcome::NotDue) continue;
    changed = true;
    LOG_INF(TAG, "Finish drain %s: %s (http %d, attempts %u)", job.hash, orbify::drainOutcomeName(outcome),
            BookOrbitSyncClient::lastHttpCode, static_cast<unsigned>(job.attempts));
    if (outcome == orbify::DrainOutcome::Dropped) {
      queue->remove(job.hash);
      i--;
    }
  }
  if (changed) save(*queue, loaded);
}

bool holdPush(const std::string& bookPath, const std::string& hash, const float percentage) {
  if (hash.size() != 32 || (!Storage.exists(SLOT_PATHS[0]) && !Storage.exists(SLOT_PATHS[1]))) return false;
  std::unique_ptr<FinishQueue> queue(new (std::nothrow) FinishQueue());
  if (!queue) return false;
  Loaded loaded;
  if (!load(*queue, loaded)) return false;
  const FinishJob* job = queue->find(hash.c_str());
  if (!job) return false;
  const std::string cachePath = BookSyncFile::cachePathFor(bookPath);
  const BookReadingStats stats = cachePath.empty() ? BookReadingStats{} : BookReadingStats::load(cachePath);
  const float clamped = percentage < 0 ? 0 : (percentage > 1 ? 1 : percentage);
  const bool hold = orbify::holdAutomaticPush(job, stats.isCompleted, static_cast<uint16_t>(clamped * 1000 + 0.5f),
                                              stats.totalPagesTurned);
  if (hold) {
    LOG_INF(TAG, "Finish hold: %s at %.1f%% not pushed (finished here, %u pages since)", hash.c_str(),
            percentage * 100.0f, static_cast<unsigned>(stats.totalPagesTurned - job->pagesAtFinish));
  }
  return hold;
}

JobState jobState(const std::string& bookPath) {
  JobState state = JobState::None;
  withJob(bookPath, [&](FinishJob& job) {
    state = (job.flags & FinishJob::AUTH_WAIT) ? JobState::SignIn : job.sent() ? JobState::Sent : JobState::Pending;
    return false;
  });
  return state;
}

int8_t rating(const std::string& bookPath) {
  int8_t value = 0;
  withJob(bookPath, [&](FinishJob& job) {
    value = job.rating > 0 ? job.rating : 0;
    return false;
  });
  return value;
}

void setRating(const std::string& bookPath, const int8_t value) {
  withJob(bookPath, [&](FinishJob& job) {
    const int8_t next = value > 0 ? value : (job.rating > 0 ? -1 : 0);
    if (next == job.rating) return false;
    job.rating = next;
    // Sent again at the next sync, rating included; the status steps are no-ops by then.
    job.flags &= static_cast<uint8_t>(~(FinishJob::SENT | FinishJob::PARKED));
    job.attempts = 0;
    job.nextTryAt = 0;
    LOG_INF(TAG, "Finish: %s rated %d", job.hash, static_cast<int>(next));
    return true;
  });
}

bool loadCard(const std::string& bookPath, orbify::SeriesCard& out) { return loadCardById(bookIdOf(bookPath), out); }

uint32_t cardGeneration() { return s_cardGeneration; }

bool hasCard(const std::string& bookPath) {
  const int64_t bookId = bookIdOf(bookPath);
  return bookId > 0 && Storage.exists(cardPath(bookId).c_str());
}

namespace {
// coverFields: the detail was read with cover::addToFilter (a sync's refresh); the catalog's download
// reads it without, and keeps the cover version an earlier sync found.
void storeCardFrom(JsonObjectConst detail, const bool coverFields) {
  std::unique_ptr<orbify::SeriesCard> card(new (std::nothrow) orbify::SeriesCard());
  if (!card || !orbify::pickCard(detail, CROSSINK_TAILNET_ORBIFY_SUGGESTIONS, *card)) return;
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
  s_nextId = 0;
  s_nextLookup = cover::Lookup::NotListed;
  std::unique_ptr<orbify::SeriesCard> old(new (std::nothrow) orbify::SeriesCard());
  const bool hadOld = old && loadCardById(card->bookId, *old);
  const bool hasNext = card->next == orbify::SeriesCard::Next::Next || card->next == orbify::SeriesCard::Next::LastUnread;
  if (hasNext) {
    s_nextId = card->nextBook.id;
    uint32_t version = 0;
    if (coverFields) s_nextLookup = cover::versionIn(detail, s_nextId, version);
    if (s_nextLookup == cover::Lookup::NotListed && hadOld && old->nextBook.id == s_nextId) version = old->nextBook.coverVer;
    card->nextBook.coverVer = version;
  }
  // The next book changed (it was read, or the series grew): the old one's cover goes.
  if (hadOld && old->nextBook.id > 0 && old->nextBook.id != s_nextId) removeCovers(old->nextBook.id, 0);
#else
  (void)coverFields;
#endif
  if (!writeCard(*card)) return;
  s_cardGeneration++;
  // seriesCount is how many of the series' books the library holds, not the series' length.
  if (card->seriesName[0]) {
    LOG_INF(TAG, "Series card %lld: next %d (book %lld), %u suggestions; series '%s' #%s (%u of its books in the library)",
            static_cast<long long>(card->bookId), static_cast<int>(card->next),
            static_cast<long long>(card->nextBook.id), static_cast<unsigned>(card->suggestionCount), card->seriesName,
            card->seriesIndex[0] ? card->seriesIndex : "-", static_cast<unsigned>(card->seriesCount));
  } else {
    LOG_INF(TAG, "Series card %lld: next %d (book %lld), %u suggestions; no series", static_cast<long long>(card->bookId),
            static_cast<int>(card->next), static_cast<long long>(card->nextBook.id),
            static_cast<unsigned>(card->suggestionCount));
  }
}
}  // namespace

void storeCard(JsonObjectConst detail) { storeCardFrom(detail, false); }

void refreshCard(const std::string& bookPath, const float percentage) {
  if (!isEpub(bookPath) || !BOOKORBIT_STORE.hasCredentials()) return;
  const int64_t bookId = bookIdOf(bookPath);
  if (bookId <= 0) return;
  // The card matters at the end: refreshed from 90% on, or when the book has none yet.
  if (percentage < 0.9f && Storage.exists(cardPath(bookId).c_str())) return;
  const std::string path = "/plugin/catalog/books/" + std::to_string(bookId) + "?deviceId=" + BookOrbitSyncClient::deviceId();
  const int code = BookOrbitSyncClient::orbifyRequest("GET", path.c_str(), nullptr, REPLY_PATH);
  if (code >= 200 && code < 300) {
    // Device measurement (X3 heap while parsing the saved detail): these two lines.
    LOG_INF(TAG, "Series card parse: heap free %u, largest %u", static_cast<unsigned>(ESP.getFreeHeap()),
            static_cast<unsigned>(ESP.getMaxAllocHeap()));
    bool parsed = false;
    {
      JsonDocument filter;
      orbify::cardFilter(filter);
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
      cover::addToFilter(filter);
#endif
      // Keep JSON nodes in PSRAM on the X4s, beside a fragmented internal heap (.167 parsed
      // it at 21 KB free, 7 KB largest).
      JsonDocument doc(OrbifyHeap::jsonAllocator());
      size_t replyBytes = 0;
      parsed = parseReply(filter, doc, &replyBytes);
      LOG_INF(TAG, "Series card parsed (%s): %u-byte reply, heap free %u, largest %u", parsed ? "ok" : "failed",
              static_cast<unsigned>(replyBytes), static_cast<unsigned>(ESP.getFreeHeap()),
              static_cast<unsigned>(ESP.getMaxAllocHeap()));
      if (parsed) storeCardFrom(doc.as<JsonObjectConst>(), true);
    }
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
    // The series section lists only the first 8 other books: past them, the next book says itself.
    if (parsed && s_nextId > 0 && s_nextLookup == cover::Lookup::NotListed) refreshNextCoverVersion(bookId, s_nextId);
#endif
  } else {
    LOG_INF(TAG, "Series card %lld not refreshed (http %d)", static_cast<long long>(bookId), code);
  }
  Storage.remove(REPLY_PATH);
}

#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
void fetchNextCover(const std::string& bookPath, bool (*stop)()) {
  if (!isEpub(bookPath) || !BOOKORBIT_STORE.hasCredentials()) return;
  std::unique_ptr<orbify::SeriesCard> card(new (std::nothrow) orbify::SeriesCard());
  if (!card || !loadCard(bookPath, *card)) return;
  if (card->next != orbify::SeriesCard::Next::Next && card->next != orbify::SeriesCard::Next::LastUnread) return;
  const int64_t id = card->nextBook.id;
  const uint32_t version = card->nextBook.coverVer;
  if (id <= 0 || version == 0) return;  // no cover known: the page's row stays as without covers

  char bmp[96];
  char jpg[96];
  if (!coverBmp(id, version, bmp, sizeof(bmp)) || !cover::jpgPath(id, version, jpg, sizeof(jpg))) return;
  cover::Disk disk;
  disk.bmp = Storage.exists(bmp);
  disk.pending = Storage.exists(jpg);
  std::string home;
  disk.homeBmp = !disk.bmp && !disk.pending && homeBmp(id, version, home);
  orbify::cache::CoverRecord kept;
  char keptPath[96] = {};
  if (OrbifyCache::coverRecord(static_cast<int32_t>(id), kept) && kept.version != version &&
      coverBmp(id, kept.version, keptPath, sizeof(keptPath))) {
    disk.kept = Storage.exists(keptPath);
    disk.keptVersion = kept.version;
    disk.hasEtag = !kept.etag.empty();
  }
  const cover::Step step = cover::plan(version, disk);
  if (step == cover::Step::CopyHome) {
    Storage.mkdir(cover::DIR);
    const bool copied = copyFile(home, bmp);
    LOG_INF(TAG, "Next cover: book %lld %s Home's %s", static_cast<long long>(id), copied ? "copied" : "could not copy",
            home.c_str());
  } else if (step == cover::Step::Download || step == cover::Step::Conditional) {
    if (stop && stop()) return;
    // On a connection already open (the sleep sync lends its own), only room beside it;
    // a new connection takes the Home store's floor.
    if (BookOrbitCatalogClient::keptConnection() != nullptr) {
      if (!OrbifyHeap::roomForRequest("Next cover")) return;
    } else if (ESP.getFreeHeap() < MIN_FREE_HEAP_FOR_COVER || ESP.getMaxAllocHeap() < MIN_MAX_ALLOC_FOR_COVER) {
      LOG_INF(TAG, "Next cover: left for the next sync (free=%u maxAlloc=%u)", ESP.getFreeHeap(), ESP.getMaxAllocHeap());
      return;
    }
    Storage.mkdir(cover::DIR);
    std::string etag;
    const auto result = BookOrbitCatalogClient::downloadThumbnail(
        id, jpg, stop, step == cover::Step::Conditional ? kept.etag : std::string(), &etag);
    switch (cover::afterFetch(result == HttpDownloader::OK, HttpDownloader::lastHttpStatus, step)) {
      case cover::After::RenameKept:
        Storage.rename(keptPath, bmp);
        OrbifyCache::coverStored(static_cast<int32_t>(id), version, kept.etag);
        LOG_INF(TAG, "Next cover: book %lld unchanged (304)", static_cast<long long>(id));
        break;
      case cover::After::Decode:
        OrbifyCache::coverStored(static_cast<int32_t>(id), version, etag);
        s_coverPending = true;
        LOG_INF(TAG, "Next cover: book %lld fetched, decodes with the radio off", static_cast<long long>(id));
        break;
      case cover::After::Drop:
        Storage.remove(jpg);
        LOG_ERR(TAG, "Next cover: book %lld not fetched (err=%d, http=%d)", static_cast<long long>(id),
                static_cast<int>(result), HttpDownloader::lastHttpStatus);
        return;
    }
  }
  removeCovers(id, version);
}

void decodeNextCovers(bool (*stop)()) {
  forEachCoverFile(cover::DIR, [&](const std::string& path, const cover::Name& n) {
    if (!n.jpg || (stop && stop())) return;
    if (ESP.getMaxAllocHeap() < MIN_MAX_ALLOC_FOR_DECODE) {
      LOG_INF(TAG, "Next cover: decode waits for more heap (maxAlloc=%u)", ESP.getMaxAllocHeap());
      return;
    }
    char bmp[96];
    if (!coverBmp(n.bookId, n.version, bmp, sizeof(bmp))) return;
    HalFile jpeg;
    HalFile out;
    bool decoded = false;
    if (Storage.openFileForRead(TAG, path.c_str(), jpeg)) {
      if (Storage.openFileForWrite(TAG, bmp, out)) {
        decoded = JpegToBmpConverter::jpegFileTo1BitBmpStreamWithSize(jpeg, out, orbify::eob::COVER_WIDTH,
                                                                      orbify::eob::COVER_HEIGHT, true);
        out.close();
      }
      jpeg.close();
    }
    // With the heap it asked for, a failed decode is a bad file: the next sync fetches it again.
    if (!decoded) Storage.remove(bmp);
    Storage.remove(path.c_str());
    LOG_INF(TAG, "Next cover: book %lld %s", static_cast<long long>(n.bookId), decoded ? "decoded" : "dropped (bad JPEG)");
  });
  s_coverPending = false;
}

bool nextCoverPending() { return s_coverPending; }
#endif

}  // namespace OrbifyFinish
