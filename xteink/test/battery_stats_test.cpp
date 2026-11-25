// The battery stats' hardware-free part (orbify/core/BatteryStatsCore): record format, analysis and
// the orbit-battery-stats/1 export. Written for GoogleTest; GtestShim.h runs it here.
#include "BatteryStatsCore.h"
#include "GtestShim.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace batterystats;

namespace {
constexpr uint32_t T0 = 1763712000;  // 2025-11-21T08:00:00Z

Record rec(uint32_t t, uint8_t kind, uint8_t pct, uint8_t flags = 0, uint16_t pages = 0, uint8_t full = 0,
           uint16_t partial = 0) {
  Record r;
  r.t = t;
  r.kind = kind;
  r.pct = pct;
  r.flags = flags;
  r.pages = pages;
  r.full = full;
  r.partial = partial;
  return r;
}

constexpr uint8_t TEXT = CONTENT_TEXT << FLAG_CONTENT_SHIFT;
constexpr uint8_t XTC = CONTENT_XTC << FLAG_CONTENT_SHIFT;
constexpr uint32_t H = 3600;

// Two days: two nights of standby, reading text and xtc, one charge.
std::vector<Record> sampleLog() {
  std::vector<Record> v;
  uint32_t t = T0;
  for (int day = 0; day < 2; day++) {
    const uint8_t b = static_cast<uint8_t>(90 - 12 * day);
    v.push_back(rec(t, KIND_BOOT, b));
    v.push_back(rec(t + 60, KIND_CONTENT, b, TEXT));
    v.push_back(rec(t + H, KIND_LEVEL, b - 3, TEXT, 60, 6, 54));
    v.push_back(rec(t + 2 * H, KIND_CONTENT, b - 6, 0, 60, 6, 54));
    v.push_back(rec(t + 2 * H + 60, KIND_CONTENT, b - 6, XTC));
    v.push_back(rec(t + 3 * H, KIND_SLEEP, b - 8, XTC, 50, 50, 0));
    v.push_back(rec(t + 13 * H, KIND_BOOT, b - 10));  // 10 h asleep: 0.2 %/h
    v.push_back(rec(t + 14 * H, KIND_SLEEP, b - 10));
    t += 24 * H;  // and 10 h more: 0.2 %/h
  }
  v.push_back(rec(t, KIND_BOOT, 66));
  v.push_back(rec(t + 60, KIND_CHARGE, 66, FLAG_USB));
  v.push_back(rec(t + 60 + H, KIND_CHARGE, 96, 0));
  return v;
}

bool feedSample(void* ctx, Analyzer& a) {
  for (const Record& r : *static_cast<std::vector<Record>*>(ctx)) a.add(r);
  return true;
}

bool appendString(void* ctx, const char* data, size_t len) {
  static_cast<std::string*>(ctx)->append(data, len);
  return true;
}
}  // namespace

TEST(BatteryStatsRecord, EncodesLittleEndianSixteenBytes) {
  Record r = rec(0x01020304, KIND_LEVEL, 57, FLAG_USB | TEXT, 0x0506, 7, 0x0809);
  r.era = 3;
  r.mv = 0x0A0B;
  r.lightLevel = 40;
  uint8_t b[RECORD_SIZE];
  encode(r, b);
  const uint8_t want[RECORD_SIZE] = {4, 3, 2, 1, KIND_LEVEL, 3, FLAG_USB | TEXT, 57, 0x0B, 0x0A, 40, 7, 6, 5, 9, 8};
  EXPECT_EQ(0, memcmp(b, want, sizeof(want)));
  const Record d = decode(b);
  EXPECT_EQ(d.t, r.t);
  EXPECT_EQ(d.pages, r.pages);
  EXPECT_EQ(d.partial, r.partial);
  EXPECT_EQ(d.content(), CONTENT_TEXT);
}

TEST(BatteryStatsRecord, HeaderAndBootResetClass) {
  uint8_t h[HEADER_SIZE];
  encodeHeader(h, 3);
  EXPECT_TRUE(headerValid(h));
  h[0] = 'X';
  EXPECT_FALSE(headerValid(h));
  const Record r = rec(T0, KIND_BOOT, 50, static_cast<uint8_t>(RESET_CRASH << FLAG_RESET_SHIFT));
  EXPECT_EQ(r.resetClass(), RESET_CRASH);
}

TEST(BatteryStatsRecord, ContentFromExtension) {
  EXPECT_EQ(contentForPath("/Books/a.EPUB"), CONTENT_TEXT);
  EXPECT_EQ(contentForPath("/a.md"), CONTENT_TEXT);
  EXPECT_EQ(contentForPath("/a.xtch"), CONTENT_XTC);
  EXPECT_EQ(contentForPath("/a.bmp"), CONTENT_NONE);
  EXPECT_EQ(contentForPath(""), CONTENT_NONE);
}

