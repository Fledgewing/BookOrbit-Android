// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of BookSync's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#pragma once

#include "activities/Activity.h"
#include "BatteryStats.h"

// Settings > System > Battery stats (the battery-stats patch, switch >= 2): exports
// /battery_stats.json; at switch 3 it also shows time left and the drain rates.
class BatteryStatsActivity final : public Activity {
 public:
  explicit BatteryStatsActivity(GfxRenderer& renderer, MappedInputManager& mappedInput)
      : Activity("BatteryStats", renderer, mappedInput) {}

  void onEnter() override;
  void loop() override;
  void render(RenderLock&&) override;

 private:
  enum class State : uint8_t { Ready, Saved, Failed };
  State state = State::Ready;
#if CROSSINK_TAILNET_BATTERY_STATS >= 3
  batterystats::Summary summary;
  bool haveSummary = false;
#endif
  void runExport();
};
