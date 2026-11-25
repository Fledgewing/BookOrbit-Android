// SPDX-License-Identifier: GPL-3.0-or-later
#include "Wifi.h"
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <Logging.h>
#include <Arduino.h>
#include <WiFi.h>
#include "Settings.h"
#include "core/WifiPolicy.h"
#include <mutex>
#include <cstdlib>
#include <atomic>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include "network/SavedWifiConnect.h"
namespace OrbifyWifi {
namespace {
std::recursive_mutex mutex;
orbify::wifi::Holds holds;
orbify::wifi::Policy policy;
bool switchingOff = false;
bool managedRadio = false, currentBrowsing = false;
std::atomic<bool> switching{false};
void offTask(void*) {
  {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if ((managedRadio || policy.forceOff) && policy.off(WiFi.getMode() != WIFI_OFF, holds.held(), false, millis() / 1000, currentBrowsing)) {
      switchingOff = true;
      SavedWifiConnect::disconnect();
      switchingOff = false;
      policy.wifiOff();
      managedRadio = false;
    }
  }
  switching.store(false);
  vTaskDelete(nullptr);
}
void restoreTask(void*) {
  {
    OrbifyWifi::Hold radio(Owner::BackgroundSync);
    OrbifyWifi::connect("book_closed", [] { return false; });
  }
  { std::lock_guard<std::recursive_mutex> lock(mutex); policy.restoreOff = false; }
  switching.store(false);
  vTaskDelete(nullptr);
}
const char* name(Owner owner) {
  constexpr const char* names[] = {"catalog", "refresh", "sleep sync", "offline miss", "background sync"};
  return names[static_cast<unsigned>(owner)];
}
}
void acquire(Owner owner) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (WiFi.getMode() == WIFI_OFF) managedRadio = true;
  policy.acquire(WiFi.getMode() != WIFI_OFF, holds.held(), millis() / 1000);
  holds.acquire(owner);
  LOG_INF("ORB", "Wi-Fi hold + %s (%u held)", name(owner), holds.held());
}
void release(Owner owner) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  holds.release(owner);
  policy.release(holds.held(), millis() / 1000);
  LOG_INF("ORB", "Wi-Fi hold - %s (%u held)", name(owner), holds.held());

}
#ifdef SIMULATOR
void simulatorIdleOffProbe() {
  if (std::getenv("ORBIFY_SIM_IDLE_OFF_ON_MISS")) SavedWifiConnect::disconnect();
}
#endif

bool connect(const char* reason, bool (*stop)()) {
  const auto mode = OrbifySettings::get("wifi_mode");
  if (!orbify::wifi::shouldConnect(mode, reason ? reason : "", false)) return false;
  LOG_INF("ORB", "Wi-Fi up reason=%s mode=%s", reason, mode.c_str());
  return SavedWifiConnect::connect(stop);
}
void tick(bool reading, bool browsing) {
  // Settings reads happen at most once a second; no network work on the main task.
  static unsigned long at = 0;
  if (millis() - at < 1000) return;
  at = millis();
  const auto mode = OrbifySettings::get("wifi_mode");
  const auto idle = OrbifySettings::idleSeconds();
  std::unique_lock<std::recursive_mutex> lock(mutex, std::try_to_lock);
  if (!lock.owns_lock()) return;
  if (mode != policy.mode || idle != policy.idleSeconds) {
    policy.mode = mode; policy.idleSeconds = idle; policy.activity = millis() / 1000;
  }
  currentBrowsing = browsing;
  const bool on = WiFi.getMode() != WIFI_OFF;
  const bool restore = policy.book(reading, on);
  const bool off = (managedRadio || policy.forceOff) && policy.off(on, holds.held(), false, millis() / 1000, browsing);
  if ((off || restore) && !switching.exchange(true)) {
    if (xTaskCreate(restore ? restoreTask : offTask, "orb_wifi", restore ? 8192 : 4096, nullptr, 1, nullptr) != pdPASS)
      switching.store(false);
  }
}
void turnOff(const char* reason, void (*stop)()) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  // Automatic disconnects are requests to release. The same grace/idle policy as
  // Android runs from tick(); it never tears down another flow's Wi-Fi hold.
  if (switchingOff && !holds.held()) { LOG_INF("ORB", "Wi-Fi off: %s (0 held)", reason); stop(); return; }
  holds.requestOff();
  LOG_INF("ORB", "Wi-Fi off %s: %s (%u held); mode=%s", holds.held() ? "deferred" : "scheduled", reason, holds.held(), policy.mode.c_str());
}

}

#else
#include "network/SavedWifiConnect.h"
namespace OrbifyWifi { bool connect(const char*, bool (*stop)()) { return SavedWifiConnect::connect(stop); } }
#endif
