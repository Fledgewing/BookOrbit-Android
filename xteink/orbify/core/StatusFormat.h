// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdio>
#include <cstddef>
#include <cmath>
namespace orbify {
inline void statusPages(char* out, size_t len, int page, int total, bool estimated = false) {
  std::snprintf(out, len, "%s%d / %d", estimated ? "~" : "", page, total);
}
inline void statusPercent(char* out, size_t len, double percent, int decimals, bool besidePages) {
  percent = std::fmax(0.0, std::fmin(100.0, percent));
  // ArduinoJson/firmware may supply float values just below an exact half.
  if (decimals == 0) percent = std::floor(percent + 0.5 + 1e-6);
  std::snprintf(out, len, besidePages ? "· %.*f%%" : "%.*f%%", decimals, percent);
}
}  // namespace orbify
