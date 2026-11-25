// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of Orbify's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#include "BookOrbitBackgroundSync.h"
#include "Wifi.h"
#include "SleepScreen.h"
#include "OrbiSmartSync.h"
#include "core/OrbiSmartState.h"
#include <HalPowerManager.h>
extern HalPowerManager powerManager;

#if CROSSINK_TAILNET_BACKGROUND_SYNC

#include <Arduino.h>
#include <Epub.h>
#include <I18n.h>
#include <Logging.h>
#include <Memory.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

#include "BookOrbitCredentialStore.h"
#include "activities/reader/bookorbit/BookOrbitSyncActivity.h"
#include "ProgressMapper.h"
#include "WifiCredentialStore.h"
#include "network/SavedWifiConnect.h"

extern GfxRenderer renderer;
extern MappedInputManager mappedInputManager;

namespace BookOrbitBackgroundSync {
namespace {
// The sync runs where the loop task would run it, so it gets the loop task's stack.
constexpr uint32_t TASK_STACK_BYTES = 16 * 1024;
// readerClosed() waits this long for a run to reach a step it can stop at; a request in
// flight ends on its own timeout well before.
constexpr unsigned long STOP_WAIT_MS = 30000;

struct Tracker {
  std::string path;
  int spine = -1;
  int page = -1;
  int syncedSpine = -1;  // the position the last run started from
  int syncedPage = -1;
  unsigned long sinceMs = 0;
  unsigned long turnMs = 0;
  bool opening = true;
  uint32_t pages = 0;
  uint32_t chapters = 0;
};
Tracker tracker;

struct Job {
  std::string epubPath;
  Position position;
  const char* trigger;
};

std::atomic<bool> running{false};
std::atomic<bool> stopRequested{false};
std::atomic<bool> lastRunFailed{false};

bool shouldStop() { return stopRequested.load(); }

size_t freeInternal() { return heap_caps_get_free_size(MALLOC_CAP_INTERNAL); }

void resetCounts(const unsigned long nowMs) {
  tracker.sinceMs = nowMs;
  tracker.pages = 0;
  tracker.chapters = 0;
}

// Everything heavy runs here, off the reader's task: the book's own copy, the position in
// KOReader form, WiFi (and with it Tailscale), the TLS session.
const char* runJob(const Job& job, size_t& lowest) {
  const auto sample = [&lowest] {
    const size_t now = freeInternal();
    if (now < lowest) lowest = now;
  };

  auto epub = std::make_shared<Epub>(job.epubPath, "/.crosspoint");
  epub->setupCacheDir();
  if (!epub->load(false, true)) return "failed: book";
  sample();

  CrossPointPosition local = {job.position.spineIndex, job.position.page, job.position.pageCount};
  if (job.position.hasParagraph) {
    local.paragraphIndex = job.position.paragraphIndex;
    local.hasParagraphIndex = true;
  }
  if (job.position.hasListItem) {
    local.liIndex = job.position.listItemIndex;
    local.hasLiIndex = true;
  }
  KOReaderPosition localKo = ProgressMapper::toKOReader(epub, local);
  if (shouldStop()) return "aborted: reader closing";

  OrbifyWifi::Hold radio(OrbifyWifi::Owner::BackgroundSync);
  const bool wasConnected = WiFi.status() == WL_CONNECTED;
  if (!SavedWifiConnect::connect(&shouldStop)) {
    if (!wasConnected) SavedWifiConnect::disconnect();
    return shouldStop() ? "aborted: reader closing" : "skipped: network";
  }
  sample();

  const char* outcome = "failed: memory";
  auto activity = makeUniqueNoThrow<BookOrbitSyncActivity>(
      renderer, mappedInputManager, job.epubPath, job.position.spineIndex, job.position.page,
      job.position.pageCount, std::move(localKo), std::string(),
      job.position.hasParagraph ? std::optional<uint16_t>(job.position.paragraphIndex) : std::nullopt);
  if (activity) {
    outcome = activity->runInBackground(std::move(epub), &shouldStop);
    sample();
    activity.reset();
  }
#if CROSSINK_TAILNET_ORBIFY_SLEEP
  // The radio is already up: a small cancellable top-up, with no drawing on the reader.
  if (!shouldStop() && WiFi.status() == WL_CONNECTED) OrbifySleep::topUp(job.epubPath, &shouldStop, 1500);
#endif
  // Off again whatever happened; MicroLink stops before the driver does (esp_wifi_stop wrap).
  if (!wasConnected) SavedWifiConnect::disconnect();
  return outcome;
}

void taskMain(void* arg) {
  std::unique_ptr<Job> job(static_cast<Job*>(arg));
  const unsigned long startMs = millis();
  const size_t lowWaterBefore = heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
  size_t lowest = freeInternal();
  const char* outcome = runJob(*job, lowest);
  // The heap's all-time low only moves when this run went below it: then that is the run's low.
  const size_t lowWaterAfter = heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
  if (lowWaterAfter < lowWaterBefore && lowWaterAfter < lowest) lowest = lowWaterAfter;
  lastRunFailed.store(strncmp(outcome, "uploaded", 8) != 0 && strncmp(outcome, "already", 7) != 0 &&
                      strncmp(outcome, "deferred", 8) != 0);
  LOG_INF("BOBG", "Background sync: trigger=%s outcome=%s duration=%lums lowestFreeInternal=%u stackUnused=%u",
          job->trigger, outcome, millis() - startMs, static_cast<unsigned>(lowest),
          static_cast<unsigned>(uxTaskGetStackHighWaterMark(nullptr)));
  job.reset();
  running.store(false);
  vTaskDelete(nullptr);
}
}  // namespace

void intervalLabel(const uint8_t interval, char* out, const unsigned outSize) {
  switch (interval) {
    case MINUTES_10:
    case MINUTES_15:
    case MINUTES_30:
    case MINUTES_60: {
      static constexpr int MINUTES[] = {10, 15, 30, 60};
      snprintf(out, outSize, tr(STR_EVERY_N_MINUTES), MINUTES[interval - MINUTES_10]);
      return;
    }
    case PAGES_25:
    case PAGES_50:
    case PAGES_100: {
      static constexpr int PAGES[] = {25, 50, 100};
      snprintf(out, outSize, tr(STR_EVERY_N_PAGES), PAGES[interval - PAGES_25]);
      return;
    }
    case CHAPTERS_1:
      snprintf(out, outSize, "%s", tr(STR_EVERY_CHAPTER));
      return;
    case CHAPTERS_2:
      snprintf(out, outSize, tr(STR_EVERY_N_CHAPTERS), 2);
      return;
    default:
      snprintf(out, outSize, "%s", tr(STR_OFF));
      return;
  }
}

bool enabled() {
  const uint8_t interval = BOOKORBIT_STORE.getBackgroundSync();
  return (OrbiSmartSync::enabled() || (interval != OFF && interval < INTERVAL_COUNT)) &&
         BOOKORBIT_STORE.getSyncBehavior() == BookOrbitSyncBehavior::SMART && BOOKORBIT_STORE.hasCredentials() &&
         WIFI_STORE.getCredentialCount() > 0;
}

const char* observe(const char* epubPath, const int spineIndex, const int page, const unsigned long nowMs) {
  if (tracker.path != epubPath) {
    // A book just opened: what it opened at is where its last sync (on open) left it.
    tracker = Tracker{};
    tracker.path = epubPath;
    tracker.spine = tracker.syncedSpine = spineIndex;
    tracker.page = tracker.syncedPage = page;
    resetCounts(nowMs);
    tracker.turnMs = nowMs;
    return nullptr;
  }
  if (spineIndex != tracker.spine || page != tracker.page) {
    if (spineIndex != tracker.spine) tracker.chapters++;
    tracker.pages++;
    tracker.turnMs = nowMs;
    tracker.spine = spineIndex;
    tracker.page = page;
  }
  if (running.load()) return nullptr;
  if (OrbiSmartSync::enabled()) {
    if (powerManager.getBatteryPercentage() < 15) return nullptr;
    if (tracker.opening) {
      tracker.opening = false;
      if (OrbiSmartSync::checkOnOpen(epubPath)) return "wake";
    }
    if (orbify::orbismart::pauseDue(nowMs - tracker.turnMs, tracker.pages, spineIndex, page, tracker.syncedSpine, tracker.syncedPage)) return "pause";
    return nullptr;
  }
  if (lastRunFailed.exchange(false)) {
    // Not reached last time: the next trigger tries again even from the same page.
    tracker.syncedSpine = -1;
    tracker.syncedPage = -1;
  }
  const uint8_t interval = BOOKORBIT_STORE.getBackgroundSync();
  if (!due(interval, nowMs - tracker.sinceMs, tracker.pages, tracker.chapters)) return nullptr;
  const char* trigger = interval <= MINUTES_60 ? "time" : interval <= PAGES_100 ? "pages" : "chapter";
  if (spineIndex == tracker.syncedSpine && page == tracker.syncedPage) {
    LOG_INF("BOBG", "Background sync: trigger=%s outcome=skipped: no change duration=0ms", trigger);
    resetCounts(nowMs);
    return nullptr;
  }
  return trigger;
}

bool start(const char* epubPath, const Position& position, const char* trigger) {
  if (running.exchange(true)) return false;
  stopRequested.store(false);
  tracker.syncedSpine = position.spineIndex;
  tracker.syncedPage = position.page;
  resetCounts(millis());
  auto* job = new (std::nothrow) Job{epubPath, position, trigger};
  if (!job || xTaskCreate(&taskMain, "bo_bgsync", TASK_STACK_BYTES, job, 1, nullptr) != pdPASS) {
    delete job;
    LOG_ERR("BOBG", "Background sync: trigger=%s outcome=failed: no task (freeInternal=%u)", trigger,
            static_cast<unsigned>(freeInternal()));
    running.store(false);
    return false;
  }
  return true;
}

void readerClosed() {
  tracker = Tracker{};
  if (!running.load()) return;
  stopRequested.store(true);
  LOG_INF("BOBG", "Reader closing: waiting for the background sync to stop");
  const unsigned long start = millis();
  while (running.load()) {
    if (millis() - start >= STOP_WAIT_MS) {
      LOG_ERR("BOBG", "Background sync still running after %lums", millis() - start);
      return;
    }
    delay(20);
  }
  LOG_INF("BOBG", "Background sync stopped (%lums)", millis() - start);
}

}  // namespace BookOrbitBackgroundSync

#endif  // CROSSINK_TAILNET_BACKGROUND_SYNC
