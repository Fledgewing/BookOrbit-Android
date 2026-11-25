// SPDX-License-Identifier: GPL-3.0-or-later
#include "OrbiSmartSync.h"
#include "BookOrbitDownloadIndex.h"
#include "BookOrbitHomeStore.h"
#include "CrossPointSettings.h"
#include "FinishSync.h"
#include "activities/RenderLock.h"
#include "activities/reader/BookReadingStats.h"
#include "activities/reader/EpubReaderUtils.h"
#include "activities/reader/bookorbit/BookOrbitRemotePosition.h"
#include "activities/reader/bookorbit/BookOrbitSyncMarkerFile.h"
#include "core/OrbiSmartState.h"
#include "network/BookOrbitCatalogClient.h"
#include "sync/BookSyncFile.h"
#include "util/BookContentId.h"
#include <Arduino.h>
#include <BookOrbitCredentialStore.h>
#include <BookOrbitSyncClient.h>
#include <HalStorage.h>
#include <KOReaderDocumentId.h>
#include <Logging.h>
#include <WallClock.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

extern GfxRenderer renderer;

namespace OrbiSmartSync {
namespace {
constexpr char DIR[] = "/.crosspoint/orbismart";
std::mutex stateMutex;
std::atomic<uint32_t> changes{0};
int64_t now() {
  uint32_t t = 0;
  WallClock::now(t);
  return t;
}
std::string hashOf(const std::string &path) {
  return KOReaderDocumentId::calculate(path);
}
std::string slot(const std::string &hash, int n) {
  return std::string(DIR) + "/" + hash + "." + char('0' + n);
}
// Two complete generations per book. A failed write never replaces the previous
// valid slot.
uint32_t serverKey() {
  const auto &server = BOOKORBIT_STORE.getServerUrl();
  const auto &user = BOOKORBIT_STORE.getUsername();
  const std::string scope = server + "\n" + user;
  return hashBytes(scope.data(), scope.size());
}
int load(const std::string &hash, State &state) {
  int best = -1;
  for (int i = 0; i < 2; ++i) {
    const auto path = slot(hash, i);
    if (!Storage.exists(path.c_str()))
      continue;
    HalFile f = Storage.open(path.c_str());
    State candidate;
    const bool ok =
        f && f.size() == sizeof(candidate) &&
        f.read(&candidate, sizeof(candidate)) == sizeof(candidate) &&
        valid(candidate, serverKey());
    if (f)
      f.close();
    if (ok && (best < 0 || candidate.generation > state.generation)) {
      best = i;
      state = candidate;
    }
  }
  return best;
}
bool save(const std::string &hash, State &state, int previous) {
  if (hash.size() != 32)
    return false;
  Storage.mkdir(DIR);
  ++state.generation;
  state.server = serverKey();
  seal(state);
  const std::string path = slot(hash, previous == 0 ? 1 : 0);
  HalFile f;
  if (!Storage.openFileForWrite("ORB", path.c_str(), f))
    return false;
  const bool ok = f.write(reinterpret_cast<const uint8_t *>(&state),
                          sizeof(state)) == sizeof(state);
  f.close();
  if (!ok)
    Storage.remove(path.c_str());
  else
    changes.fetch_add(1);
  return ok;
}
bool putRemote(RemoteRecord &o, const KOReaderProgress &p) {
  if (p.progress.size() >= sizeof(o.xpath))
    return false;
  o = RemoteRecord{};
  memcpy(o.xpath, p.progress.c_str(), p.progress.size());
  snprintf(o.device, sizeof(o.device), "%s", p.device.c_str());
  snprintf(o.deviceId, sizeof(o.deviceId), "%s", p.deviceId.c_str());
  o.percent = p.percentage;
  o.at = p.timestamp;
  return true;
}
KOReaderProgress getRemote(const RemoteRecord &o) {
  KOReaderProgress p{};
  p.progress = o.xpath;
  p.percentage = o.percent;
  p.device = o.device;
  p.deviceId = o.deviceId;
  p.timestamp = o.at;
  return p;
}
// Chapters occupy ordered bands; within a chapter use today's local page count.
// Marker pages are rescaled to that same layout. This preserves +/- one page
// without ordering raw percentages.
double ordinal(const CrossPointPosition &p) {
  return p.spineIndex * 1000000.0 + p.pageNumber;
}
CrossPointPosition markerPosition(const BookOrbitSmartSync::Marker &m,
                                  const CrossPointPosition &local,
                                  const CrossPointPosition &remote) {
  const int count = m.spineIndex == local.spineIndex    ? local.totalPages
                    : m.spineIndex == remote.spineIndex ? remote.totalPages
                                                        : m.pageCount;
  return {m.spineIndex, BookOrbitSmartSync::pageOutOf(m.position(), count),
          count};
}
} // namespace

uint32_t generation() { return changes.load(); }
bool enabled() { return BOOKORBIT_STORE.getOrbiSmart(); }
bool checkOnOpen(const std::string &path) {
  State doc;
  {
    std::lock_guard<std::mutex> lock(stateMutex);
    load(hashOf(path), doc);
  }
  const int64_t slept = doc.slept;
  return wakeDue(now(), slept);
}

Result evaluate(const std::shared_ptr<Epub> &epub,
                const CrossPointPosition &local, const KOReaderProgress *remote,
                const CrossPointPosition &mapped, const Moment moment) {
  const auto marker = BookOrbitSyncMarkerFile::read(
      BookContentId::bookStateDir(epub->getPath()));
  State doc;
  {
    std::lock_guard<std::mutex> lock(stateMutex);
    load(hashOf(epub->getPath()), doc);
  }
  if (remote || moment == Moment::Sleep) {
    std::lock_guard<std::mutex> lock(stateMutex);
    const auto hash = hashOf(epub->getPath());
    const int old = load(hash, doc);
    if (remote)
      putRemote(doc.seen, *remote);
    if (moment == Moment::Sleep)
      doc.slept = now();
    save(hash, doc, old);
  }
  // A failed queued override stays first; ordinary snapshots must not replace
  // its chosen place.
  if ((doc.flags & State::OVERRIDE))
    return {Decision::Hold, Rule::Override, false};
  Input in;
  in.local = ordinal(local);
  in.hasServer = remote != nullptr;
  in.server = ordinal(mapped);
  in.serverAt = remote ? remote->timestamp : 0;
  in.hasMarker = marker.timestamp > 0;
  in.markerAt = marker.timestamp;
  in.markerPlace = ordinal(markerPosition(marker, local, mapped));
  in.turnAt = doc.turn;
  in.declinedAt = doc.declined;
  in.reset = remote && remote->device == "web" &&
             remote->deviceId == "bookorbit-web" && remote->percentage == 0;
  in.redated =
      remote &&
      BookOrbitSmartSync::onlyRedated(
          {mapped.spineIndex, mapped.pageNumber, mapped.totalPages}, marker);
  const float percent = BookOrbitRemotePosition::localPercent(*epub, local);
  const bool held =
      OrbifyFinish::holdPush(epub->getPath(), hashOf(epub->getPath()), percent);
  orbify::SeriesCard card;
  const auto stats = BookReadingStats::load(epub->getCachePath());
  const bool finished = held || stats.isCompleted ||
                        (OrbifyFinish::loadCard(epub->getPath(), card) &&
                         card.status == orbify::ServerStatus::Read);
  if (finished && !(doc.flags & State::FINISHED)) {
    std::lock_guard<std::mutex> lock(stateMutex);
    const auto hash = hashOf(epub->getPath());
    const int old = load(hash, doc);
    doc.flags |= State::FINISHED;
    if (stats.isCompleted)
      doc.flags |= State::WAS_COMPLETED;
    doc.finishTurns = stats.totalPagesTurned;
    save(hash, doc, old);
  }
  in.finished = finished;
  in.released =
      !held && ((stats.totalPagesTurned >= doc.finishTurns + 10) ||
                ((doc.flags & State::WAS_COMPLETED) && !stats.isCompleted));
  in.percentOnly = remote && remote->progress.empty();
  if (in.percentOnly) {
    in.local = percent * 100;
    in.server = remote->percentage * 100;
    in.tolerance = 2;
    in.markerPlace = BookOrbitRemotePosition::localPercent(
                         *epub, markerPosition(marker, local, mapped)) *
                     100;
  }
  const Result r = decide(in);
  char line[192];
  formatLine(in, r, moment, line, sizeof(line));
  LOG_INF("ORB", "%s", line);
  return r;
}

bool pushAllowed(const std::shared_ptr<Epub> &epub,
                 const CrossPointPosition &local,
                 const KOReaderProgress *remote,
                 const CrossPointPosition &mapped, bool exempt) {
  KOReaderProgress known{};
  CrossPointPosition target = mapped;
  if (!remote && !exempt) {
    State state;
    {
      std::lock_guard<std::mutex> lock(stateMutex);
      load(hashOf(epub->getPath()), state);
    }
    if (state.seen.at > 0) {
      known = getRemote(state.seen);
      remote = &known;
      target = BookOrbitRemotePosition::toLocal(
          epub, renderer, known, local.spineIndex, local.totalPages);
    }
  }
  if (remote && !target.valid)
    return false;
  const bool percent = remote && remote->progress.empty();
  const double l =
      percent ? BookOrbitRemotePosition::localPercent(*epub, local) * 100
              : ordinal(local);
  const double r = percent ? remote->percentage * 100 : ordinal(target);
  const bool ok = mayPush(l, remote != nullptr, r, percent ? 2 : 1, exempt);
  if (!ok)
    LOG_INF("ORB", "orbismart: push held L=%g R=%g (behind the server)", l, r);
  return ok;
}

void remember(const std::string &path, const KOReaderProgress &remote,
              const bool wake) {
  std::lock_guard<std::mutex> lock(stateMutex);
  const auto hash = hashOf(path);
  State doc;
  const int old = load(hash, doc);
  if (!putRemote(doc.pending, remote))
    return;
  doc.flags |= State::PENDING;
  if (wake)
    doc.flags |= State::WAKE;
  else
    doc.flags &= ~State::WAKE;
  save(hash, doc, old);
}
bool pending(const std::string &path, KOReaderProgress &out, bool &wake) {
  std::lock_guard<std::mutex> lock(stateMutex);
  State doc;
  load(hashOf(path), doc);
  if (!(doc.flags & State::PENDING) || (doc.flags & State::OVERRIDE))
    return false;
  out = getRemote(doc.pending);
  wake = (doc.flags & State::WAKE) != 0;
  return out.timestamp != (doc.declined);
}
void resolve(const std::string &path, const KOReaderProgress &remote,
             const CrossPointPosition &mapped, const bool yes) {
  std::lock_guard<std::mutex> lock(stateMutex);
  const auto hash = hashOf(path);
  State doc;
  const int old = load(hash, doc);
  if (!yes)
    doc.declined = remote.timestamp;
  // An answer to an older popup must not discard a newer place arriving on the
  // worker.
  if (doc.pending.at == remote.timestamp)
    doc.flags &= ~State::PENDING;
  save(hash, doc, old);
  if (yes)
    BookOrbitSyncMarkerFile::write(
        BookContentId::bookStateDir(path), remote.timestamp,
        {mapped.spineIndex, mapped.pageNumber, mapped.totalPages});
}
void noteTurn(const std::string &path) {
  std::lock_guard<std::mutex> lock(stateMutex);
  const auto hash = hashOf(path);
  State doc;
  const int old = load(hash, doc);
  doc.turn = now();
  save(hash, doc, old);
}
bool queueOverride(const std::string &path, const KOReaderPosition &place,
                   const CrossPointPosition &local) {
  if (!place.valid || place.xpath.empty())
    return false;
  std::lock_guard<std::mutex> lock(stateMutex);
  const auto hash = hashOf(path);
  State doc;
  const int old = load(hash, doc);
  if (path.size() >= sizeof(doc.path))
    return false;
  KOReaderProgress chosen{};
  chosen.progress = place.xpath;
  chosen.percentage = place.percentage;
  chosen.timestamp = now();
  if (!putRemote(doc.chosen, chosen))
    return false;
  doc.spine = local.spineIndex;
  doc.page = local.pageNumber;
  doc.count = local.totalPages;
  snprintf(doc.path, sizeof(doc.path), "%s", path.c_str());
  doc.flags = (doc.flags | State::OVERRIDE) & ~State::PENDING;
  const bool ok = save(hash, doc, old);
  if (ok)
    LOG_INF("ORB", "orbismart: override queued");
  return ok;
}

void drainOverrides(bool (*stop)()) {
  std::vector<std::string> hashes;
  {
    HalFile dir = Storage.open(DIR);
    HalFile entry;
    char name[48];
    while (dir && (entry = dir.openNextFile())) {
      entry.getName(name, sizeof(name));
      entry.close();
      if (strlen(name) == 34 && name[32] == '.') {
        std::string hash(name, 32);
        if (std::find(hashes.begin(), hashes.end(), hash) == hashes.end())
          hashes.push_back(hash);
      }
    }
    if (dir)
      dir.close();
  }
  for (const auto &hash : hashes) {
    if (stop && stop())
      return;
    State doc;
    {
      std::lock_guard<std::mutex> lock(stateMutex);
      load(hash, doc);
    }
    if (!(doc.flags & State::OVERRIDE))
      continue;
    const auto chosen = getRemote(doc.chosen);
    KOReaderProgress remote{};
    const auto fetched = BookOrbitSyncClient::getProgress(hash, remote);
    if (fetched != BookOrbitSyncClient::OK &&
        fetched != BookOrbitSyncClient::NOT_FOUND)
      return;
    if (stop && stop())
      return;
    const auto seen = getRemote(doc.seen);
    bool redated = remote.progress == seen.progress &&
                   remote.percentage <= seen.percentage + .02f;
    if (!redated && seen.timestamp > 0 && remote.timestamp > chosen.timestamp &&
        fetched == BookOrbitSyncClient::OK) {
      // The web reader can re-date an earlier place in the same chapter. Map
      // both snapshots exactly as ordinary sync does; sibling paragraph numbers
      // alone cannot order nested containers. This work stays on the sync task,
      // under the cache lock.
      auto book = std::make_shared<Epub>(doc.path, "/.crosspoint");
      book->setupCacheDir();
      if (!book->load(false, true))
        return;
      std::optional<::RenderLock> cacheLock;
      for (;;) {
        cacheLock.emplace(::RenderLock::Mode::Try);
        if (cacheLock->ownsLock())
          break;
        cacheLock.reset();
        if (stop && stop())
          return;
        delay(20);
      }
      const auto before = BookOrbitRemotePosition::toLocal(
          book, renderer, seen, doc.spine, doc.count);
      const auto after = BookOrbitRemotePosition::toLocal(
          book, renderer, remote, doc.spine, doc.count);
      if (!before.valid || !after.valid)
        return;
      redated = BookOrbitSmartSync::onlyRedated(
          {after.spineIndex, after.pageNumber, after.totalPages},
          BookOrbitSmartSync::makeMarker(
              seen.timestamp,
              {before.spineIndex, before.pageNumber, before.totalPages}));
    }
    Input intent;
    intent.hasOverride = true;
    intent.overrideAt = chosen.timestamp;
    intent.hasServer = fetched == BookOrbitSyncClient::OK;
    intent.serverAt = remote.timestamp;
    intent.hasMarker = seen.timestamp > 0;
    intent.markerAt = seen.timestamp;
    intent.redated = redated;
    intent.local = chosen.percentage * 100;
    intent.server = remote.percentage * 100;
    intent.tolerance = 2;
    const auto decision = decide(intent);
    char line[192];
    formatLine(intent, decision, Moment::Manual, line, sizeof(line));
    LOG_INF("ORB", "%s", line);
    const bool drop = decision.dropped;
    if (!drop) {
      KOReaderProgress push = chosen;
      push.document = hash;
      push.timestamp = now();
      push.device = SETTINGS.getEffectiveDeviceName();
      if (BookOrbitSyncClient::updateProgress(push) != BookOrbitSyncClient::OK)
        return;
    }
    std::lock_guard<std::mutex> lock(stateMutex);
    State latest;
    const int old = load(hash, latest);
    if (latest.chosen.at == chosen.timestamp &&
        std::string(latest.chosen.xpath) == chosen.progress &&
        latest.chosen.percent == chosen.percentage &&
        latest.spine == doc.spine && latest.page == doc.page &&
        latest.count == doc.count) {
      if (!drop) {
        const std::string path = latest.path;
        BookOrbitSyncMarkerFile::write(BookContentId::bookStateDir(path), now(),
                                       {doc.spine, doc.page, doc.count});
      }
      latest.flags &= ~(State::OVERRIDE | State::PENDING);
      if (drop)
        putRemote(latest.seen, remote);
      else {
        latest.seen = doc.chosen;
        latest.seen.at = now();
      }
      save(hash, latest, old);
    }
    LOG_INF("ORB", "orbismart: override %s", drop ? "dropped" : "sent");
  }
}

void prefetch(const std::string &openPath, bool (*stop)()) {
  if (!enabled())
    return;
  BookOrbitHomeSnapshot home;
  if (!BookOrbitHomeStore::load(home))
    return;
  std::vector<std::string> paths;
  const auto add = [&](int64_t id) {
    std::string path;
    const bool found = BookOrbitDownloadIndex::lookup(id, path);
    BookOrbitDownloadIndex::unload();
    if (found && path != openPath && paths.size() < 3 &&
        std::find(paths.begin(), paths.end(), path) == paths.end())
      paths.push_back(path);
  };
  for (int i = 0;
       i < home.continueCount && i < BookOrbitHomeSnapshot::CONTINUE_COUNT; ++i)
    add(home.continueReading[i].id);
  // Home displays three rows, one often being the open book. Fill the remaining
  // slots from its same Continue-reading order, with a bounded single-page
  // listing.
  if (paths.size() < 3 && !(stop && stop())) {
    BookOrbitCatalogClient::Session catalog;
    BookOrbitBookPage page;
    if (BookOrbitCatalogClient::fetchBooks(
            BookOrbitCatalogClient::sectionBookQuery("continue-reading"), 1,
            page)) {
      for (const auto &book : page.books) {
        if (paths.size() == 3)
          break;
        add(book.id);
      }
    }
  }
  std::unique_ptr<BookOrbitSyncClient::Session> ownSession;
  if (!BookOrbitSyncClient::sessionConnection())
    ownSession.reset(new (std::nothrow) BookOrbitSyncClient::Session());
  unsigned saved = 0;
  for (const auto &path : paths) {
    if (stop && stop())
      break;
    const auto hash = hashOf(path);
    if (hash.size() != 32)
      continue;
    KOReaderProgress remote{};
    if (BookOrbitSyncClient::getProgress(hash, remote) ==
        BookOrbitSyncClient::OK) {
      remember(path, remote, false);
      ++saved;
    }
  }
  LOG_INF("ORB", "OrbiSmart: pending places saved %u/%u", saved,
          static_cast<unsigned>(paths.size()));
}

bool prerender(const std::shared_ptr<Epub> &epub, GfxRenderer &renderer) {
  if (!enabled())
    return false;
  KOReaderProgress remote{};
  bool wake = false;
  if (!pending(epub->getPath(), remote, wake) || wake)
    return false;
  EpubReaderUtils::Progress saved;
  EpubReaderUtils::loadProgress(*epub, saved);
  CrossPointPosition local{saved.spineIndex, saved.pageNumber,
                           std::max(1, saved.pageCount)};
  const auto mapped = BookOrbitRemotePosition::toLocal(
      epub, renderer, remote, local.spineIndex, local.totalPages);
  if (!mapped.valid)
    return false;
  const auto r = evaluate(epub, local, &remote, mapped, Moment::Prerender);
  if (apply(r.decision, Moment::Prerender) != Applied::Now)
    return false;
  const auto offset = mapped.hasVisibleTextOffset
                          ? std::optional<uint32_t>(mapped.visibleTextOffset)
                          : std::nullopt;
  if (!EpubReaderUtils::saveProgress(
          *epub, mapped.spineIndex, mapped.pageNumber,
          std::max(mapped.totalPages, mapped.pageNumber + 1), offset))
    return false;
  resolve(epub->getPath(), remote, mapped, true);
  LOG_INF("ORB", "pending place used (offline)");
  return true;
}
} // namespace OrbiSmartSync
