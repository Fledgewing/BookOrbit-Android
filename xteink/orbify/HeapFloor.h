#pragma once
// Orbify: the heap the sleep sync's extra work (copy refresh, the next cover, the mirror's slice) may
// use (patch 0037, docs/design/XTEINK-BUILD-NOTES.md "The sleep sync on a shared heap").
//
// An X4 Pro sleep sync with Tailscale up has ~30 KB of internal RAM free beside its one TLS session
// (Wi-Fi ~26 KB, MicroLink's tasks and relay session most of the rest). rc3 then opened a second
// catalog session with no floor at all and walked the mirror on it: the relay's own TLS ran out of
// memory ("esp-aes: Failed to allocate memory"), the relay dropped, handshakes took 14 s and a 47 KB
// reply waited 82 s. The extras now ride the sync's own connection, and each request needs this
// much free; a transfer under way stops when the heap falls to the starved mark.
#include <cstdint>

namespace OrbifyHeap {

// Free internal RAM before a request on a kept (already handshaken) connection.
constexpr uint32_t KEPT_CONNECTION_MIN_FREE = 24 * 1024;
// A transfer under way gives up below this: the relay's TLS needs its few KB to keep the link.
constexpr uint32_t TRANSFER_MIN_FREE = 16 * 1024;

// Logs "<what>: waiting for heap (...)" and returns false when a request does not fit.
bool roomForRequest(const char* what);
// For a transfer's cancel check: true (logged once per boot) when the heap is starved.
bool starved();

}  // namespace OrbifyHeap
