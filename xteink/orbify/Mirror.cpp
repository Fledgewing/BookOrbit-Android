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

bool runView(const orbify::mirror::Step& step, int pageNumber) {
  switch (step.kind) {
    case Kind::Root: {
      std::vector<BookOrbitCatalogSection> sections;
      return BookOrbitCatalogClient::fetchRootSections(sections);
    }
    case Kind::Section: {
      BookOrbitFacetPage page;
      return BookOrbitCatalogClient::fetchSectionEntries(step.arg, pageNumber, page);
    }
    case Kind::Books: {
      orbify::mirror::FacetQuery f;
      BookOrbitBookPage page;
      return orbify::mirror::decodeQuery(step.arg, f) &&
             BookOrbitCatalogClient::fetchBooks(fromFacet(f), pageNumber, page);
    }
    case Kind::Detail: {
      BookOrbitBookDetail detail;
      return BookOrbitCatalogClient::fetchBookDetail(strtoll(step.arg.c_str(), nullptr, 10), detail);
    }
  }
  return false;
}

}  // namespace

namespace OrbifyMirror {

void refreshChanged(bool (*cancelled)()) {
  if (requested() || WiFi.status() != WL_CONNECTED || (cancelled && cancelled()) ||
      !OrbifyHeap::roomForRequest("Catalog incremental"))
    return;
  // The pinned catalog has no delta endpoint. One bounded head page, never a
  // full walk.
  OrbifyCache::ScopedMode refresh(orbify::cache::Mode::Refresh);
  BookOrbitBookQuery query;
  query.sort = "recently_updated";
  BookOrbitBookPage page;
  if (BookOrbitCatalogClient::fetchBooks(query, 1, page) && !(cancelled && cancelled())) {
    const auto changed = OrbifyCache::mergeRecent();
    for (int64_t id : changed) {
      if ((cancelled && cancelled()) || !OrbifyHeap::roomForRequest("Changed catalog detail")) break;
      BookOrbitBookDetail detail;
      BookOrbitCatalogClient::fetchBookDetail(id, detail);
    }
  }
}

bool saved() { return loadState().saved; }
uint32_t savedAt() { return loadState().at; }
bool requested() { return Storage.exists(REQUEST_PATH); }

bool quietRestart() { return userRunThisBoot || (Storage.ready() && requested()); }

void request() {
  userRunThisBoot = true;
  if (busy()) return;
  freshRequest();
  writeText(REQUEST_PATH, "1\n");
  LOG_INF(TAG, "Mirror: Full refresh asked for");
}

Due dueNow() {
  // Retain the cache indefinitely. Only request() (a user action) starts a Full
  // refresh.
  return Due::None;
}

// Full refresh belongs to the global worker; sleep sync must never create
// another walker.
bool run(bool (*)(), unsigned long, const Progress*, size_t, bool) { return false; }
int pendingPercent() {
  const auto value = snapshot();
  return value.active && !value.finished ? static_cast<int>(value.percent) : -1;
}
void Walk::begin(const bool userStarted) {
  if (userStarted) request();
  if (!requested()) return;
  viewOnly = false;
  started = true;
  connectionFailed = false;
}
bool Walk::finished() const {
  return started && (connectionFailed || (viewOnly ? plan.finished() : snapshot().finished));
}
unsigned Walk::percent() const { return viewOnly ? plan.percent() : snapshot().percent; }
size_t Walk::failures() const {
  return viewOnly ? plan.failures() + (connectionFailed ? 1 : 0) : snapshot().failures;
}

void Walk::beginView(const orbify::mirror::Step& view, const int page) {
  viewPage = page > 0 ? page : 1;
  end();
  plan = Plan{};
  plan.add(view.kind, view.arg);
  connectionFailed = false;
  viewOnly = true;
  started = true;
  startedAt = millis();
  OrbifyWifi::acquire(OrbifyWifi::Owner::Refresh);
  wifiHeld = true;
  LOG_INF(TAG, "Refresh: queued visible view (%u); browsing continues", static_cast<unsigned>(view.kind));
}

void Walk::end() {
  started = false;
  if (wifiHeld) {
    wifiHeld = false;
    OrbifyWifi::release(OrbifyWifi::Owner::Refresh);
  }
}

void Walk::step() {
  if (!viewOnly || !started || connectionFailed || plan.next() == nullptr) return;
  OrbifyCache::ScopedMode full(orbify::cache::Mode::Full);
  const bool ok = runView(*plan.next(), viewPage);
  plan.advance(!ok);
  LOG_INF(TAG, "Refresh phase: kind=%u request=%u/%u ok=%d",
          static_cast<unsigned>(plan.count(Kind::Root) ? Kind::Root : Kind::Books),
          static_cast<unsigned>(plan.doneCount()), static_cast<unsigned>(plan.total()), ok);
  if (plan.finished() && wifiHeld) {
    wifiHeld = false;
    OrbifyWifi::release(OrbifyWifi::Owner::Refresh);
  }
}

std::string savedLine() {
  const auto current = snapshot();
  if (!current.result.empty() && current.result != "Done") return current.result;
  const auto result = readText("/.crosspoint/orbify/walk.result");
  if (result.find("Stopped at ") == 0) return result;
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
