// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <CrossInkTailnetCuts.h>
#include <cstddef>
#include <string>
namespace OrbifyMirror {
struct Snapshot {
  bool active = false, finished = false, paused = false;
  unsigned percent = 0;
  size_t done = 0, total = 0, failures = 0;
  std::string result;
};
#if CROSSINK_TAILNET_ORBIFY_MIRROR
Snapshot snapshot();
void freshRequest();
// Main-loop scheduling only: no network, parsing, scans, or waiting on the UI task.
void service();
void stopForSleep();
bool busy();
void countCatalogRequest();
#else
inline void service() {}
inline void stopForSleep() {}
inline bool busy() { return false; }
#endif
}
