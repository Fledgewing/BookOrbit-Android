// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of Orbify's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#include "BatteryStats.h"

#if CROSSINK_TAILNET_BATTERY_STATS >= 1

#include <Arduino.h>
#include <BatteryMonitor.h>
#include "core/BatteryStatsCore.h"
#include <BoardConfig.h>
#include <HalClock.h>
#include <HalDisplay.h>
#include <HalFrontlight.h>
#include <HalGPIO.h>
#include <HalPowerManager.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WallClock.h>
#include <WiFi.h>

#include <ctime>

#include "AppVersion.h"
#include "CrossPointSettings.h"
#include "activities/Activity.h"
#include "activities/ActivityManager.h"

namespace BatteryStats {
namespace {
using namespace batterystats;

constexpr char DIR[] = "/.crossink";
constexpr char LOG_PATH[] = "/.crossink/battery.bin";
constexpr char OLD_PATH[] = "/.crossink/battery.1.bin";
// About seven years at ~100 records a day. The full file then becomes battery.1.bin
// (kept, never deleted) and a new one starts; an older battery.1.bin is replaced.
constexpr size_t MAX_LOG_BYTES = 4u * 1024u * 1024u;
constexpr unsigned long CHECK_MS = 1000;        // book, USB power, frontlight
constexpr unsigned long LEVEL_CHECK_MS = 60000;  // battery % (cached for 30 s by the power manager)

bool started = false;
uint16_t pages = 0;
uint8_t content = CONTENT_NONE;
bool usb = false, light = false;
uint8_t lightLevel = 0;
uint8_t lastPct = 0;
unsigned long lastCheckMs = 0, lastLevelMs = 0;
// Radio events arrive on the Arduino event task: kept here, written from the main loop.
volatile bool radioOn = false;
volatile bool radioPending = false;

uint8_t boardId() {
  switch (BoardConfig::ACTIVE.board) {
    case BoardConfig::Board::XteinkX3:
    case BoardConfig::Board::XteinkX3Uc8279: return 1;
    case BoardConfig::Board::XteinkX4: return 2;
    case BoardConfig::Board::XteinkX4Pro: return 3;
    case BoardConfig::Board::XteinkX4Classic: return 4;
    default: return 0;
  }
}

void append(const uint8_t kind, uint8_t extraFlags = 0) {
  static const BatteryMonitor battery;
  Record r;
  const time_t now = time(nullptr);
  r.t = now > 0 ? static_cast<uint32_t>(now) : 0;
  r.kind = kind;
  r.era = static_cast<uint8_t>(WallClock::era());
  r.flags = extraFlags | static_cast<uint8_t>(content << FLAG_CONTENT_SHIFT);
  if (!halClock.isAvailable() || r.t < WallClock::MIN_PLAUSIBLE_EPOCH) r.flags |= FLAG_APPROX_TIME;
  if (usb) r.flags |= FLAG_USB;
  if (radioOn) r.flags |= FLAG_RADIO;
  if (light) r.flags |= FLAG_LIGHT;
  r.pct = lastPct = static_cast<uint8_t>(powerManager.getBatteryPercentage());
  r.mv = battery.readMillivolts();
  r.lightLevel = light ? lightLevel : 0;
  uint16_t full = 0, partial = 0;
  display.takeRefreshCounts(full, partial);
  r.full = full > 255 ? 255 : static_cast<uint8_t>(full);
  r.partial = partial;
  r.pages = pages;
  pages = 0;

  uint8_t bytes[RECORD_SIZE];
  encode(r, bytes);
  Storage.mkdir(DIR);
  HalFile file = Storage.open(LOG_PATH, O_RDWR | O_CREAT | O_APPEND);
  if (!file) {
    LOG_ERR("BSTAT", "Cannot open %s", LOG_PATH);
    return;
  }
  size_t size = file.size();
  if (size >= MAX_LOG_BYTES) {
    file.close();
    Storage.remove(OLD_PATH);
    Storage.rename(LOG_PATH, OLD_PATH);
    file = Storage.open(LOG_PATH, O_RDWR | O_CREAT | O_APPEND);
    if (!file) return;
    size = 0;
  }
  bool ok = true;
  if (size == 0) {
    uint8_t header[HEADER_SIZE];
    encodeHeader(header, boardId());
    ok = file.write(header, sizeof(header)) == sizeof(header);
  }
  if (ok) ok = file.write(bytes, sizeof(bytes)) == sizeof(bytes);
  if (!file.close() || !ok) LOG_ERR("BSTAT", "Append to %s failed", LOG_PATH);
}

void onRadio(const arduino_event_id_t event) {
  const bool on = event == ARDUINO_EVENT_WIFI_STA_START;
  if (on == radioOn) return;
  radioOn = on;
  radioPending = true;
}

uint8_t currentContent() {
  if (!activityManager.isReaderActivity()) return CONTENT_NONE;
  return contentForPath(activityManager.getCurrentBookPath().c_str());
}

bool currentLight(uint8_t& level) {
  level = Frontlight.brightness();
  return Frontlight.present() && Frontlight.isOn();
}
}  // namespace

void begin(const uint8_t resetClass) {
  usb = gpio.isUsbConnectedCached();
  light = currentLight(lightLevel);
  started = true;
  append(KIND_BOOT, static_cast<uint8_t>(resetClass << FLAG_RESET_SHIFT));
  WiFi.onEvent(onRadio, ARDUINO_EVENT_WIFI_STA_START);
  WiFi.onEvent(onRadio, ARDUINO_EVENT_WIFI_STA_STOP);
  lastLevelMs = lastCheckMs = millis();
}

void poll() {
  if (!started) return;
  if (radioPending) {
    radioPending = false;
    append(KIND_RADIO);
  }
  const unsigned long now = millis();
  if (now - lastCheckMs < CHECK_MS) return;
  lastCheckMs = now;

  const uint8_t c = currentContent();
  if (c != content) {
    content = c;
    append(KIND_CONTENT);
  }
  const bool u = gpio.isUsbConnectedCached();
  if (u != usb) {
    usb = u;
    append(KIND_CHARGE);
  }
  uint8_t level = 0;
  const bool l = currentLight(level);
  if (l != light) {
    light = l;
    lightLevel = level;
    append(KIND_LIGHT);
  } else if (l) {
    lightLevel = level;
  }
  if (now - lastLevelMs >= LEVEL_CHECK_MS) {
    lastLevelMs = now;
    if (powerManager.getBatteryPercentage() != lastPct) append(KIND_LEVEL);
  }
}

void onSleep() {
  if (started) append(KIND_SLEEP);
}

void onRestart() {
  if (started) append(KIND_RESTART);
}

void countPage() {
  if (pages < UINT16_MAX) pages++;
}

#if CROSSINK_TAILNET_BATTERY_STATS >= 2
namespace {
bool writeFile(void* ctx, const char* data, const size_t len) {
  return static_cast<HalFile*>(ctx)->write(data, len) == len;
}

// Feeds every record of battery.1.bin (if any) and battery.bin to the analyzer.
bool feed(void*, Analyzer& a) {
  for (const char* path : {OLD_PATH, LOG_PATH}) {
    if (!Storage.exists(path)) continue;
    HalFile file = Storage.open(path, O_RDONLY);
    if (!file) return false;
    uint8_t buf[HEADER_SIZE > RECORD_SIZE ? HEADER_SIZE : RECORD_SIZE];
    if (file.read(buf, HEADER_SIZE) != static_cast<int>(HEADER_SIZE) || !headerValid(buf)) {
      file.close();
      continue;
    }
    while (file.read(buf, RECORD_SIZE) == static_cast<int>(RECORD_SIZE)) a.add(decode(buf));
    file.close();
  }
  return true;
}

const char* modelName() {
  switch (boardId()) {
    case 1: return "X3";
    case 2: return "X4";
    case 3: return "X4 Pro";
    case 4: return "X4 Classic";
    default: return BoardConfig::ACTIVE.name;
  }
}
}  // namespace

bool exportJson(Summary* summary) {
  if (started) append(KIND_LEVEL);  // the current level closes the open stretch
  const bool gauge = BoardConfig::ACTIVE.batteryGauge.gaugeAddr != 0;
  DeviceInfo dev{modelName(), gauge ? "fuel_gauge" : "voltage_estimate",
                 gauge ? BoardConfig::ACTIVE.batteryGauge.designCapacityMah : static_cast<uint16_t>(0),
                 AppVersion::version()};
  const time_t t = time(nullptr);
  const uint32_t now = t > 0 ? static_cast<uint32_t>(t) : 0;
  Config cfg;
  cfg.utcOffsetMin = (static_cast<int32_t>(SETTINGS.clockUtcOffsetQ) - 48) * 15;
  cfg.hasLight = Frontlight.present();
  cfg.voltageEstimate = !gauge;
  cfg.segmentsSince = now > 90u * 86400u ? now - 90u * 86400u : 0;  // the companion's 90 days

  HalFile file = Storage.open(EXPORT_PATH, O_WRONLY | O_CREAT | O_TRUNC);
  if (!file) return false;
  JsonOut out{writeFile, &file};
  const bool nowKnown = halClock.isAvailable() && now >= WallClock::MIN_PLAUSIBLE_EPOCH;
#if CROSSINK_TAILNET_BATTERY_STATS >= 3
  const auto done = [](void* ctx, const Analyzer& a) {
    if (ctx) *static_cast<Summary*>(ctx) = summarize(a);
  };
  const bool ok = batterystats::exportJson(out, dev, cfg, now, nowKnown, feed, nullptr, done, summary);
#else
  (void)summary;
  const bool ok = batterystats::exportJson(out, dev, cfg, now, nowKnown, feed, nullptr);
#endif
  const bool closed = file.close();
  LOG_INF("BSTAT", "Export to %s %s", EXPORT_PATH, ok && closed ? "done" : "failed");
  return ok && closed;
}
#endif

}  // namespace BatteryStats

#endif  // CROSSINK_TAILNET_BATTERY_STATS >= 1
