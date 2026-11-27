// SPDX-License-Identifier: GPL-3.0-or-later
#include "RefreshRunner.h"
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <Arduino.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/idf_additions.h>
#include "ResumedWork.h"
#ifndef SIMULATOR
#include <esp_heap_caps.h>
#endif
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <mutex>

#include "CacheStore.h"
#include "BookOrbitHomeStore.h"
#include "BulkCatalog.h"
#include "CopyRefresh.h"
#include "HeapFloor.h"
#include "Mirror.h"
#include "RefreshJournal.h"
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
std::atomic<bool> incrementalRequested{false}, quiet{false};
std::atomic<unsigned long> retryAt{0}, requestCount{0};
std::atomic<TaskHandle_t> workerTask{nullptr};
std::mutex stateMutex;
Snapshot state;
bool write(const char* path, const std::string& text);
ResumedWork attempt("/.crosspoint/orbify/refresh.inflight");
ResumedWork bootAttempt("/.crosspoint/orbify/refresh-boot.inflight");
constexpr const char* CRASHED = "/.crosspoint/orbify/mirror.request.crashed";
constexpr const char* CRASH_MESSAGE = "Refresh stopped after a crash. Run Full refresh to rebuild.";
void showCrash() {
  std::lock_guard<std::mutex> lock(stateMutex);
  state = Snapshot{};
  state.active = true; state.finished = true; state.failures = 1;
  state.result = CRASH_MESSAGE;
}
void quarantine() {
  // Disable every automatic entry point before touching the old checkpoint.
  // Keep the published generation, books, credentials and reading state.
  write(CRASHED, CRASH_MESSAGE);
  attempt.complete();
  Storage.remove(REQUEST);
  Storage.remove(CHECKPOINT);
  Storage.remove("/.crosspoint/orbify-catalog/bulk/stage");
  Storage.remove("/.crosspoint/orbify-catalog/bulk/stage.tmp");
  Storage.remove("/.crosspoint/orbify-catalog/bulk/stage.bak");
  terminalThisBoot.store(true);
  incrementalRequested.store(false);
  showCrash();
  LOG_ERR("ORB", "Full refresh: crash breaker stopped automatic resume; saved catalog and books kept");
}

