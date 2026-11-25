// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace orbify::orbismart {
// Fixed-size two-slot journal, shared by every reader. No pointers or native
// padding on disk. Hash keys name books, server scopes prevent an
// account/server change reusing a queued intent.
#pragma pack(push, 1)
struct RemoteRecord {
  int64_t at = 0;
  float percent = 0;
  char xpath[256] = {};
  char device[64] = {};
  char deviceId[64] = {};
};
struct State {
  uint32_t magic = 0x314D534F; // OSM1
  uint32_t generation = 0;
  uint32_t server = 0;
  uint32_t checksum = 0;
  enum : uint8_t {
    PENDING = 1,
    WAKE = 2,
    OVERRIDE = 4,
    FINISHED = 8,
    WAS_COMPLETED = 16
  };
  uint8_t flags = 0;
  int64_t turn = 0;
  int64_t slept = 0;
  int64_t declined = 0;
  uint32_t finishTurns = 0;
  char path[384] = {};
  RemoteRecord pending;
  RemoteRecord seen;
  RemoteRecord chosen;
  int32_t spine = 0, page = 0, count = 1;
};
#pragma pack(pop)
inline bool pauseDue(uint32_t idleMs, uint32_t turns, int spine, int page,
                     int syncedSpine, int syncedPage) {
  const int delta = page - syncedPage;
  return idleMs >= 120000 && turns > 1 &&
         (spine != syncedSpine || delta > 1 || delta < -1);
}
inline bool wakeDue(int64_t now, int64_t slept) {
  return slept == 0 || now - slept >= 600;
}
inline uint32_t hashBytes(const void *data, size_t size) {
  uint32_t h = 2166136261u;
  const auto *p = static_cast<const uint8_t *>(data);
  while (size--)
    h = (h ^ *p++) * 16777619u;
  return h;
}
inline uint32_t stateChecksum(State state) {
  state.checksum = 0;
  return hashBytes(&state, sizeof(state));
}
inline void seal(State &state) { state.checksum = stateChecksum(state); }
inline bool valid(const State &state, uint32_t server) {
  return state.magic == 0x314D534F && state.generation != 0 &&
         state.server == server && state.checksum == stateChecksum(state) &&
         state.path[sizeof(state.path) - 1] == 0 &&
         state.pending.xpath[255] == 0 && state.pending.device[63] == 0 &&
         state.pending.deviceId[63] == 0 && state.seen.xpath[255] == 0 &&
         state.seen.device[63] == 0 && state.seen.deviceId[63] == 0 &&
         state.chosen.xpath[255] == 0;
}
} // namespace orbify::orbismart
