// SPDX-License-Identifier: GPL-3.0-or-later
#include "RefreshRunner.h"
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <Arduino.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#ifndef SIMULATOR
#include <freertos/idf_additions.h>
#include <esp_heap_caps.h>
#endif
#include <atomic>
#include <ctime>
#include <mutex>
#include "Mirror.h"
#include "RefreshJournal.h"
#include "CacheStore.h"
#include "CopyRefresh.h"
#include "HeapFloor.h"
#include "Wifi.h"
#include "network/BookOrbitCatalogClient.h"
#include "network/SavedWifiConnect.h"
namespace OrbifyMirror {
namespace {
using namespace orbify::mirror;
constexpr const char* CHECKPOINT = "/.crosspoint/orbify/walk.state";
constexpr const char* RESULT = "/.crosspoint/orbify/walk.result";
constexpr const char* REQUEST = "/.crosspoint/orbify/mirror.request";
std::atomic<bool> running{false}, stopping{false}, fresh{false}, sleeping{false}, terminalThisBoot{false};
std::atomic<unsigned long> retryAt{0}, requestCount{0};
std::atomic<TaskHandle_t> workerTask{nullptr};
std::mutex stateMutex;
Snapshot state;
#ifndef SIMULATOR
TaskHandle_t taskHandle = nullptr; // owned/reaped only by the main task
void reap() {
  if (taskHandle && eTaskGetState(taskHandle) == eSuspended) {
    vTaskDeleteWithCaps(taskHandle); taskHandle = nullptr;
  }
}
#endif
void publish(const RefreshPlan& plan, bool finished = false, bool paused = false, const std::string& result = "") {
  std::lock_guard<std::mutex> lock(stateMutex);
  state = {true, finished, paused, plan.percent(), plan.doneCount(), plan.total(), plan.errors(), result};
}
bool write(const char* path, const std::string& text) {
  const std::string tmp = std::string(path) + ".tmp";
  HalFile file;
  if (!Storage.openFileForWrite("ORB", tmp, file)) return false;
  bool ok = file.write(text.data(), text.size()) == text.size() && file.sync();
  file.close();
  if (ok) { Storage.remove(path); ok = Storage.rename(tmp.c_str(), path); }
  return ok;
}
std::string read(const char* path) {
  char text[512]{};
  Storage.readFileToBuffer(path, text, sizeof(text));
  return text;
}
bool stop() { return stopping.load() || OrbifyHeap::starved(); }
FacetQuery facet(const BookOrbitBookQuery& q) {
  return {q.sort, q.order, q.readStatus, q.shelf, q.query, q.author, q.seriesId, q.series, q.collectionId, q.smartScopeId, q.libraryId};
}
BookOrbitBookQuery query(const FacetQuery& f) {
  BookOrbitBookQuery q;
  q.sort=f.sort; q.order=f.order; q.readStatus=f.readStatus; q.shelf=f.shelf;
  q.query=f.query; q.author=f.author; q.seriesId=f.seriesId; q.series=f.series;
  q.collectionId=f.collectionId; q.smartScopeId=f.smartScopeId; q.libraryId=f.libraryId;
  return q;
}
bool step(const Step& current, int pageNumber, RefreshPlan& plan) {
  switch (current.kind) {
    case Kind::Root: {
      std::vector<BookOrbitCatalogSection> sections;
      if (!BookOrbitCatalogClient::fetchRootSections(sections)) return false;
      BookOrbitCatalogCounts counts;
      if (!stop() && OrbifyHeap::roomForRequest("Full refresh counts")) BookOrbitCatalogClient::fetchCatalogCounts(counts);
      for (const auto& section : sections) {
        if (isFacetSection(section.id)) plan.add(Kind::Section, section.id);
        else plan.add(Kind::Books, encodeQuery(facet(BookOrbitCatalogClient::sectionBookQuery(section.id))));
      }
      plan.add(Kind::Books, encodeQuery(facet(BookOrbitCatalogClient::sectionBookQuery(BookOrbitCatalogClient::WANT_TO_READ_SHELF))));
      return true;
    }
    case Kind::Section: {
      BookOrbitFacetPage page;
      if (!BookOrbitCatalogClient::fetchSectionEntries(current.arg, pageNumber, page)) return false;
      // Read total/size on the first page and enqueue every remaining page up front.
      // hasNext also supports sections which send their entire list without totals.
      if (pageNumber == 1 && page.total >= 0 && page.pageSize > 0) {
        const int pages = std::max(1, (page.total + page.pageSize - 1) / page.pageSize);
        for (int n = 2; n <= pages; ++n) plan.add(Kind::Section, current.arg, n);
      } else if ((page.total < 0 || page.pageSize <= 0) && page.hasNext) {
        plan.add(Kind::Section, current.arg, pageNumber + 1);
      }
      for (const auto& entry : page.entries)
        plan.add(Kind::Books, encodeQuery(facetQuery(current.arg, entry.id, entry.seriesId)));
      return true;
    }
    case Kind::Books: {
      FacetQuery f;
      if (!decodeQuery(current.arg, f)) return false;
      BookOrbitBookPage page;
      if (!BookOrbitCatalogClient::fetchBooks(query(f), pageNumber, page)) return false;
      if (pageNumber == 1) {
        // Canonical all-books includes every downloadable catalog book. Its total
        // fixes the number of distinct detail jobs before the data pass starts.
        if (f.query.empty() && f.author.empty() && f.series.empty() && f.seriesId.empty() &&
            f.collectionId.empty() && f.smartScopeId.empty() && f.libraryId.empty() && f.readStatus.empty() && f.shelf.empty())
          plan.expectDetails(std::max(0, page.total));
        const int size = std::max(1, page.pageSize);
        const int pages = std::max(1, (page.total + size - 1) / size);
        for (int n = 2; n <= pages; ++n) plan.add(Kind::Books, current.arg, n, true);
      }
      for (const auto& book : page.books) if (book.id > 0) plan.add(Kind::Detail, std::to_string(book.id));
      return true;
    }
    case Kind::Detail: {
      BookOrbitBookDetail detail;
      return BookOrbitCatalogClient::fetchBookDetail(strtoll(current.arg.c_str(), nullptr, 10), detail);
    }
  }
  return false;
}
void runTask() {
  const unsigned long began = millis();
  workerTask.store(xTaskGetCurrentTaskHandle());
  requestCount.store(0);
  const bool reset = fresh.exchange(false);
  if (reset) { Storage.remove(CHECKPOINT); Storage.remove(RESULT); }
  RefreshJournal journal(reset);
  RefreshPlan plan(journal);
  const std::string checkpoint = read(CHECKPOINT);
  bool valid = journal.good() && (checkpoint.empty() || plan.restore(checkpoint));
  if (!journal.count(0)) plan.add(Kind::Root, "");
  OrbifyCache::clearStorageStop();
  unsigned long requests = 0, pagesSaved = 0, noteAt = began;
  Stop terminal = valid ? Stop::None : Stop::Io;
  publish(plan);
  {
    OrbifyWifi::Hold radio(OrbifyWifi::Owner::Refresh);
    if (terminal == Stop::None && !OrbifyWifi::connect("refresh", &stop)) publish(plan, false, true);
    else if (terminal == Stop::None) {
      // Per-task modes and serialized network requests let cached foreground reads
      // proceed independently. No render operation runs on this task.
      OrbifyCache::ScopedMode full(orbify::cache::Mode::Full);
      BookOrbitCatalogClient::Session session;
      Step current; int page;
      while (!stop() && WiFi.status() == WL_CONNECTED && plan.next(current, page)) {
        if (!OrbifyHeap::roomForRequest("Full refresh")) { delay(100); continue; }
        OrbifyCache::setPlanBytes(journal.bytes());
        if (!OrbifyCache::roomForReply()) { terminal = OrbifyCache::storageStop(); break; }
        const bool ok = step(current, page, plan);
        requests = requestCount.load();
        if (ok && current.kind != Kind::Detail) ++pagesSaved;
        terminal = OrbifyCache::storageStop();
        if (!journal.good()) terminal = Stop::Io;
        if (terminal != Stop::None) break;
        plan.advance(!ok);
        if (!write(CHECKPOINT, plan.checkpoint())) { terminal = Stop::Io; break; }
        publish(plan);
        if (millis() - noteAt >= 10000) {
          noteAt = millis();
          const auto elapsed = std::max<unsigned long>(1, millis() - began);
          const double rate = requests * 1000.0 / elapsed;
          LOG_INF("ORB", "Full refresh: pagesSaved=%lu itemsSaved=%u/%u bytesOnSD=%llu elapsed=%lums requests/s=%.2f estimateRemaining=%.0fs",
            pagesSaved, static_cast<unsigned>(plan.doneCount() - plan.errors()), static_cast<unsigned>(plan.total()),
            static_cast<unsigned long long>(OrbifyCache::bytesOnSd()), elapsed, rate,
            rate > 0 ? (plan.total() - plan.doneCount()) / rate : 0);
        }
        delay(10); // lend the CPU after each page; input stays on the main task
      }
    }
    if (!journal.good()) terminal = Stop::Io;
    if (terminal != Stop::None) {
      const auto result = stopText(terminal, plan.doneCount() - plan.errors(), plan.total());
      write(RESULT, result);
      terminalThisBoot.store(true);
      Storage.remove(REQUEST); // terminal: no sleep/wake/main-loop retry
      publish(plan, true, false, result);
      LOG_INF("ORB", "%s", result.c_str());
    } else if (plan.finished() && valid && WiFi.status() == WL_CONNECTED && !stop()) {
      const auto now = time(nullptr);
      write("/.crosspoint/orbify/mirror.state", std::to_string(now > 1700000000 ? now : 0) + "\t" + OrbifyCopyRefresh::libraryVersion() + "\n");
      terminalThisBoot.store(true);
      Storage.remove(REQUEST);
      const auto result = plan.errors() ? "Done with " + std::to_string(plan.errors()) + " errors" : "Done";
      write(RESULT, result);
      publish(plan, true, false, result);
      LOG_INF("ORB", "Mirror: saved for offline: %u requests (%u failed)", static_cast<unsigned>(plan.doneCount()), static_cast<unsigned>(plan.errors()));
      LOG_INF("ORB", "Full refresh: %s pagesSaved=%lu saved=%u/%u bytesOnSD=%llu elapsed=%lums requests/s=%.2f estimate10300books=%.0fs",
        result.c_str(), pagesSaved, static_cast<unsigned>(plan.doneCount() - plan.errors()), static_cast<unsigned>(plan.total()),
        static_cast<unsigned long long>(OrbifyCache::bytesOnSd()), millis() - began,
        requests * 1000.0 / std::max<unsigned long>(1, millis() - began),
        plan.bookCount() && requests ? plan.total() * 10300.0 / plan.bookCount() * (millis() - began) / (requests * 1000.0) : 0);
    } else {
      publish(plan, false, true);
      retryAt.store(millis() + 60000); // a failed join is paced, never a tight retry loop
    }
  }
  workerTask.store(nullptr);
  running.store(false);
}
void task(void*) {
  runTask(); // leave this scope first: FreeRTOS deletion does not unwind C++ locals
#ifdef SIMULATOR
  vTaskDelete(nullptr);
#else
  // The main task deletes this suspended task with the matching caps API. It
  // never frees a PSRAM stack still executing on the other core.
  vTaskSuspend(nullptr);
#endif
}
}
Snapshot snapshot() { std::lock_guard<std::mutex> lock(stateMutex); return state; }
bool busy() { return running.load(); }
void countCatalogRequest() { if (xTaskGetCurrentTaskHandle() == workerTask.load()) ++requestCount; }
void freshRequest() {
  fresh.store(true); terminalThisBoot.store(false); retryAt.store(0); sleeping.store(false);
  std::lock_guard<std::mutex> lock(stateMutex); state = Snapshot{}; state.active = true;
}
void service() {
#ifndef SIMULATOR
  reap();
  if (taskHandle) return;
#endif
  const auto retry = retryAt.load();
  if (sleeping.load() || terminalThisBoot.load() || running.load() || !Storage.ready() ||
      (retry && static_cast<int32_t>(millis() - retry) < 0)) return;
  static unsigned long checkedAt = 0;
  if (!fresh.load() && checkedAt && millis() - checkedAt < 1000) return;
  checkedAt = millis();
  if (!requested()) {
    static bool loadedResult = false;
    if (!loadedResult) {
      loadedResult = true;
      const auto result = read(RESULT);
      std::lock_guard<std::mutex> lock(stateMutex);
      if (!state.active && result.find("Stopped at ") == 0) { state.result = result; state.finished = true; state.active = true; }
    }
    return;
  }
  if (!OrbifyHeap::roomForRequest("Full refresh worker")) return;
  running.store(true); stopping.store(false);
#ifdef SIMULATOR
  const auto created = xTaskCreate(task, "orb_catalog", 16 * 1024, nullptr, 1, nullptr);
#else
  const auto created = xTaskCreateWithCaps(task, "orb_catalog", 16 * 1024, nullptr, 1, &taskHandle,
      MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#endif
  if (created != pdPASS) {
    running.store(false); retryAt.store(millis() + 60000);
    LOG_ERR("ORB", "Full refresh: couldn't start worker; request retained");
  }
}
void stopForSleep() {
  sleeping.store(true); stopping.store(true);
  // Never shut down the SD filesystem underneath a TLS transfer or queue checkpoint.
  while (running.load()) delay(20);
#ifndef SIMULATOR
  while (taskHandle) { reap(); if (taskHandle) delay(1); }
#endif
}
}
#endif
