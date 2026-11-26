#pragma once
// BookSync: the internal heap the sync's extra work (copy refresh, the next cover, the mirror's slice)
// may use (docs/design/XTEINK-BUILD-NOTES.md "The sleep sync on a shared heap").
//
// An X4 Pro sleep sync with Tailscale up kept ~30 KB of internal RAM free beside its one TLS session.
// rc3 opened a second session with no floor and the relay's own TLS ran out of memory ("esp-aes:
// Failed to allocate memory"). Session lending puts the extras on the sync's connection behind these
// floors, which then deferred everything: .167 had 21 KB free with a 7 KB largest block.
//
// What took it (.167 log, X4 Pro sleep sync): the largest internal block was 31.7 KB before the
// sync's wolfSSL handshake and 10.2 KB after it. wolfSSL used the default malloc, so every one of
// its allocations under 4 KB (CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL; with WOLFSSL_SMALL_STACK, the
// handshake's many big-number and certificate temporaries) went to internal RAM and left it in
// pieces. The TLS PSRAM hook gives wolfSSL a PSRAM allocator on the X4s (installTlsPsram), parses replies
// into PSRAM (jsonAllocator), and the floors below count what a request still needs of internal
// RAM there: Wi-Fi and lwIP buffers, and the relay's DMA bounce buffers (~1.6 KB each).
#include <ArduinoJson.h>

#include <cstdint>

namespace OrbifyHeap {

#if CROSSINK_TAILNET_TLS_PSRAM
// Free internal RAM before a request on a kept (already handshaken) connection.
constexpr uint32_t KEPT_CONNECTION_MIN_FREE = 12 * 1024;
// A transfer under way gives up below this: the relay's TLS needs its few KB to keep the link.
constexpr uint32_t TRANSFER_MIN_FREE = 8 * 1024;
#else
constexpr uint32_t KEPT_CONNECTION_MIN_FREE = 24 * 1024;
constexpr uint32_t TRANSFER_MIN_FREE = 16 * 1024;
#endif

// Logs "<what>: waiting for heap (...)" and returns false when a request does not fit.
bool roomForRequest(const char* what);
// For a transfer's cancel check: true (logged once per boot) when the heap is starved.
bool starved();
// Catalog browsing leaves headroom for the Wi-Fi PHY, even on an already joined radio.
bool roomForCatalog();
bool roomForWifi();

// The X4s: wolfSSL allocates from PSRAM (internal RAM when PSRAM has no room). Call once at boot,
// before the first TLS session. No-op without PSRAM and on the simulator.
void installTlsPsram();

// For JsonDocument: PSRAM first on the X4s, the default heap elsewhere.
ArduinoJson::Allocator* jsonAllocator();

// One line of the internal and PSRAM heap, for device measurements: "Heap <where>: ...".
void logHeap(const char* where);

}  // namespace OrbifyHeap
