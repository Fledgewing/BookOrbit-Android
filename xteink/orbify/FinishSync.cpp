#include "FinishSync.h"

#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_FINISH
#include <Arduino.h>
#include <ArduinoJson.h>
#include <HalStorage.h>
#include <Logging.h>

#include <cstring>
#include <ctime>
#include <memory>
#include <new>

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
  return n == static_cast<int>(orbify::CARD_BYTES) && orbify::deserializeCard(buf.get(), orbify::CARD_BYTES, out);
}

int64_t bookIdOf(const std::string& bookPath) {
  int64_t bookId = 0;
  if (!BookOrbitDownloadIndex::bookIdForPath(bookPath, bookId)) bookId = 0;
  BookOrbitDownloadIndex::unload();
  return bookId;
}

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

void storeCard(JsonObjectConst detail) {
  std::unique_ptr<orbify::SeriesCard> card(new (std::nothrow) orbify::SeriesCard());
  std::unique_ptr<uint8_t[]> buf(new (std::nothrow) uint8_t[orbify::CARD_BYTES]);
  if (!card || !buf || !orbify::pickCard(detail, CROSSINK_TAILNET_ORBIFY_SUGGESTIONS, *card)) return;
  const size_t size = orbify::serializeCard(*card, buf.get(), orbify::CARD_BYTES);
  Storage.mkdir("/.crosspoint");
  Storage.mkdir(CARD_DIR);
  const std::string path = cardPath(card->bookId);
  HalFile file;
  if (!size || !Storage.openFileForWrite(TAG, path.c_str(), file)) return;
  const bool ok = file.write(buf.get(), size) == size;
  file.close();
  if (!ok) {
    Storage.remove(path.c_str());
    return;
  }
  LOG_INF(TAG, "Series card %lld: next %d (book %lld), %u suggestions", static_cast<long long>(card->bookId),
          static_cast<int>(card->next), static_cast<long long>(card->nextBook.id),
          static_cast<unsigned>(card->suggestionCount));
}

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
    JsonDocument filter;
    orbify::cardFilter(filter);
    JsonDocument doc;
    size_t replyBytes = 0;
    const bool parsed = parseReply(filter, doc, &replyBytes);
    LOG_INF(TAG, "Series card parsed (%s): %u-byte reply, heap free %u, largest %u", parsed ? "ok" : "failed",
            static_cast<unsigned>(replyBytes), static_cast<unsigned>(ESP.getFreeHeap()),
            static_cast<unsigned>(ESP.getMaxAllocHeap()));
    if (parsed) storeCard(doc.as<JsonObjectConst>());
  } else {
    LOG_INF(TAG, "Series card %lld not refreshed (http %d)", static_cast<long long>(bookId), code);
  }
  Storage.remove(REPLY_PATH);
}

}  // namespace OrbifyFinish

#else

namespace OrbifyFinish {
bool autoMarkEnabled() { return false; }
bool reachedEnd(bool) { return false; }
void onFinishedChanged(const std::string&, bool) {}
void drain(const std::string&, bool, bool (*)()) {}
bool holdPush(const std::string&, const std::string&, float) { return false; }
JobState jobState(const std::string&) { return JobState::None; }
int8_t rating(const std::string&) { return 0; }
void setRating(const std::string&, int8_t) {}
bool loadCard(const std::string&, orbify::SeriesCard&) { return false; }
void storeCard(JsonObjectConst) {}
void refreshCard(const std::string&, float) {}
}  // namespace OrbifyFinish

#endif
