"""BookSync's additions to the fetched crossink-simulator package (simulator builds only).

tailnet_build.py runs this in a simulator env, after upstream's own package patcher
(test/integration/ci/patch_simulator_package.py, when the checkout has one). Each step looks for
its marker first, so a rerun is a no-op; a step whose anchor is gone stops the build, which is how
a re-pinned simulator that changed the code shows.

1. heap_caps_get_minimum_free_size (patch 0022's background sync logs it) and heap_caps_realloc
   (the write-through cache's PSRAM allocator, patch 0029): the package lacks both.
2. The scripted heap (ORBIFY_SIM_HEAP): a timeline that caps the internal heap the firmware is
   told about, so the heap floors' decisions run (wait, stop a transfer, skip a cover decode).
   "0:120000/60000;30000:20000/14000" = from 0 ms after the process started, at most 120000 B
   free with a 60000 B largest block; from 30 s, 20000/14000. A step written "w100:..." counts
   from the process's first WiFi.begin() instead: the heap a device has once its Wi-Fi driver
   (and Tailscale) took their share, which the firmware's own checks before starting Wi-Fi
   must not see. Only what is reported changes:
   allocations still follow the package's own model. The real numbers stay a device check
   (docs/design/emulated-release-tests.md 6.2).
"""

from pathlib import Path

INPUT_CLOCK_HEADER = "orbify_sim_input.h"
INPUT_CLOCK = """\
// SPDX-License-Identifier: MIT
// BookSync: opt-in script time from the first input poll, after boot setup.
#pragma once
#include <cstdlib>
namespace orbify_sim_input {
struct Clock {
  bool started = false;
  unsigned long origin = 0;
  unsigned long elapsed(unsigned long processMs, bool relative) {
    if (!relative) return processMs;
    if (!started) { origin = processMs; started = true; }
    return processMs - origin;
  }
};
inline unsigned long now(unsigned long processMs) {
  static Clock clock;
  static const bool relative = std::getenv("ORBIFY_SIM_INPUT_FROM_POLL") != nullptr;
  return clock.elapsed(processMs, relative);
}
} // namespace orbify_sim_input
"""


def patch_input(src_dir):
    """Opt-in input epoch; absolute scripts/screenshots keep their existing clock."""
    changed = []
    header = Path(src_dir) / INPUT_CLOCK_HEADER
    if not header.exists() or header.read_text() != INPUT_CLOCK:
        header.write_text(INPUT_CLOCK)
        changed.append(INPUT_CLOCK_HEADER)
    include = '#include "SimulatorInput.h"\n'
    clock = "  const unsigned long now = millis();\n"

    def transform(text):
        if include not in text or clock not in text:
            return text
        return text.replace(include, include + '#include "orbify_sim_input.h"\n', 1).replace(
            clock, "  const unsigned long now = orbify_sim_input::now(millis());\n", 1)

    _edit(Path(src_dir) / "HalGPIO.cpp", "orbify_sim_input::now", transform, changed, "input poll clock")
    return changed

# The host has no flash cache. Model the ESP-IDF cache_utils.c stack assertion
# explicitly, so simulator builds exercise the same caps API as the S3 build.
FLASH_MODEL = """\
// SPDX-License-Identifier: MIT
#pragma once
#include <cstdlib>
#include <cstdio>
#include <esp_heap_caps.h>
#include <freertos/task.h>
namespace orbify_sim_flash {
inline thread_local uint32_t stackCaps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
inline void write() {
  if (!std::getenv("ORBIFY_SIM_FLASH_ON_CONNECT")) return;
  static thread_local bool done = false;
  if (done) return;
  done = true;
  if (!(stackCaps & MALLOC_CAP_INTERNAL)) {
    std::fprintf(stderr, "Flash cache disabled with external task stack\\n");
    std::fflush(nullptr); std::_Exit(87);
  }
  std::fprintf(stderr, "Flash write on internal task stack: %s\\n", pcTaskGetName(nullptr));
}
}
"""
CAPS_TASK = """\
// SPDX-License-Identifier: MIT
#pragma once
#include <freertos/task.h>
#include <orbify_sim_flash.h>
#include <memory>
struct OrbifySimCapsCall { void (*fn)(void*); void* arg; uint32_t caps; };
inline BaseType_t xTaskCreateWithCaps(void (*fn)(void*), const char* name,
    uint32_t bytes, void* arg, BaseType_t priority, TaskHandle_t* task, uint32_t caps) {
  auto* call = new OrbifySimCapsCall{fn, arg, caps};
  return xTaskCreate([](void* p) {
    std::unique_ptr<OrbifySimCapsCall> call(static_cast<OrbifySimCapsCall*>(p));
    orbify_sim_flash::stackCaps = call->caps;
    call->fn(call->arg);
  }, name, bytes, call, priority, task);
}
"""