#ifndef SIMULATOR
TaskHandle_t taskHandle = nullptr;  // owned/reaped only by the main task
void reap() {
  if (taskHandle && eTaskGetState(taskHandle) == eSuspended) {
    vTaskDeleteWithCaps(taskHandle);
    taskHandle = nullptr;
  }
}
#endif
bool write(const char* path, const std::string& text) {
  const std::string tmp = std::string(path) + ".tmp";
  HalFile file;
  if (!Storage.openFileForWrite("ORB", tmp, file)) return false;
  bool ok = file.write(text.data(), text.size()) == text.size() && file.sync();
  file.close();
  if (ok) {
    Storage.remove(path);
    ok = Storage.rename(tmp.c_str(), path);
  }
  return ok;
}
std::string read(const char* path) {
  char text[512]{};Storage.readFileToBuffer(path,text,sizeof(text));return text;
}
bool stop() { return stopping.load() || fresh.load() || OrbifyHeap::starved(); }
void runTask() {
  const unsigned long began = millis();
  // Survives power loss and panics, unlike an in-memory running flag. An ordinary
  // return (including offline, low heap or cancellation) is never a crash.
  const auto start = attempt.begin();
  if (start == ResumedWork::Start::Exhausted) { quarantine(); return; }
  if (start == ResumedWork::Start::StorageError) {
    retryAt.store(millis() + 60000);
    std::lock_guard<std::mutex> lock(stateMutex);
    state.active = requested(); state.paused = true;
    LOG_ERR("ORB", "Full refresh: cannot save worker marker; request retained, retrying later");
    return;
  }
  struct Completed { ~Completed() { attempt.complete(); } } completed;
#ifdef SIMULATOR
  if (std::getenv("ORBIFY_SIM_CRASH_REFRESH")) { std::fflush(nullptr); std::_Exit(86); }
#endif
  workerTask.store(xTaskGetCurrentTaskHandle());
  requestCount.store(0);
  const bool reset = fresh.exchange(false);
  quiet.store(!requested());
  incrementalRequested.store(false);
  if (reset) {
    Storage.remove(CHECKPOINT);
    Storage.remove(RESULT);
  }
  // Retire the previous exhaustive walk's queue, never its published catalog.
  if(Storage.exists("/.crosspoint/orbify/walk")) {
    RefreshJournal retired(true,&stop);
    if(!retired.good()||stop())return;
  }
  RefreshJournal::cleanup(&stop);
  if(stop())return;
  OrbifyCache::clearStorageStop();
  if(!OrbifyCache::roomForReply()) {
    const auto result=stopText(OrbifyCache::storageStop(),0,0);write(RESULT,result);Storage.remove(REQUEST);terminalThisBoot.store(true);
    std::lock_guard<std::mutex> lock(stateMutex);state.active=!quiet.load();state.finished=true;state.failures=1;state.result=result;
    LOG_INF("ORB","%s",result.c_str());return;
  }
  {
    OrbifyWifi::Hold radio(OrbifyWifi::Owner::Refresh);
    if (!OrbifyWifi::connect("refresh", &stop)) {
      std::lock_guard<std::mutex> lock(stateMutex); state.active = !quiet.load(); state.paused = true;
      retryAt.store(millis()+60000); return;
    }
    OrbifyCache::ScopedMode full(orbify::cache::Mode::Full);
    BookOrbitCatalogClient::Session session;
    const bool ok = OrbifyBulk::refresh(reset,&stop,[](unsigned p) {
      std::lock_guard<std::mutex> lock(stateMutex);
      state.active = !quiet.load(); state.percent = std::max(state.percent,p); state.paused = false;
    }, !quiet.load());
    if(ok) {
      // A normal refresh can repair a quarantined catalog too. Retire the
      // durable warning only after the replacement catalog is published.
      if (Storage.exists(CRASHED)) {
        Storage.remove(CRASHED);
        Storage.remove(RESULT);
        std::lock_guard<std::mutex> lock(stateMutex);
        state = Snapshot{};
      }
      BookOrbitHomeStore::markSynced();
      if (!quiet.load()) {
      const auto now=time(nullptr);
      write("/.crosspoint/orbify/mirror.state",std::to_string(now>1700000000?now:0)+"\t"+OrbifyCopyRefresh::libraryVersion()+"\n");
      write(RESULT,"Done");Storage.remove(REQUEST);terminalThisBoot.store(true);
      LOG_INF("ORB","Full refresh: Done");LOG_INF("ORB","Mirror: saved for offline");
      std::lock_guard<std::mutex> lock(stateMutex);state.active=true;state.finished=true;state.percent=100;state.result="Done";
      } else {terminalThisBoot.store(true);}
    } else {
      const auto terminal=OrbifyCache::storageStop();
      if(terminal!=Stop::None) {
        const auto result=stopText(terminal,requestCount.load(),requestCount.load());write(RESULT,result);Storage.remove(REQUEST);terminalThisBoot.store(true);
        LOG_INF("ORB","%s",result.c_str());
        std::lock_guard<std::mutex> lock(stateMutex);state.finished=true;state.result=result;state.failures=1;
      } else {
        if(OrbifyHeap::starved()) LOG_INF("ORB","Full refresh: waiting for heap");
        std::lock_guard<std::mutex> lock(stateMutex);state.paused=true;retryAt.store(millis()+60000);
      }
    }
    LOG_INF("ORB","Full refresh worker: ok=%d requests=%lu elapsedMs=%lu",ok,requestCount.load(),millis()-began);
#ifdef SIMULATOR
    if (std::getenv("ORBIFY_SIM_QUIT_BULK_DONE")) {attempt.complete();std::fflush(nullptr);std::_Exit(ok ? 0 : 1); }
#endif
  }
  workerTask.store(nullptr);
}
void task(void*) {
  runTask();
  workerTask.store(nullptr);
  running.store(false);  // leave this scope first: FreeRTOS deletion does not unwind C++
                         // locals
#ifdef SIMULATOR
  vTaskDelete(nullptr);
#else
  // The main task deletes this suspended task with the matching caps API. It
  // never frees a PSRAM stack still executing on the other core.
  vTaskSuspend(nullptr);
#endif
}
}  // namespace
void bootBegin() {
  // Before any saved catalog is decoded or the first activity is selected.
  // A refresh can also leave a published cache that fails during setup, before
  // service() has a chance to see the worker's in-flight marker.
  if (!requested() && !Storage.exists(CRASHED) && !attempt.exhausted() &&
      !Storage.exists("/.crosspoint/orbify/refresh.inflight")) return;
  const auto start = bootAttempt.begin();
  if (start == ResumedWork::Start::StorageError) {
    LOG_ERR("ORB", "Full refresh: cannot save boot marker; request and saved catalog kept");
    return;
  }
  if (start == ResumedWork::Start::Exhausted) {
    // An old warning is already quarantined; do not repeat that transition.
    // Still protect setup if the retained catalog itself later fails to load.
    if (!Storage.exists(CRASHED) || requested()) quarantine();
    // Disable the suspect cache by moving only its pointer, never the books or
    // the catalog generation itself. Do not decode any of it during recovery.
    constexpr const char* active = "/.crosspoint/orbify-catalog/bulk/active";
    const bool hadPointer = Storage.exists(active) || Storage.exists("/.crosspoint/orbify-catalog/bulk/active.bak");
    if (Storage.exists(active)) {
      Storage.remove("/.crosspoint/orbify-catalog/bulk/active.crashed");
      Storage.rename(active, "/.crosspoint/orbify-catalog/bulk/active.crashed");
    }
    Storage.remove("/.crosspoint/orbify-catalog/bulk/active.bak");
    if (hadPointer) LOG_ERR("ORB", "Full refresh: early-boot breaker disabled saved catalog pointer");
    return;
  }
#ifdef SIMULATOR
  if (std::getenv("ORBIFY_SIM_CRASH_REFRESH_BOOT")) { std::fflush(nullptr); std::_Exit(88); }
#endif
}
void bootComplete() {
  // Also retires an exhausted marker on the boot that quarantined the job.
  bootAttempt.complete();
  if (Storage.exists(CRASHED) && !requested()) attempt.complete();
}
Snapshot snapshot() {
  std::lock_guard<std::mutex> lock(stateMutex);
  return state;
}
bool busy() { return running.load(); }
void countCatalogRequest() {
  if (xTaskGetCurrentTaskHandle() == workerTask.load()) ++requestCount;
}
void catalogProgress(size_t done, size_t total, size_t books) {
  std::lock_guard<std::mutex> lock(stateMutex);
  state.done=done;state.total=total;state.books=books;
}
bool catalogTask() { return xTaskGetCurrentTaskHandle() == workerTask.load(); }
bool cancelCatalogRequest() { return xTaskGetCurrentTaskHandle() == workerTask.load() && stop(); }

