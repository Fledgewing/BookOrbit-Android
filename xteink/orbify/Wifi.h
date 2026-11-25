// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CrossInkTailnetCuts.h>
#include "core/WifiHolds.h"
namespace OrbifyWifi {
using Owner = orbify::wifi::Owner;
// Shared by activities and the reading-sync worker; counters are protected by a mutex.
#if CROSSINK_TAILNET_ORBIFY_MIRROR
void acquire(Owner owner);
void release(Owner owner);
bool allowOff(const char* reason);
#else
inline void acquire(Owner) {}
inline void release(Owner) {}
inline bool allowOff(const char*) { return true; }
#endif
#ifdef SIMULATOR
void simulatorIdleOffProbe();
#else
inline void simulatorIdleOffProbe() {}
#endif
class Hold {
 public:
  explicit Hold(Owner owner, bool enabled = true) : owner(owner), held(enabled) { if (held) acquire(owner); }
  ~Hold() { reset(); }
  void reset() { if (held) { held = false; release(owner); } }
  Hold(const Hold&) = delete;
  Hold& operator=(const Hold&) = delete;
 private:
  Owner owner;
  bool held;
};
}
