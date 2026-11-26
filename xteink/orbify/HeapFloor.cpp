#include "HeapFloor.h"
#include "core/HeapBudget.h"

#include <Arduino.h>
#include <Logging.h>
#include <esp_heap_caps.h>

#if CROSSINK_TAILNET_TLS_PSRAM && defined(BOARD_HAS_PSRAM) && defined(FREEINK_NET_WOLFSSL) && !defined(SIMULATOR)
#include <wolfssl/wolfcrypt/settings.h>
#include <wolfssl/wolfcrypt/memory.h>
#define ORBIFY_TLS_PSRAM 1
#else
#define ORBIFY_TLS_PSRAM 0
#endif

namespace OrbifyHeap {

namespace {
constexpr uint32_t PSRAM_CAPS = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
constexpr uint32_t INTERNAL_CAPS = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;

#if defined(BOARD_HAS_PSRAM) && !defined(SIMULATOR)
class PsramFirst final : public ArduinoJson::Allocator {
 public:
  void* allocate(size_t size) override { return heap_caps_malloc_prefer(size, 2, PSRAM_CAPS, INTERNAL_CAPS); }
  void deallocate(void* ptr) override { heap_caps_free(ptr); }
  void* reallocate(void* ptr, size_t size) override {
    return heap_caps_realloc_prefer(ptr, size, 2, PSRAM_CAPS, INTERNAL_CAPS);
  }
};
PsramFirst s_psramFirst;
#endif

#if ORBIFY_TLS_PSRAM
void* tlsMalloc(size_t size) { return heap_caps_malloc_prefer(size, 2, PSRAM_CAPS, INTERNAL_CAPS); }
void tlsFree(void* ptr) { heap_caps_free(ptr); }
void* tlsRealloc(void* ptr, size_t size) { return heap_caps_realloc_prefer(ptr, size, 2, PSRAM_CAPS, INTERNAL_CAPS); }
#endif
}  // namespace

bool roomForRequest(const char* what) {
  const uint32_t free = ESP.getFreeHeap();
  if (free >= KEPT_CONNECTION_MIN_FREE) return true;
  LOG_INF("ORB", "%s: waiting for heap (free=%u, needs %u, maxAlloc=%u); next sync", what, static_cast<unsigned>(free),
          static_cast<unsigned>(KEPT_CONNECTION_MIN_FREE), static_cast<unsigned>(ESP.getMaxAllocHeap()));
  return false;
}

bool roomForWifi() {
  const auto free = heap_caps_get_free_size(INTERNAL_CAPS);
  const auto largest = heap_caps_get_largest_free_block(INTERNAL_CAPS);
  if (orbify::heap::wifiFits(free, largest)) return true;
  LOG_ERR("ORB", "Not enough memory to connect; close the catalog and try again (free=%u largest=%u)",
          static_cast<unsigned>(free), static_cast<unsigned>(largest));
  return false;
}
bool roomForCatalog() {
  const auto free = heap_caps_get_free_size(INTERNAL_CAPS);
  const auto largest = heap_caps_get_largest_free_block(INTERNAL_CAPS);
  if (orbify::heap::catalogFits(free, largest)) return true;
  LOG_ERR("ORB", "Catalog: waiting for heap (free=%u largest=%u); using saved data",
          static_cast<unsigned>(free), static_cast<unsigned>(largest));
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

void installTlsPsram() {
#if ORBIFY_TLS_PSRAM
  static bool installed = false;
  if (installed || heap_caps_get_total_size(MALLOC_CAP_SPIRAM) == 0) return;
  // The TLS arena (X3 only) installs its own hooks; the two never share a build.
  if (wolfSSL_SetAllocators(tlsMalloc, tlsFree, tlsRealloc) == 0) {
    installed = true;
    LOG_INF("ORB", "wolfSSL allocates from PSRAM");
  }
#endif
}

ArduinoJson::Allocator* jsonAllocator() {
#if defined(BOARD_HAS_PSRAM) && !defined(SIMULATOR)
  if (heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0) return &s_psramFirst;
#endif
  return ArduinoJson::detail::DefaultAllocator::instance();
}

void logHeap(const char* where) {
  LOG_INF("ORB", "Heap %s: internal free=%u largest=%u, psram free=%u", where,
          static_cast<unsigned>(heap_caps_get_free_size(INTERNAL_CAPS)),
          static_cast<unsigned>(heap_caps_get_largest_free_block(INTERNAL_CAPS)),
          static_cast<unsigned>(heap_caps_get_free_size(PSRAM_CAPS)));
}

}  // namespace OrbifyHeap