def patch_storage(src_dir):
    """Opt-in SdFat semantics: creating an existing final directory fails.

    The package's POSIX EEXIST success hid device-only marker failures. Keep
    this in BookSync's package shim, never patch the upstream project.
    """
    changed = []
    anchor = '  return ::mkdir(full.c_str(), 0777) == 0 || errno == EEXIST;'
    def transform(text):
        return text.replace(anchor, '  if (std::getenv("ORBIFY_SIM_SDFAT_MKDIR"))\n'
                            '    return ::mkdir(full.c_str(), 0777) == 0;\n' + anchor, 1)
    _edit(Path(src_dir) / "HalStorage.cpp", "ORBIFY_SIM_SDFAT_MKDIR", transform,
          changed, "SdFat mkdir semantics")
    write_anchor = '  file = open(path, O_RDWR | O_CREAT | O_TRUNC);'
    def fail_marker(text):
        return text.replace(write_anchor,
                            '  if (std::getenv("ORBIFY_SIM_MARKER_IO_ERROR") &&\n'
                            '      std::string(path).find(".inflight.tmp") != std::string::npos) return false;\n'
                            + write_anchor, 1)
    _edit(Path(src_dir) / "HalStorage.cpp", "ORBIFY_SIM_MARKER_IO_ERROR", fail_marker,
          changed, "in-flight marker I/O failure")
    return changed


def patch_flash(src_dir):
    src = Path(src_dir)
    (src / "orbify_sim_flash.h").write_text(FLASH_MODEL)
    (src / "freertos/idf_additions.h").write_text(CAPS_TASK)
    changed = []
    return changed


MIN_FREE = """\
inline size_t heap_caps_get_minimum_free_size(const uint32_t caps) {
  simulator_heap::initialize();
  std::lock_guard<std::mutex> lock(simulator_heap::mutex);
  return simulator_heap::capabilityPoolFor(caps).minimumFree;
}
"""

REALLOC = """\
inline void *heap_caps_realloc(void *pointer, const size_t bytes, const uint32_t caps) {
  if (!pointer)
    return simulator_heap::allocate(bytes, caps);
  if (bytes == 0) {
    simulator_heap::release(pointer);
    return nullptr;
  }
  size_t old = 0;
  {
    std::lock_guard<std::mutex> lock(simulator_heap::mutex);
    const auto found = simulator_heap::live.find(pointer);
    if (found == simulator_heap::live.end())
      return std::realloc(pointer, bytes);
    old = found->second.size;
  }
  void *moved = simulator_heap::allocate(bytes, caps);
  if (!moved)
    return nullptr;
  std::memcpy(moved, pointer, std::min(old, bytes));
  simulator_heap::release(pointer);
  return moved;
}
"""

SCRIPTED_HEAP = """\
// BookSync: the scripted heap (xteink/tailnet/sim/sim_package.py).
namespace orbify_sim_heap {
struct Step {
  unsigned long atMs;
  size_t free;
  size_t largest;
  bool afterWifi;
};
inline const std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
inline std::vector<Step> parse() {
  std::vector<Step> steps;
  const char *spec = std::getenv("ORBIFY_SIM_HEAP");
  while (spec && *spec) {
    char *end = nullptr;
    const bool afterWifi = *spec == 'w';
    Step step{std::strtoul(spec + (afterWifi ? 1 : 0), &end, 10), 0, 0, afterWifi};
    if (!end || *end != ':')
      break;
    step.free = std::strtoull(end + 1, &end, 10);
    step.largest = step.free;
    if (end && *end == '/')
      step.largest = std::strtoull(end + 1, &end, 10);
    steps.push_back(step);
    spec = end && *end == ';' ? end + 1 : nullptr;
  }
  return steps;
}
inline size_t cap(const simulator_heap::Pool &pool, const bool largest, const size_t modeled) {
  static const std::vector<Step> steps = parse();
  if (steps.empty() || &pool != &simulator_heap::internal)
    return modeled;
  const auto now = static_cast<unsigned long>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                                  std::chrono::steady_clock::now() - started)
                                                  .count());
  const long long wifiAt = orbify_sim_wifi::startedMs.load();
  const Step *current = nullptr;
  for (const auto &step : steps)
    if (step.afterWifi ? (wifiAt >= 0 && wifiAt + static_cast<long long>(step.atMs) <= static_cast<long long>(now))
                       : step.atMs <= now)
      current = &step;
  if (!current)
    return modeled;
  static const Step *announced = nullptr;
  if (announced != current) {
    announced = current;
    std::fprintf(stderr, "ORBIFY_SIM_HEAP t=%s%lu free=%zu largest=%zu\\n", current->afterWifi ? "w" : "",
                 current->atMs, current->free, current->largest);
    std::fflush(stderr);
  }
  return std::min(modeled, largest ? current->largest : current->free);
}
}  // namespace orbify_sim_heap

"""

