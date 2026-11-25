// SPDX-License-Identifier: GPL-3.0-or-later
#include "Wifi.h"
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <Logging.h>
#include <mutex>
#include <cstdlib>
#include "network/SavedWifiConnect.h"
namespace OrbifyWifi {
namespace {
orbify::wifi::Holds holds;
std::recursive_mutex mutex;
const char* name(Owner owner) {
  constexpr const char* names[] = {"catalog", "refresh", "sleep sync", "offline miss", "background sync"};
  return names[static_cast<unsigned>(owner)];
}
}
void acquire(Owner owner) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  holds.acquire(owner);
  LOG_INF("ORB", "Wi-Fi hold + %s (%u held)", name(owner), holds.held());
}
void release(Owner owner) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  const bool off = holds.release(owner);
  LOG_INF("ORB", "Wi-Fi hold - %s (%u held)", name(owner), holds.held());
  if (off) SavedWifiConnect::disconnect();
}
#ifdef SIMULATOR
void simulatorIdleOffProbe() {
  if (std::getenv("ORBIFY_SIM_IDLE_OFF_ON_MISS")) SavedWifiConnect::disconnect();
}
#endif

bool allowOff(const char* reason) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  const bool off = holds.requestOff();
  LOG_INF("ORB", "Wi-Fi %s: %s (%u held)", off ? "off" : "off deferred", reason, holds.held());
  return off;
}
}

#endif
