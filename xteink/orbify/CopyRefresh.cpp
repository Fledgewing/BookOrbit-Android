#include "CopyRefresh.h"

#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_COPY_REFRESH

#include <Arduino.h>
#include <HalStorage.h>
#include <LibraryBuilder.h>
#include <Logging.h>
#include <ZipFile.h>

#include <cstring>
#include <memory>
#include <new>

#include "BookOrbitCredentialStore.h"
#include "BookOrbitDownloadIndex.h"
#include "BookOrbitSyncClient.h"
#include "CrossPointSettings.h"
#include "RecentBooksStore.h"
#include "HeapFloor.h"
#include "KOReaderDocumentId.h"
#include "core/CopyQueue.h"
#include "network/BookOrbitCatalogClient.h"
#include "activities/home/RecentBookProgress.h"
#include "network/HttpDownloader.h"
#include "util/BookContentId.h"
#include "util/BookUpdateMigration.h"

namespace {

const char* const TAG = "ORB";
const char* const DIR = "/.crosspoint/orbify";
const char* const QUEUE_PATH = "/.crosspoint/orbify/copy-refresh.tsv";
const char* const QUEUE_TMP = "/.crosspoint/orbify/copy-refresh.tmp";
const char* const TOKEN_PATH = "/.crosspoint/orbify/copy-refresh.token";
constexpr size_t BATCH = 20;
constexpr size_t MAX_FILE = 64 * 1024;
// A download on a new connection needs a TLS session beside the book's buffers: the sync's own
// block (24 KB on the X3; 8 KB on the X4s, whose TLS buffers live in PSRAM).
constexpr uint32_t DOWNLOAD_MIN_BLOCK = CROSSINK_TAILNET_SYNC_TLS_BLOCK ? CROSSINK_TAILNET_SYNC_TLS_BLOCK : 24576;

std::string readText(const char* path) {
  std::string out;
  if (!Storage.exists(path)) return out;
  HalFile file;
  if (!Storage.openFileForRead(TAG, path, file)) return out;
  const size_t size = file.fileSize();
  if (size > 0 && size <= MAX_FILE) {
    out.resize(size);
    if (file.read(reinterpret_cast<uint8_t*>(&out[0]), size) != static_cast<int>(size)) out.clear();
  }
  file.close();
  return out;
}

bool writeText(const char* path, const std::string& text) {
  HalFile file;
  if (!Storage.openFileForWrite(TAG, path, file)) return false;
  const bool ok = file.write(reinterpret_cast<const uint8_t*>(text.data()), text.size()) == text.size();
  file.sync();
  file.close();
  return ok;
}

bool load(orbify::refresh::Queue& queue) {
  // A reset between the write and the rename leaves only the temporary file.
  if (!Storage.exists(QUEUE_PATH) && Storage.exists(QUEUE_TMP)) Storage.rename(QUEUE_TMP, QUEUE_PATH);
  return queue.parse(readText(QUEUE_PATH));
}

bool save(const orbify::refresh::Queue& queue) {
  Storage.mkdir("/.crosspoint");
  Storage.mkdir(DIR);
  if (!writeText(QUEUE_TMP, queue.serialize())) {
    LOG_ERR(TAG, "Copy refresh: queue not saved");
    return false;
  }
  Storage.remove(QUEUE_PATH);
  return Storage.rename(QUEUE_TMP, QUEUE_PATH);
}

// One match-check batch: the catalog downloads hashed so far.
struct Scan {
  orbify::refresh::Queue* queue = nullptr;
  bool (*cancelled)() = nullptr;
  BookOrbitSyncClient::MatchQuery queries[BATCH];
  char hashes[BATCH][33] = {};
  int64_t bookIds[BATCH] = {};
  std::string paths[BATCH];
  size_t count = 0;
  size_t batches = 0;
  size_t queued = 0;
  bool stop = false;
  bool failed = false;
  char token[BookOrbitSyncClient::LIBRARY_VERSION_SIZE] = {};
  std::string knownToken;
};

void onIncompatible(const char* hash, const int64_t bookId, const int64_t bookFileId, void* context) {
  auto* scan = static_cast<Scan*>(context);
  for (size_t i = 0; i < scan->count; ++i) {
    if (strcasecmp(scan->hashes[i], hash) != 0) continue;
    const orbify::refresh::Match match{bookId, bookFileId, false};
    if (!orbify::refresh::shouldRefresh(scan->bookIds[i], scan->hashes[i], &match)) continue;
    orbify::refresh::Entry entry;
    entry.bookId = bookId;
    entry.fileId = bookFileId;
    std::memcpy(entry.oldHash, scan->hashes[i], 32);
    entry.path = scan->paths[i];
    if (scan->queue->add(entry)) {
      ++scan->queued;
      LOG_INF(TAG, "Copy refresh: %s is an older copy of book %lld (card %s)", entry.path.c_str(),
              static_cast<long long>(bookId), entry.oldHash);
    }
  }
}

void flush(Scan& scan) {
  if (scan.count == 0 || scan.stop) return;
  const auto err = BookOrbitSyncClient::matchCheck(SETTINGS.getEffectiveDeviceName(), scan.queries, scan.count,
                                                   nullptr, &scan, scan.token, onIncompatible);
  if (err != BookOrbitSyncClient::OK) {
    LOG_ERR(TAG, "Copy refresh: match check failed (%d)", static_cast<int>(err));
    scan.stop = scan.failed = true;
  }
  ++scan.batches;
  scan.count = 0;
  // Nothing on the server changed since the last full pass: the rest of the card is as it was.
  if (scan.batches == 1 && !scan.knownToken.empty() && scan.knownToken == scan.token) scan.stop = true;
}

void visitDownload(const int64_t bookId, const std::string& path, void* context) {
  auto* scan = static_cast<Scan*>(context);
  if (scan->stop) return;
  if (scan->cancelled && scan->cancelled()) {
    scan->stop = scan->failed = true;
    return;
  }
  const std::string hash = BookContentId::contentHash(path);
  if (hash.size() != 32) return;
  const size_t i = scan->count;
  std::memcpy(scan->hashes[i], hash.c_str(), 33);
  scan->bookIds[i] = bookId;
  scan->paths[i] = path;
  scan->queries[i] = BookOrbitSyncClient::MatchQuery{scan->hashes[i], nullptr, nullptr};
  if (++scan->count == BATCH) flush(*scan);
}

HttpDownloader::DownloadOptions downloadOptions() {
  // The catalog download's safeguards (BookOrbitCatalogBrowserActivity::downloadBook): staged
  // as "<book>.part", resumable, checked for room, swapped in only once it opens as an EPUB,
  // and the replaced copy kept at "<book>.old" until its state has moved.
  HttpDownloader::DownloadOptions options;
  options.bufferSize = 2048;
  options.preservePartial = true;
  options.reserveFullRecord = true;
  options.stageAsPart = true;
  options.keepReplaced = true;
  options.checkFreeSpace = true;
  options.validate = [](const std::string& path) {
    ZipFile zip(path);
    size_t size = 0;
    return zip.getInflatedFileSize("META-INF/container.xml", &size) && size > 0;
  };
  return options;
}

bool epubFile(const BookOrbitBookDetail& detail, const int64_t fileId, BookOrbitCatalogFile& out) {
  for (const auto& file : detail.files) {
    if (file.id == fileId || (fileId == 0 && file.format == "epub")) {
      out = file;
      return true;
    }
  }
  for (const auto& file : detail.files) {
    if (file.format == "epub") {
      out = file;
      return true;
    }
  }
  return false;
}

enum class Outcome { Replaced, AlreadyCurrent, Failed, GiveUp, Stop };

Outcome refreshOne(const orbify::refresh::Entry& entry, bool (*cancelled)()) {
  if (!Storage.exists(entry.path.c_str())) {
    LOG_INF(TAG, "Copy refresh: %s is gone from the card; dropped", entry.path.c_str());
    return Outcome::GiveUp;
  }
  // On a connection already open (the sleep sync lends its own, patch 0037) a request needs no
  // TLS session of its own, only room beside the one there; a new connection needs the block.
  const bool kept = BookOrbitCatalogClient::keptConnection() != nullptr;
  if (kept && !OrbifyHeap::roomForRequest("Copy refresh")) return Outcome::Stop;
  if (!kept && ESP.getMaxAllocHeap() < DOWNLOAD_MIN_BLOCK) {
    LOG_INF(TAG, "Copy refresh: heap too fragmented for a download (largest %u); later",
            static_cast<unsigned>(ESP.getMaxAllocHeap()));
    return Outcome::Stop;
  }
  BookOrbitBookDetail detail;
  if (!BookOrbitCatalogClient::fetchBookDetail(entry.bookId, detail)) return Outcome::Failed;
  BookOrbitCatalogFile file;
  if (!epubFile(detail, entry.fileId, file)) {
    LOG_INF(TAG, "Copy refresh: book %lld has no EPUB file now; dropped", static_cast<long long>(entry.bookId));
    return Outcome::GiveUp;
  }
  const std::string cardHash = BookContentId::contentHash(entry.path);
  switch (orbify::refresh::beforeDownload(cardHash.c_str(), file.fileHash.c_str())) {
    case orbify::refresh::BeforeDownload::AlreadyCurrent:
      BookOrbitDownloadIndex::record(entry.bookId, entry.path);
      LOG_INF(TAG, "Copy refresh: %s already is the library file (%s)", entry.path.c_str(), cardHash.c_str());
      return Outcome::AlreadyCurrent;
    case orbify::refresh::BeforeDownload::CannotVerify:
      LOG_INF(TAG, "Copy refresh: book %lld file %lld sends no hash; not downloaded",
              static_cast<long long>(entry.bookId), static_cast<long long>(file.id));
      return Outcome::GiveUp;
    case orbify::refresh::BeforeDownload::Download:
      break;
  }

  // A replacement a reset interrupted moves its state first (as the catalog does).
  if (BookUpdateMigration::pending(entry.path)) BookUpdateMigration::begin(entry.path, /*renderCacheIsOld=*/false);
  const unsigned long started = millis();
  // The saved position's percentage, for the log (read before the migration clears the render
  // cache it lives beside; the position itself moves with the book's state).
  RecentBook book;
  book.path = entry.path;
  const float percent = RecentBookProgress::loadCachedEpubPercent(book);
  bool cancel = false;
  HttpDownloader::DownloadOptions options = downloadOptions();
  options.wolfSslClient = BookOrbitCatalogClient::keptConnection();
  // Checked between the body's chunks: a wake press (or the sleep sync's time budget) stops the
  // transfer there, and so does a heap the relay's TLS would starve on. The .part stays and the
  // next run resumes it.
  options.shouldCancel = [cancelled, kept]() { return (cancelled && cancelled()) || (kept && OrbifyHeap::starved()); };
  HttpDownloader::DownloadError result = HttpDownloader::HTTP_ERROR;
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (cancelled && cancelled()) return Outcome::Stop;
    // A transfer a wake press stopped resumes from its .part (the hash check below still decides).
    options.resumePartial = attempt > 0 || Storage.exists((entry.path + ".part").c_str());
    result = BookOrbitCatalogClient::downloadFile(file.id, entry.path, nullptr, &cancel, options);
    if (result == HttpDownloader::OK || result == HttpDownloader::ABORTED ||
        result == HttpDownloader::INSUFFICIENT_SPACE) {
      break;
    }
  }
  if (result == HttpDownloader::ABORTED) {
    // Not the book's fault: it keeps its attempts, and its .part for the resume.
    LOG_INF(TAG, "Copy refresh: download of book %lld stopped; resumes next time", static_cast<long long>(entry.bookId));
    return Outcome::Stop;
  }
  if (result != HttpDownloader::OK) {
    LOG_ERR(TAG, "Copy refresh: download of book %lld failed (err=%d)", static_cast<long long>(entry.bookId),
            static_cast<int>(result));
    if (result != HttpDownloader::ABORTED) Storage.remove((entry.path + ".part").c_str());
    return result == HttpDownloader::INSUFFICIENT_SPACE ? Outcome::GiveUp : Outcome::Failed;
  }

