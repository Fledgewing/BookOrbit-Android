// SPDX-License-Identifier: GPL-3.0-or-later
#include "Mirror.h"

#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_MIRROR

#include <Arduino.h>
#include <HalStorage.h>
#include <I18n.h>
#include <Logging.h>
#include <WiFi.h>

#include <ctime>
#include <vector>

#include "BookOrbitDownloadIndex.h"
#include "CacheStore.h"
#include "CopyRefresh.h"
#include "FinishSync.h"
#include "HeapFloor.h"
#include "core/LocalFirst.h"
#include "network/BookOrbitCatalogClient.h"

namespace {

using orbify::mirror::Due;
using orbify::mirror::Kind;
using orbify::mirror::Plan;

const char* const TAG = "ORB";
const char* const DIR = "/.crosspoint/orbify";
const char* const PLAN_PATH = "/.crosspoint/orbify/mirror.tsv";
const char* const PLAN_TMP = "/.crosspoint/orbify/mirror.tmp";
const char* const STATE_PATH = "/.crosspoint/orbify/mirror.state";
const char* const REQUEST_PATH = "/.crosspoint/orbify/mirror.request";
constexpr size_t MAX_FILE = 32 * 1024;
constexpr uint32_t MIN_PLAUSIBLE_EPOCH = 1700000000u;
bool userRunThisBoot = false;

uint32_t nowSeconds() {
  const time_t t = time(nullptr);
  return t >= static_cast<time_t>(MIN_PLAUSIBLE_EPOCH) ? static_cast<uint32_t>(t) : 0;
}

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
  Storage.mkdir("/.crosspoint");
  Storage.mkdir(DIR);
  HalFile file;
  if (!Storage.openFileForWrite(TAG, path, file)) return false;
  const bool ok = file.write(reinterpret_cast<const uint8_t*>(text.data()), text.size()) == text.size();
  file.sync();
  file.close();
  return ok;
}

// "<at>\t<library version>\n"
struct State {
  uint32_t at = 0;
  std::string library;
  bool saved = false;
};

State loadState() {
  State s;
  const std::string text = readText(STATE_PATH);
  if (text.empty()) return s;
  s.saved = true;
  s.at = static_cast<uint32_t>(strtoul(text.c_str(), nullptr, 10));
  const size_t tab = text.find('\t');
  if (tab != std::string::npos) {
    s.library = text.substr(tab + 1);
    while (!s.library.empty() && (s.library.back() == '\n' || s.library.back() == '\r')) s.library.pop_back();
  }
  return s;
}

bool loadPlan(Plan& plan) {
  if (!Storage.exists(PLAN_PATH) && Storage.exists(PLAN_TMP)) Storage.rename(PLAN_TMP, PLAN_PATH);
  const std::string text = readText(PLAN_PATH);
  // Older walks interleaved discovery and data. Restart them once under the fixed-total rule.
  return text.find("orbify-mirror 4\n") == 0 && plan.parse(text);
}

void savePlan(const Plan& plan) {
  if (!writeText(PLAN_TMP, plan.serialize())) {
    LOG_ERR(TAG, "Mirror: plan not saved");
    return;
  }
  Storage.remove(PLAN_PATH);
  Storage.rename(PLAN_TMP, PLAN_PATH);
}

orbify::mirror::FacetQuery toFacet(const BookOrbitBookQuery& q) {
  orbify::mirror::FacetQuery f;
  f.sort = q.sort;
  f.order = q.order;
  f.readStatus = q.readStatus;
  f.shelf = q.shelf;
  f.query = q.query;
  f.author = q.author;
  f.seriesId = q.seriesId;
  f.series = q.series;
  f.collectionId = q.collectionId;
  f.smartScopeId = q.smartScopeId;
  f.libraryId = q.libraryId;
  return f;
}

BookOrbitBookQuery fromFacet(const orbify::mirror::FacetQuery& f) {
  BookOrbitBookQuery q;
  q.sort = f.sort;
  q.order = f.order;
  q.readStatus = f.readStatus;
  q.shelf = f.shelf;
  q.query = f.query;
  q.author = f.author;
  q.seriesId = f.seriesId;
  q.series = f.series;
  q.collectionId = f.collectionId;
  q.smartScopeId = f.smartScopeId;
  q.libraryId = f.libraryId;
  return q;
}

// The books on the reader and the next book of each one's series, up to MAX_DETAILS.
struct DetailSeed {
  Plan* plan = nullptr;
  size_t added = 0;
};

void addDetails(int64_t bookId, const std::string& path, void* context) {
  auto* seed = static_cast<DetailSeed*>(context);
  if (seed->added >= orbify::mirror::MAX_DETAILS) return;
  if (bookId > 0 && seed->plan->add(Kind::Detail, std::to_string(bookId))) seed->added++;
  orbify::SeriesCard card;
  if (seed->added < orbify::mirror::MAX_DETAILS && OrbifyFinish::loadCard(path, card) && card.nextBook.id > 0 &&
      seed->plan->add(Kind::Detail, std::to_string(card.nextBook.id))) {
    seed->added++;
  }
}

