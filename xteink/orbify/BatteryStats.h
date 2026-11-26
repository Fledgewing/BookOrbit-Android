// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of BookSync's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#pragma once

// Battery stats (hooked in by the battery-stats patch; switch CROSSINK_TAILNET_BATTERY_STATS):
//   1 record: one 16-byte record per transition (boot, sleep, restart, Wi-Fi, USB power,
//     book open/close, frontlight, 1 % step) appended to /.crossink/battery.bin. Never a
//     timer or a wakeup: records are written where the firmware already is awake.
//   2 + export: Settings > System > Battery stats writes /battery_stats.json in the
//     orbit-battery-stats/1 format (BookSync docs/design/STATS.md).
//   3 + the numbers on that page, and an export whenever USB Drive mode starts.
// At 0 every call below is an empty inline.

#include <cstddef>
#include <cstdint>

#ifndef CROSSINK_TAILNET_BATTERY_STATS
#define CROSSINK_TAILNET_BATTERY_STATS 0
#endif

#if CROSSINK_TAILNET_BATTERY_STATS >= 2
#include "core/BatteryStatsCore.h"
#endif

namespace BatteryStats {

#if CROSSINK_TAILNET_BATTERY_STATS >= 1
// After the SD card is mounted at boot. resetClass: batterystats::ResetClass.
void begin(uint8_t resetClass);
// Main loop: radio events, USB power, book, frontlight, battery steps.
void poll();
void onSleep();    // last SD write before deep sleep
void onRestart();  // before a software restart
void countPage();  // any page turn in a reader
#else
inline void begin(uint8_t) {}
inline void poll() {}
inline void onSleep() {}
inline void onRestart() {}
inline void countPage() {}
#endif

#if CROSSINK_TAILNET_BATTERY_STATS >= 2
constexpr char EXPORT_PATH[] = "/battery_stats.json";
// Writes EXPORT_PATH. `summary` (optional) receives the page's numbers.
bool exportJson(batterystats::Summary* summary);
#endif

}  // namespace BatteryStats