bool recoveryPending() { return Storage.exists(CRASHED); }
bool requestIncremental() {
  // Own normal refresh after quarantine even when boot recovery disabled the
  // active pointer. The bulk catalog starts a new generation when none exists.
  const bool recovering = Storage.exists(CRASHED);
  if (!recovering && !OrbifyBulk::active()) return false;
  if (running.load() || requested() || WiFi.status()!=WL_CONNECTED) return true;
  if (recovering) {
    // Home refresh restarts when its foreground work ends. Persist the repair
    // so it can finish after that restart, retaining the warning until success.
    if (!write(REQUEST, "1\n")) return true;
    attempt.complete();
    std::lock_guard<std::mutex> lock(stateMutex);
    state = Snapshot{};
    state.active = true;
  }
  incrementalRequested.store(true);terminalThisBoot.store(false);retryAt.store(0);sleeping.store(false);
  return true;
}
void freshRequest() {
  attempt.complete();
  bootAttempt.complete();
  Storage.remove(CRASHED);
  fresh.store(true);
  terminalThisBoot.store(false);
  retryAt.store(0);
  sleeping.store(false);
  std::lock_guard<std::mutex> lock(stateMutex);
  state = Snapshot{};
  state.active = true;
}
void service() {
#ifndef SIMULATOR
  reap();
  if (taskHandle) return;
#endif
  static bool recoveryChecked = false;
  if (!recoveryChecked && Storage.ready()) {
    recoveryChecked = true;
    if (Storage.exists(CRASHED)) {
      if (!requested() && !incrementalRequested.load() && !fresh.load()) {
        showCrash();
        terminalThisBoot.store(true);
        return;
      }
    } else if (attempt.exhausted()) {
      quarantine();
      return;
    }
  }
  const auto retry = retryAt.load();
  if (sleeping.load() || terminalThisBoot.load() || running.load() || !Storage.ready() ||
      (retry && static_cast<int32_t>(millis() - retry) < 0))
    return;
  static unsigned long checkedAt = 0;
  if (!fresh.load() && checkedAt && millis() - checkedAt < 1000) return;
  checkedAt = millis();
  if (!requested() && !incrementalRequested.load()) {
    static bool loadedResult = false;
    if (!loadedResult) {
      loadedResult = true;
      const auto result = read(RESULT);
      std::lock_guard<std::mutex> lock(stateMutex);
      if (!state.active && result.find("Stopped at ") == 0) {
        state.result = result;
        state.finished = true;
        state.active = true;
      }
    }
    return;
  }
  if (incrementalRequested.load() && !requested() && WiFi.status()!=WL_CONNECTED) return;
  if (!OrbifyHeap::roomForRequest("Full refresh worker")) return;
  running.store(true);
  stopping.store(false);
  // This task can reach flash writes (Wi-Fi PHY / Tailscale peer NVS).
  // Its stack must remain accessible with the flash/PSRAM cache disabled.
  // Library-sized JSON and indexes still use the separate PSRAM arena.
  const auto created = xTaskCreateWithCaps(task, "orb_catalog", 16 * 1024, nullptr, 1,
#ifdef SIMULATOR
                                           nullptr,
#else
                                           &taskHandle,
#endif
                                           MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (created != pdPASS) {
    running.store(false);
    retryAt.store(millis() + 60000);
    LOG_ERR("ORB", "Full refresh: couldn't start worker; request retained");
  }
}
void credentialsChanging() {
  stopForSleep();
  // Quiesce the task before the settings callback mutates shared credentials.
  // An old account's queued inventory is never resumed on a different account.
  attempt.complete();
  bootAttempt.complete();
  Storage.remove(CRASHED);
  Storage.remove(REQUEST);
  Storage.remove(CHECKPOINT);
  Storage.remove(RESULT);
  Storage.remove("/.crosspoint/orbify/mirror.state");
  terminalThisBoot.store(true);incrementalRequested.store(false);
  std::lock_guard<std::mutex> lock(stateMutex);
  state = Snapshot{};
}
void beforeRestart() {
  // Orderly software transitions are not crashes. Drain before the restart's
  // render lock or filesystem flush; let the scheduler resume if it is cancelled.
  stopForSleep();
  stopping.store(false);
  sleeping.store(false);
}
void stopForSleep() {
  sleeping.store(true);
  stopping.store(true);
  // Never shut down the SD filesystem underneath a TLS transfer or queue
  // checkpoint.
  while (running.load()) delay(20);
#ifndef SIMULATOR
  while (taskHandle) {
    reap();
    if (taskHandle) delay(1);
  }
#endif
  bootComplete();
}
}  // namespace OrbifyMirror
#endif
