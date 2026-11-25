// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace orbify::wifi {
enum class Owner : uint8_t { Catalog, Refresh, SleepSync, OfflineMiss, BackgroundSync, Count };
// Main-loop policy: off requests wait for every nested hold, including holds by the same owner.
class Holds {
 public:
  void acquire(Owner owner) { ++counts[static_cast<size_t>(owner)]; ++total; }
  bool release(Owner owner) {
    auto& count = counts[static_cast<size_t>(owner)];
    if (!count) return false;
    --count; --total;
    return total == 0 && pending;
  }
  bool requestOff() { pending = total != 0; return !pending; }
  unsigned held() const { return total; }
 private:
  std::array<unsigned, static_cast<size_t>(Owner::Count)> counts{};
  unsigned total = 0;
  bool pending = false;
};
}