  BookContentId::forget(entry.path);
  const std::string newHash = KOReaderDocumentId::calculate(entry.path);
  if (orbify::refresh::afterDownload(newHash.c_str(), file.fileHash.c_str()) ==
      orbify::refresh::AfterDownload::RollBack) {
    // Not the library file after all: the old copy goes back, its state never moved.
    const std::string old = entry.path + ".old";
    Storage.remove(entry.path.c_str());
    Storage.rename(old.c_str(), entry.path.c_str());
    BookContentId::forget(entry.path);
    LOG_ERR(TAG, "Copy refresh: book %lld downloaded as %s, library says %s; old copy kept",
            static_cast<long long>(entry.bookId), newHash.c_str(), file.fileHash.c_str());
    return Outcome::Failed;
  }
  // Highlights, bookmarks, reading progress and sync state move to the new hash; the render
  // cache (built, if at all, for the old copy) is cleared and "<book>.old" removed.
  if (BookUpdateMigration::pending(entry.path)) BookUpdateMigration::begin(entry.path, /*renderCacheIsOld=*/true);
  BookOrbitDownloadIndex::record(entry.bookId, entry.path);
  library::invalidateLibraryIndex();
  LOG_INF(TAG, "Copy refresh: %s (book %lld) replaced: %s -> %s in %lu s", entry.path.c_str(),
          static_cast<long long>(entry.bookId), entry.oldHash, newHash.c_str(), (millis() - started) / 1000);
  // The position moved with the book's state (BookUpdateMigration): the reader opens there.
  if (RecentBookProgress::hasPercent(percent)) {
    LOG_INF(TAG, "Copy refresh: book %lld replaced, position kept at %.0f%%", static_cast<long long>(entry.bookId),
            static_cast<double>(percent));
  } else {
    LOG_INF(TAG, "Copy refresh: book %lld replaced, position kept (not opened here yet)",
            static_cast<long long>(entry.bookId));
  }
  return Outcome::Replaced;
}

}  // namespace