# Shared by the scripted heap and the package's WiFi: when this process first started Wi-Fi.
WIFI_CLOCK_HEADER = "orbify_sim_wifi.h"
WIFI_CLOCK = """\
// BookSync (xteink/tailnet/sim/sim_package.py): when this process first called WiFi.begin().
#pragma once
#include <atomic>
#include <chrono>
namespace orbify_sim_wifi {
inline const std::chrono::steady_clock::time_point processStart = std::chrono::steady_clock::now();
inline std::atomic<long long> startedMs{-1};
inline void began() {
  long long none = -1;
  startedMs.compare_exchange_strong(
      none, std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - processStart)
                .count());
}
}  // namespace orbify_sim_wifi
"""
WIFI_BEGIN_OLD = """    (void)pass;
    currentMode = WIFI_STA;
"""
WIFI_BEGIN_NEW = """    (void)pass;
    orbify_sim_wifi::began();
    currentMode = WIFI_STA;
"""

FREE_OLD = "  return simulator_heap::capabilityPoolFor(caps).free;\n}"
FREE_NEW = ("  const auto &pool = simulator_heap::capabilityPoolFor(caps);\n"
            "  return orbify_sim_heap::cap(pool, false, pool.free);\n}")
LARGEST_OLD = "  return simulator_heap::capabilityPoolFor(caps).largest;\n}"
LARGEST_NEW = ("  const auto &pool = simulator_heap::capabilityPoolFor(caps);\n"
               "  return orbify_sim_heap::cap(pool, true, pool.largest);\n}")


def _edit(path, marker, transform, changed, what):
    text = path.read_text()
    if marker in text:
        return
    updated = transform(text)
    if updated == text:
        raise RuntimeError(f"{path}: anchor for '{what}' not found; the simulator package changed, "
                           "update xteink/tailnet/sim/sim_package.py")
    path.write_text(updated)
    changed.append(what)


def patch(src_dir):
    """Patch the package sources in src_dir (.pio/libdeps/<env>/simulator/src). Returns what changed."""
    heap = Path(src_dir) / "esp_heap_caps.h"
    changed = patch_input(src_dir) + patch_flash(src_dir) + patch_storage(src_dir)
    clock = Path(src_dir) / WIFI_CLOCK_HEADER
    if not clock.exists() or clock.read_text() != WIFI_CLOCK:
        clock.write_text(WIFI_CLOCK)
        changed.append(WIFI_CLOCK_HEADER)
    wifi = Path(src_dir) / "WiFi.h"
    _edit(wifi, "orbify_sim_wifi::began", lambda t: t.replace(WIFI_BEGIN_OLD, WIFI_BEGIN_NEW, 1).replace(
        '#include "NetworkClient.h"\n', '#include "NetworkClient.h"\n#include "orbify_sim_wifi.h"\n', 1)
        if WIFI_BEGIN_OLD in t else t, changed, "Wi-Fi start time for the scripted heap")
    _edit(heap, "heap_caps_get_minimum_free_size", lambda t: t.replace(
        "inline void *heap_caps_malloc(", MIN_FREE + "inline void *heap_caps_malloc(", 1),
        changed, "heap_caps_get_minimum_free_size")

    _edit(heap, "heap_caps_realloc", lambda t: t.replace(
        "inline void heap_caps_free(", REALLOC + "inline void heap_caps_free(", 1), changed, "heap_caps_realloc")

    def scripted(t):
        anchors = ("#include <algorithm>\n", "inline size_t heap_caps_get_total_size(", FREE_OLD, LARGEST_OLD)
        if not all(a in t for a in anchors):
            return t
        t = t.replace(anchors[0], anchors[0] + "#include <chrono>\n#include \"orbify_sim_wifi.h\"\n", 1)
        t = t.replace(anchors[1], SCRIPTED_HEAP + anchors[1], 1)
        return t.replace(FREE_OLD, FREE_NEW, 1).replace(LARGEST_OLD, LARGEST_NEW, 1)

    _edit(heap, "orbify_sim_heap", scripted, changed, "scripted heap (ORBIFY_SIM_HEAP)")
    return changed