void seed(Plan& plan) {
  plan.add(Kind::Root, "");
  // The want-to-read shelf the browser adds to the root (it is not among the server's sections).
  plan.add(Kind::Books, orbify::mirror::encodeQuery(toFacet(
                            BookOrbitCatalogClient::sectionBookQuery(BookOrbitCatalogClient::WANT_TO_READ_SHELF))));
  DetailSeed details{&plan, 0};
  BookOrbitDownloadIndex::forEachExisting(addDetails, &details);
  BookOrbitDownloadIndex::unload();
}

// One request. Returns false when it failed.
bool runStep(const orbify::mirror::Step& step, Plan& plan) {
  switch (step.kind) {
    case Kind::Root: {
      std::vector<BookOrbitCatalogSection> sections;
      if (!BookOrbitCatalogClient::fetchRootSections(sections)) return false;
      // Save the root's counts too (the dashboard's want-to-read shelf and two totals), so a
      // cache-first catalog opens its root with no request at all. Optional, as on the root.
      // Behind the same heap floor as a step (the sleep sync's slice).
      BookOrbitCatalogCounts counts;
      if (OrbifyHeap::roomForRequest("Mirror")) BookOrbitCatalogClient::fetchCatalogCounts(counts);
      for (const auto& section : sections) {
        if (orbify::mirror::isFacetSection(section.id)) {
          plan.add(Kind::Section, section.id);
        } else {
          plan.add(Kind::Books,
                   orbify::mirror::encodeQuery(toFacet(BookOrbitCatalogClient::sectionBookQuery(section.id))));
        }
      }
      return true;
    }
    case Kind::Section: {
      BookOrbitFacetPage page;
      if (!BookOrbitCatalogClient::fetchSectionEntries(step.arg, 1, page)) return false;
      size_t lists = 0;
      for (const auto& entry : page.entries) {
        if (lists >= orbify::mirror::MAX_LISTS_PER_FACET) break;
        if (plan.add(Kind::Books, orbify::mirror::encodeQuery(
                                      orbify::mirror::facetQuery(step.arg, entry.id, entry.seriesId)))) {
          lists++;
        }
      }
      return true;
    }
    case Kind::Books: {
      orbify::mirror::FacetQuery facet;
      if (!orbify::mirror::decodeQuery(step.arg, facet)) return true;  // unreadable: skipped
      BookOrbitBookPage page;
      return BookOrbitCatalogClient::fetchBooks(fromFacet(facet), 1, page);
    }
    case Kind::Detail: {
      BookOrbitBookDetail detail;
      return BookOrbitCatalogClient::fetchBookDetail(strtoll(step.arg.c_str(), nullptr, 10), detail);
    }
  }
  return true;
}

}  // namespace

