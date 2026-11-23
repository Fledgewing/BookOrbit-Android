#include "HeapFloor.h"

#include <Arduino.h>
#include <Logging.h>

namespace OrbifyHeap {

bool roomForRequest(const char* what) {
  const uint32_t free = ESP.getFreeHeap();
  if (free >= KEPT_CONNECTION_MIN_FREE) return true;
  LOG_INF("ORB", "%s: waiting for heap (free=%u, needs %u, maxAlloc=%u); next sync", what, static_cast<unsigned>(free),
          static_cast<unsigned>(KEPT_CONNECTION_MIN_FREE), static_cast<unsigned>(ESP.getMaxAllocHeap()));
  return false;
}

bool starved() {
  static bool logged = false;
  const uint32_t free = ESP.getFreeHeap();
  if (free >= TRANSFER_MIN_FREE) return false;
  if (!logged) {
    logged = true;
    LOG_ERR("ORB", "Transfer stopped: heap starved (free=%u, floor %u, maxAlloc=%u)", static_cast<unsigned>(free),
            static_cast<unsigned>(TRANSFER_MIN_FREE), static_cast<unsigned>(ESP.getMaxAllocHeap()));
  }
  return true;
}

}  // namespace OrbifyHeap
