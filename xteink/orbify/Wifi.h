// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CrossInkTailnetCuts.h>

#include "core/WifiHolds.h"
namespace OrbifyWifi {
using Owner = orbify::wifi::Owner;
bool connect(const char* reason, bool (*stop)());
// Shared by activities and the reading-sync worker; counters are protected by a
// mutex.
#if CROSSINK_TAILNET_ORBIFY_MIRROR
void acquire(Owner owner);
void tick(bool reading, bool browsing = false, bool busy = false);
void release(Owner owner);
void turnOff(const char* reason, void (*off)());
#else
inline void acquire(Owner) {}
inline void tick(bool, bool = false, bool = false) {}
inline void release(Owner) {}
inline void turnOff(const char*, void (*off)()) { off(); }
#endif
#ifdef SIMULATOR
void simulatorIdleOffProbe();
#else
inline void simulatorIdleOffProbe() {}
#endif
class Hold {
 public:
  explicit Hold(Owner owner, bool enabled = true) : owner(owner), held(enabled) {
    if (held) acquire(owner);
  }
  ~Hold() { reset(); }
  void reset() {
    if (held) {
      held = false;
      release(owner);
    }
  }
  Hold(const Hold&) = delete;
  Hold& operator=(const Hold&) = delete;

 private:
  Owner owner;
  bool held;
};
}  // namespace OrbifyWifi
