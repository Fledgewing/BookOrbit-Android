// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
namespace orbify::wifi {
inline bool shouldConnect(const std::string&, const std::string& reason, bool saved) {
  // Android's three modes all allow a requested flow to acquire the radio. They
  // change release/off behavior, never forbid sleep/open/wake or a genuine miss.
  return !saved && !reason.empty();
}
struct Policy {
  std::string mode = "jit";
  uint32_t idleSeconds = 120;
  uint32_t activity = 0, released = 0;
  bool releasePending = false, restoreOff = false, inBook = false, bookWasOn = false, forceOff = false;
  void acquire(bool on, unsigned heldBefore, uint32_t now) {
    if (!heldBefore) restoreOff = !on;
    releasePending = false; activity = now;
  }
  void release(unsigned heldAfter, uint32_t now) {
    activity = now;
    if (!heldAfter) { released = now + 3; releasePending = true; }
  }
  bool book(bool reading, bool on) {
    if (reading == inBook) return false;
    inBook = reading;
    if (reading) { bookWasOn = on; forceOff = mode == "off_reading" && on; return false; }
    forceOff = false;
    return mode == "off_reading" && bookWasOn;
  }
  bool off(bool on, unsigned held, bool busy, uint32_t now, bool browsing = false) const {
    if (!on || held || busy) return false;
    const bool ready = releasePending && static_cast<int32_t>(now - released) >= 0;
    const bool reading = inBook && !browsing;
    if (forceOff && reading && (ready || !releasePending)) return true;
    if (ready && (restoreOff || (reading && mode != "always_on"))) return true;
    return mode == "jit" && now - activity >= idleSeconds;
  }
  void wifiOff() { restoreOff = false; releasePending = false; forceOff = false; }
};
}