namespace OrbifyMirror {

void refreshChanged(bool (*cancelled)()) {
  if (requested() || WiFi.status() != WL_CONNECTED || (cancelled && cancelled()) ||
      !OrbifyHeap::roomForRequest("Catalog incremental")) return;
  // The pinned catalog has no delta endpoint. One bounded head page, never a full walk.
  OrbifyCache::ScopedMode refresh(orbify::cache::Mode::Refresh);
  BookOrbitBookQuery query;
  query.sort = "recently_updated";
  BookOrbitBookPage page;
  if (BookOrbitCatalogClient::fetchBooks(query, 1, page) && !(cancelled && cancelled())) {
    OrbifyCache::mergeRecent();
  }
}

bool saved() { return loadState().saved; }
uint32_t savedAt() { return loadState().at; }
bool requested() { return Storage.exists(REQUEST_PATH); }

bool quietRestart() { return userRunThisBoot || (Storage.ready() && requested()); }

void request() {
  userRunThisBoot = true;
  writeText(REQUEST_PATH, "1\n");
  LOG_INF(TAG, "Mirror: Full refresh asked for");
}

Due dueNow() {
  // Retain the cache indefinitely. Only request() (a user action) starts a Full refresh.
  return Due::None;
}

namespace {
// Loads the plan on the card, or seeds a new one. True when it resumed one.
bool loadOrSeed(Plan& plan) {
  const bool resumed = loadPlan(plan) && !plan.empty();
  if (!resumed) {
    plan = Plan{};
    seed(plan);
    savePlan(plan);
  }
  LOG_INF(TAG, "Mirror: Full refresh %s, %u/%u requests, %u%% (free=%u maxAlloc=%u)", resumed ? "resumed" : "started",
          static_cast<unsigned>(plan.doneCount()), static_cast<unsigned>(plan.total()), plan.percent(),
          ESP.getFreeHeap(), ESP.getMaxAllocHeap());
  return resumed;
}

void runOne(Plan& plan) {
  const orbify::mirror::Step current = *plan.next();
  const bool ok = runStep(current, plan);
  if (!ok) {
    LOG_ERR(TAG, "Mirror: request %u failed (kind %u, %s)", static_cast<unsigned>(plan.doneCount() + 1),
            static_cast<unsigned>(current.kind), current.arg.c_str());
  }
  plan.advance(!ok);
  savePlan(plan);
}

// The last request ran: the mirror is saved, the plan and the request go.
void complete(const Plan& plan, const unsigned long seconds) {
  const std::string library = OrbifyCopyRefresh::libraryVersion();
  writeText(STATE_PATH, std::to_string(nowSeconds()) + "\t" + library + "\n");
  Storage.remove(PLAN_PATH);
  Storage.remove(REQUEST_PATH);
  LOG_INF(TAG, "Mirror: saved for offline: %u lists, %u sections, %u details, %u requests (%u failed) in %lu s",
          static_cast<unsigned>(plan.count(Kind::Books)), static_cast<unsigned>(plan.count(Kind::Section)),
          static_cast<unsigned>(plan.count(Kind::Detail)), static_cast<unsigned>(plan.total()),
          static_cast<unsigned>(plan.failures()), seconds);
}
}  // namespace

bool run(bool (*cancelled)(), const unsigned long budgetMs, const Progress* progress, const size_t maxSteps,
         const bool heapFloor) {
  if (!requested()) return false;  // no automatic Full refresh, even through a future caller
  userRunThisBoot = true;
  const unsigned long started = millis();
  Plan plan;
  loadOrSeed(plan);
  const size_t failedBefore = plan.failures();
  size_t ran = 0;
  unsigned long noteAt = started;
  {
    // Every request of the plan replaces its cache entry (Full refresh), on one TLS connection.
    OrbifyCache::ScopedMode full(orbify::cache::Mode::Full);
    BookOrbitCatalogClient::Session session;
    while (plan.next() != nullptr) {
      if (cancelled && cancelled()) break;
      if (budgetMs != 0 && millis() - started >= budgetMs) break;
      if (maxSteps != 0 && ran >= maxSteps) break;
      if (heapFloor && !OrbifyHeap::roomForRequest("Mirror")) break;
      if (WiFi.status() != WL_CONNECTED) {
        LOG_INF(TAG, "Mirror: the network went; stopping at %u/%u", static_cast<unsigned>(plan.doneCount()),
                static_cast<unsigned>(plan.total()));
        break;
      }
      runOne(plan);
      ran++;
      if (progress && progress->step) progress->step(progress->context, plan.percent());
      if (millis() - noteAt >= 10000) {
        noteAt = millis();
        LOG_INF(TAG, "Mirror: Full refresh %u%% (%u/%u)", plan.percent(), static_cast<unsigned>(plan.doneCount()),
                static_cast<unsigned>(plan.total()));
      }
    }
  }
  const unsigned long seconds = (millis() - started) / 1000;
  if (!plan.finished()) {
    LOG_INF(TAG, "Mirror: paused at %u/%u, %u%% (%u this run, %u failed, %lu s); resumes next time",
            static_cast<unsigned>(plan.doneCount()), static_cast<unsigned>(plan.total()), plan.percent(),
            static_cast<unsigned>(ran), static_cast<unsigned>(plan.failures() - failedBefore), seconds);
    return false;
  }
  complete(plan, seconds);
  return true;
}

int pendingPercent() {
  if (!requested()) return -1;
  Plan plan;
  if (!loadPlan(plan) || plan.empty()) return 0;
  return static_cast<int>(plan.percent());
}

void Walk::begin(const bool userStarted) {
  if (userStarted) request();
  if (!orbify::mirror::showProgress(requested(), true)) return;
  userRunThisBoot = true;
  plan = Plan{};
  connectionFailed = false;
  loadOrSeed(plan);
  started = true;
  startedAt = millis();
}

void Walk::step() {
  if (!started || connectionFailed || plan.next() == nullptr) return;
  {
    OrbifyCache::ScopedMode full(orbify::cache::Mode::Full);
    runOne(plan);
  }
  if (plan.finished()) complete(plan, (millis() - startedAt) / 1000);
}

std::string savedLine() {
  const State s = loadState();
  if (!s.saved) return tr(STR_ORBIFY_NOT_SAVED_OFFLINE);
  std::string line = tr(STR_ORBIFY_SAVED_OFFLINE);
  const uint32_t now = nowSeconds();
  if (s.at != 0 && now >= s.at) {
    char age[24];
    orbify::formatAge(now - s.at, age, sizeof(age));
    line += " \xC2\xB7 ";
    line += age;
    if (std::string(age) != "just now") line += " ago";
  }
  return line;
}

}  // namespace OrbifyMirror

#endif  // CROSSINK_TAILNET_ORBIFY_MIRROR