namespace OrbifyCopyRefresh {

bool enabled() { return BOOKORBIT_STORE.hasCredentials() && BOOKORBIT_STORE.getOrbifyKeepCopiesCurrent(); }

size_t detect(bool (*cancelled)()) {
  if (!enabled()) return 0;
  orbify::refresh::Queue queue;
  load(queue);
  std::unique_ptr<Scan> scan(new (std::nothrow) Scan());
  if (!scan) return 0;
  scan->queue = &queue;
  scan->cancelled = cancelled;
  scan->knownToken = readText(TOKEN_PATH);
  BookOrbitDownloadIndex::forEachExisting(visitDownload, scan.get());
  BookOrbitDownloadIndex::unload();
  flush(*scan);
  const bool fullPass = !scan->failed && (scan->batches > 1 || scan->knownToken != scan->token);
  if (scan->queued) save(queue);
  if (fullPass && scan->token[0]) {
    Storage.mkdir("/.crosspoint");
    Storage.mkdir(DIR);
    writeText(TOKEN_PATH, scan->token);
  }
  LOG_INF(TAG, "Copy refresh: %u queued (%u waiting, %u batch%s%s)", static_cast<unsigned>(scan->queued),
          static_cast<unsigned>(queue.pending()), static_cast<unsigned>(scan->batches), scan->batches == 1 ? "" : "es",
          scan->failed ? ", stopped early" : "");
  return scan->queued;
}

size_t run(bool (*cancelled)(), const unsigned long budgetMs, const char* where) {
  if (!enabled()) return 0;
  orbify::refresh::Queue queue;
  if (!load(queue) || queue.pending() == 0) return 0;
  const unsigned long started = millis();
  size_t replaced = 0;
  while (const orbify::refresh::Entry* next = queue.next()) {
    if ((cancelled && cancelled()) || millis() - started > budgetMs) break;
    const orbify::refresh::Entry entry = *next;
    const Outcome outcome = refreshOne(entry, cancelled);
    if (outcome == Outcome::Stop) break;
    if (outcome == Outcome::Replaced || outcome == Outcome::AlreadyCurrent || outcome == Outcome::GiveUp) {
      queue.done(entry.path);
    } else {
      queue.failed(entry.path);
    }
    replaced += outcome == Outcome::Replaced ? 1 : 0;
    save(queue);  // after every book: a wake press or a reset resumes here
  }
  LOG_INF(TAG, "Copy refresh: replaced %u (%s), %u carried over", static_cast<unsigned>(replaced), where,
          static_cast<unsigned>(queue.pending()));
  return replaced;
}

bool enqueue(const int64_t bookId, const std::string& path, const std::string& cardHash) {
  if (!enabled() || bookId <= 0 || cardHash.size() != 32) return false;
  orbify::refresh::Queue queue;
  load(queue);
  orbify::refresh::Entry entry;
  entry.bookId = bookId;
  std::memcpy(entry.oldHash, cardHash.c_str(), 32);
  entry.path = path;
  if (!queue.add(entry)) return true;
  LOG_INF(TAG, "Copy refresh: 1 queued (%s, from the sync)", path.c_str());
  return save(queue);
}

size_t pending() {
  orbify::refresh::Queue queue;
  load(queue);
  return queue.pending();
}

std::string libraryVersion() {
  std::string token = readText(TOKEN_PATH);
  while (!token.empty() && (token.back() == '\n' || token.back() == '\r')) token.pop_back();
  return token;
}

}  // namespace OrbifyCopyRefresh

#else

namespace OrbifyCopyRefresh {
bool enabled() { return false; }
size_t detect(bool (*)()) { return 0; }
size_t run(bool (*)(), unsigned long, const char*) { return 0; }
bool enqueue(int64_t, const std::string&, const std::string&) { return false; }
size_t pending() { return 0; }
std::string libraryVersion() { return std::string(); }
}  // namespace OrbifyCopyRefresh

#endif