TEST(BatteryStatsTime, IsoWithOffsetAndLocalDay) {
  char buf[32];
  formatTime(T0, -8 * 60, buf, sizeof(buf));
  EXPECT_STREQ(buf, "2025-11-21T00:00:00-08:00");
  formatTime(T0 + 30 * 60, 5 * 60 + 30, buf, sizeof(buf));
  EXPECT_STREQ(buf, "2025-11-21T14:00:00+05:30");
  EXPECT_EQ(localDay(T0 - 1, -8 * 60) + 1, localDay(T0, -8 * 60));
}

TEST(BatteryStatsAnalyzer, PooledRatesAndUnknownStretches) {
  std::vector<Record> log = sampleLog();
  Config cfg;
  Analyzer a(cfg, T0 + 49 * H, nullptr, nullptr, nullptr);
  for (const Record& r : log) a.add(r);
  a.finish();
  const Pooled& standby = a.rate(CAT_STANDBY);
  ASSERT_TRUE(standby.has());
  EXPECT_NEAR(standby.pctPerHour(false), 0.2, 1e-9);
  EXPECT_EQ(standby.segments, 4u);  // each night and each gap before a morning boot
  const Pooled& text = a.rate(CAT_READING_TEXT);
  EXPECT_NEAR(text.pctPerHour(false), 3.0, 0.05);
  EXPECT_EQ(text.pages, 240u);
  const Pooled& charging = a.rate(CAT_CHARGING);
  EXPECT_NEAR(charging.pctPerHour(true), 30.0, 1e-6);

  // Power lost while awake: that stretch is skipped, not counted as standby.
  Analyzer b(cfg, T0, nullptr, nullptr, nullptr);
  b.add(rec(T0, KIND_BOOT, 80));
  b.add(rec(T0 + 5 * H, KIND_BOOT, 60, static_cast<uint8_t>(RESET_POWER_ON << FLAG_RESET_SHIFT)));
  b.finish();
  EXPECT_FALSE(b.rate(CAT_AWAKE).has());
  // Charged while asleep: the stretch is unknown too.
  Analyzer c(cfg, T0, nullptr, nullptr, nullptr);
  c.add(rec(T0, KIND_SLEEP, 50));
  c.add(rec(T0 + 5 * H, KIND_BOOT, 70, FLAG_USB));
  c.finish();
  EXPECT_FALSE(c.rate(CAT_STANDBY).has());
}

TEST(BatteryStatsExport, WritesOrbitBatteryStatsJson) {
  std::vector<Record> log = sampleLog();
  std::string json;
  JsonOut out{appendString, &json};
  Config cfg;
  cfg.utcOffsetMin = -8 * 60;
  cfg.hasLight = true;
  DeviceInfo dev{"X4 Pro", "fuel_gauge", 0, "2.0.0-test"};
  Summary s;
  const auto done = [](void* ctx, const Analyzer& a) { *static_cast<Summary*>(ctx) = summarize(a); };
  ASSERT_TRUE(exportJson(out, dev, cfg, T0 + 49 * H, true, feedSample, &log, done, &s));
  EXPECT_NE(json.find("\"schema\":\"orbit-battery-stats/1\""), std::string::npos);
  EXPECT_NE(json.find("\"source\":\"crossink-firmware\""), std::string::npos);
  EXPECT_NE(json.find("\"content\":\"xtc\""), std::string::npos);
  EXPECT_NE(json.find("\"light\":\"off\""), std::string::npos);
  EXPECT_NE(json.find("\"unit\":\"pages\""), std::string::npos);
  EXPECT_NE(json.find("\"day\":\"2025-11-21\""), std::string::npos);
  EXPECT_EQ(json.find("capacity_mah"), std::string::npos);
  EXPECT_TRUE(s.standby);
  EXPECT_NEAR(s.standbyPctH, 0.2f, 1e-4);
  EXPECT_TRUE(s.reading);
  EXPECT_TRUE(s.timeLeft);
  if (const char* path = std::getenv("BATTERY_STATS_SAMPLE")) {
    FILE* f = fopen(path, "w");
    ASSERT_NE(f, nullptr);
    fwrite(json.data(), 1, json.size(), f);
    fclose(f);
  }
}

TEST(BatteryStatsExport, NoClockWritesNullTimes) {
  std::vector<Record> log;
  log.push_back(rec(1000, KIND_SLEEP, 80, FLAG_APPROX_TIME));
  log.push_back(rec(1000 + 20 * H, KIND_BOOT, 76, FLAG_APPROX_TIME));
  std::string json;
  JsonOut out{appendString, &json};
  Config cfg;
  cfg.voltageEstimate = false;
  DeviceInfo dev{"X4", "voltage_estimate", 0, "t"};
  ASSERT_TRUE(exportJson(out, dev, cfg, 1000 + 20 * H, false, feedSample, &log));
  EXPECT_NE(json.find("\"start\":null,\"end\":null,\"duration_s\":72000"), std::string::npos);
  EXPECT_EQ(json.find("\"generated\""), std::string::npos);
  EXPECT_EQ(json.find("\"day\""), std::string::npos);
}

GTEST_SHIM_MAIN("battery_stats")
