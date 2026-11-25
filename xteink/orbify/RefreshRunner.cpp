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
#include <esp_heap_caps.h>
#include <freertos/idf_additions.h>
#endif
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <mutex>

#include "CacheStore.h"
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
    if (std::getenv("ORBIFY_SIM_QUIT_BULK_DONE")) {std::fflush(nullptr);std::_Exit(ok ? 0 : 1); }
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
Snapshot snapshot() {
  std::lock_guard<std::mutex> lock(stateMutex);
  return state;
}
bool busy() { return running.load() && !snapshot().finished; }
void countCatalogRequest() {
  if (xTaskGetCurrentTaskHandle() == workerTask.load()) ++requestCount;
}
bool catalogTask() { return xTaskGetCurrentTaskHandle() == workerTask.load(); }
bool cancelCatalogRequest() { return xTaskGetCurrentTaskHandle() == workerTask.load() && stop(); }

void requestIncremental() {
  if (!OrbifyBulk::active() || running.load() || requested() || WiFi.status()!=WL_CONNECTED) return;
  incrementalRequested.store(true);terminalThisBoot.store(false);retryAt.store(0);sleeping.store(false);
}
void freshRequest() {
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
#ifdef SIMULATOR
  const auto created = xTaskCreate(task, "orb_catalog", 16 * 1024, nullptr, 1, nullptr);
#else
  const auto created = xTaskCreateWithCaps(task, "orb_catalog", 16 * 1024, nullptr, 1, &taskHandle,
                                           MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#endif
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
  Storage.remove(REQUEST);
  Storage.remove(CHECKPOINT);
  Storage.remove(RESULT);
  Storage.remove("/.crosspoint/orbify/mirror.state");
  terminalThisBoot.store(true);incrementalRequested.store(false);
  std::lock_guard<std::mutex> lock(stateMutex);
  state = Snapshot{};
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
}
}  // namespace OrbifyMirror
#endif
