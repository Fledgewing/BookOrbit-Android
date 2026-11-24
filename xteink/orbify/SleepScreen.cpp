#include "SleepScreen.h"

#if CROSSINK_TAILNET_ORBIFY_SLEEP

#include <Arduino.h>
#include <ArduinoJson.h>
#include <GfxRenderer.h>
#include <HalPowerManager.h>
#include <HalStorage.h>
#include <JpegToBmpConverter.h>
#include <Logging.h>
#include <esp_heap_caps.h>

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <new>
#include <vector>

#include "BookOrbitCredentialStore.h"
#include "BookOrbitDownloadIndex.h"
#include "BookOrbitSyncClient.h"
#include "CrossPointSettings.h"
#include "CrossPointState.h"
#include "HeapFloor.h"
#include "fontIds.h"
#include "network/BookOrbitCatalogClient.h"

namespace OrbifySleep {

using namespace orbify::sleep;

namespace {

constexpr char TAG[] = "ORB";
constexpr char DIR[] = "/.crosspoint/orbify_sleep";
constexpr char SETTINGS_PATH[] = "/.crosspoint/orbify_sleep/settings.json";
constexpr char SCOPES_PATH[] = "/.crosspoint/orbify_sleep/scopes.tsv";
constexpr char STORE_PATH[] = "/.crosspoint/orbify_sleep/state.bin";
constexpr char STORE_BAK[] = "/.crosspoint/orbify_sleep/state.bak";
constexpr char STORE_TMP[] = "/.crosspoint/orbify_sleep/state.tmp";
constexpr char REPLY_PATH[] = "/.crosspoint/orbify_sleep/reply.json";
constexpr char BAG_PATH[] = "/.crosspoint/orbify_sleep/bag.bin";

// Batch entry flags (core Entry::flags).
constexpr uint8_t READY = 0x01;    // <id>.bmp decoded
constexpr uint8_t CROP = 0x02;     // decoded for Crop (else Fit)
constexpr uint8_t LEGACY = 0x04;   // decoded with the legacy tone profile (a cover filter is on)
constexpr uint8_t HIDDEN = 0x08;   // a Leave out list is not complete yet: not shown (X7)
constexpr uint8_t TAGS_OK = 0x10;  // checked against the tag rules of rulesStamp

// The top-up's share of the sleep sync (whose watcher bounds the whole at 240 s).
constexpr unsigned long TOP_UP_BUDGET_MS = 40000;
// A radio-off decode: JPEGDEC and its buffers go to PSRAM (malloc puts blocks over 4 KB there).
constexpr size_t DECODE_MIN_PSRAM_BLOCK = 96 * 1024;
constexpr uint32_t BAG_MAGIC = 0x4741424Fu;  // "OBAG"
constexpr uint32_t LO_MAGIC = 0x534C4F4Fu;   // "OOLS"

Settings s_settings;
bool s_loaded = false;

// --- small helpers --------------------------------------------------------------------------------------

uint32_t nowEpoch() {
  const time_t now = time(nullptr);
  return now >= static_cast<time_t>(1704067200) ? static_cast<uint32_t>(now) : 0;
}

bool due(const uint32_t at, const uint32_t now) { return at == 0 || now == 0 || now < at || now - at >= DAY_S; }

uint32_t randomBelow(const uint32_t n, void*) {
#ifdef SIMULATOR
  return static_cast<uint32_t>(std::rand()) % n;
#else
  return esp_random() % n;
#endif
}

// Id buffers: PSRAM on the X4s, so a listing never takes the sync's internal RAM.
uint32_t* allocIds(const size_t n) {
  void* p = heap_caps_malloc(n * sizeof(uint32_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!p) p = heap_caps_malloc(n * sizeof(uint32_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  return static_cast<uint32_t*>(p);
}
struct Ids {
  uint32_t* p = nullptr;
  size_t n = 0;
  size_t cap = 0;
  explicit Ids(const size_t capacity) : p(allocIds(capacity)), cap(p ? capacity : 0) {}
  ~Ids() { heap_caps_free(p); }
  Ids(const Ids&) = delete;
  Ids& operator=(const Ids&) = delete;
  void add(const uint32_t id) {
    if (n < cap && id) p[n++] = id;
  }
};

void coverPath(const uint32_t id, const char* ext, char* out, const size_t size) {
  std::snprintf(out, size, "%s/%" PRIu32 ".%s", DIR, id, ext);
}

void removeCover(const uint32_t id) {
  char path[64];
  for (const char* ext : {"bmp", "jpg", "tmp"}) {
    coverPath(id, ext, path, sizeof(path));
    if (Storage.exists(path)) Storage.remove(path);
  }
}

// A set as one log line ("a, b").
std::string oneLine(std::string text) {
  for (size_t i = text.find('\n'); i != std::string::npos; i = text.find('\n', i)) text.replace(i, 1, ", ");
  return text;
}

uint32_t jsonId(JsonVariantConst v) {
  if (v.is<const char*>()) return static_cast<uint32_t>(std::strtoul(v.as<const char*>(), nullptr, 10));
  return v.as<uint32_t>();
}

bool parseReply(JsonDocument& filter, JsonDocument& doc) {
  HalFile file;
  if (!Storage.openFileForRead(TAG, REPLY_PATH, file)) return false;
  struct Reader {
    HalFile& f;
    int read() { return f.read(); }
    size_t readBytes(char* b, size_t n) {
      const int r = f.read(b, n);
      return r > 0 ? static_cast<size_t>(r) : 0;
    }
  } reader{file};
  const bool ok = !deserializeJson(doc, reader, DeserializationOption::Filter(filter));
  file.close();
  return ok;
}

// GET on the sync's session (the lent connection), the reply parsed into PSRAM through a filter.
bool getJson(const std::string& path, JsonDocument& filter, JsonDocument& doc) {
  if (!OrbifyHeap::roomForRequest("Sleep screen")) return false;
  const int code = BookOrbitSyncClient::orbifyRequest("GET", path, nullptr, REPLY_PATH);
  const bool ok = code >= 200 && code < 300 && parseReply(filter, doc);
  if (!ok) LOG_INF(TAG, "Sleep screen: %s failed (http %d)", path.c_str(), code);
  Storage.remove(REPLY_PATH);
  return ok;
}

// --- settings ---------------------------------------------------------------------------------------------

template <typename E>
E enumOf(const int v, const int count, const E fallback) {
  return v >= 0 && v < count ? static_cast<E>(v) : fallback;
}

void loadSettings() {
  s_loaded = true;
  std::string text;
  if (!Storage.exists(SETTINGS_PATH) || !Storage.readFileToString(TAG, SETTINGS_PATH, 4096, text)) return;
  JsonDocument doc;
  if (deserializeJson(doc, text)) return;
  Settings s;
  s.pick = doc["pick"] | false;
  char set[1024];
  s.from = normalizeSources(doc["from"] | "up_next", set, sizeof(set)) ? set : "up_next";
  s.leaveTags = doc["leaveTags"] | "";
  // Leave Out Scopes holds the member rules and Library (tags have their own row).
  std::string scopes = doc["leaveScopes"] | "";
  for (char& c : scopes) {
    if (c == ',') c = '\n';
  }
  s.leaveScopes = normalizeRules(scopes.c_str(), set, sizeof(set)) ? set : "";
  s.hours = cleanHours(doc["hours"] | DEFAULT_HOURS);
  char clean[4 * TEXT_MAX + 1];
  cleanText(doc["text"] | "", clean, sizeof(clean));
  s.text = clean;
  s.battery = doc["battery"] | false;
  s.style = enumOf<Style>(doc["style"] | 0, 2, Style::Bar);
  s.textPos = enumOf<TextPos>(doc["textPos"] | 0, 4, TextPos::Right);
  s.batteryCorner = enumOf<Corner>(doc["corner"] | 2, 4, Corner::BottomLeft);
  s_settings = s;
}

// --- the store ---------------------------------------------------------------------------------------------

bool readStore(const char* path, Store& out) {
  if (!Storage.exists(path)) return false;
  HalFile file;
  if (!Storage.openFileForRead(TAG, path, file)) return false;
  uint8_t buf[STORE_BYTES];
  const int n = file.read(buf, sizeof(buf));
  file.close();
  return n == static_cast<int>(sizeof(buf)) && parse(buf, sizeof(buf), out);
}

Store loadStore() {
  Store s;
  if (readStore(STORE_PATH, s) || readStore(STORE_BAK, s)) return s;
  return Store{};
}

// The new record goes to a temporary file first; the previous one stays as the backup slot.
void saveStore(const Store& s) {
  uint8_t buf[STORE_BYTES];
  if (!serialize(s, buf, sizeof(buf))) return;
  Storage.mkdir(DIR);
  HalFile file;
  if (!Storage.openFileForWrite(TAG, STORE_TMP, file)) return;
  const bool ok = file.write(buf, sizeof(buf)) == sizeof(buf);
  file.sync();
  file.close();
  if (!ok) {
    Storage.remove(STORE_TMP);
    LOG_ERR(TAG, "Sleep screen: state not saved");
    return;
  }
  if (Storage.exists(STORE_BAK)) Storage.remove(STORE_BAK);
  if (Storage.exists(STORE_PATH)) Storage.rename(STORE_PATH, STORE_BAK);
  Storage.rename(STORE_TMP, STORE_PATH);
}

int64_t openBookId(const std::string& path) {
  int64_t id = 0;
  return !path.empty() && BookOrbitDownloadIndex::bookIdForPath(path, id) ? id : 0;
}

uint8_t batteryNow() {
  const uint16_t level = powerManager.getBatteryPercentage();
  return level > 100 ? 100 : static_cast<uint8_t>(level);
}

}  // namespace

const Settings& settings() {
  if (!s_loaded) loadSettings();
  return s_settings;
}

Settings& edit() {
  if (!s_loaded) loadSettings();
  return s_settings;
}

void save() {
  JsonDocument doc;
  doc["pick"] = s_settings.pick;
  doc["from"] = s_settings.from;
  doc["leaveTags"] = s_settings.leaveTags;
  doc["leaveScopes"] = s_settings.leaveScopes;
  doc["hours"] = s_settings.hours;
  doc["text"] = s_settings.text;
  doc["battery"] = s_settings.battery;
  doc["style"] = static_cast<int>(s_settings.style);
  doc["textPos"] = static_cast<int>(s_settings.textPos);
  doc["corner"] = static_cast<int>(s_settings.batteryCorner);
  std::string out;
  serializeJson(doc, out);
  Storage.mkdir(DIR);
  if (!Storage.writeFile(SETTINGS_PATH, String(out.c_str()))) LOG_ERR(TAG, "Sleep screen: settings not saved");
}

bool readScopes(void (*each)(const Scope&, void* ctx), void* ctx) {
  std::string text;
  if (!Storage.exists(SCOPES_PATH) || !Storage.readFileToString(TAG, SCOPES_PATH, 16384, text)) return false;
  size_t at = 0;
  while (at < text.size()) {
    size_t end = text.find('\n', at);
    if (end == std::string::npos) end = text.size();
    const std::string line = text.substr(at, end - at);
    at = end + 1;
    // kind \t id \t count \t title
    const size_t t1 = line.find('\t');
    const size_t t2 = t1 == std::string::npos ? t1 : line.find('\t', t1 + 1);
    const size_t t3 = t2 == std::string::npos ? t2 : line.find('\t', t2 + 1);
    if (t3 == std::string::npos) continue;
    Scope s;
    s.collection = line[0] == 'c';
    s.id = static_cast<uint32_t>(std::strtoul(line.c_str() + t1 + 1, nullptr, 10));
    s.count = std::atoi(line.c_str() + t2 + 1);
    s.title = line.substr(t3 + 1);
    if (s.id) each(s, ctx);
  }
  return true;
}

// --- at sleep -----------------------------------------------------------------------------------------------

bool active() { return settings().pick; }

namespace {
Check memberCheck(const Settings& s, uint32_t id);  // the sleep sync's section below
}  // namespace

bool pickCover(const bool redraw, std::string& bmpPath) {
  const Settings& s = settings();
  Store st = loadStore();
  // The covers it may show: decoded, not held back by an incomplete Leave out list or unchecked tags,
  // and never the book open now (R2).
  const bool tagRules = hasTagRules(s.leaveTags.c_str());
  const bool rulesChanged = st.rulesStamp != fnv1a(s.leaveScopes.c_str(), fnv1a(s.leaveTags.c_str()));
  const int64_t open = openBookId(APP_STATE.openEpubPath);
  Entry pool[BATCH];
  size_t at[BATCH];
  size_t n = 0;
  for (size_t i = 0; i < st.batch.count; i++) {
    const Entry& e = st.batch.entries[i];
    if (!(e.flags & READY) || (e.flags & HIDDEN) || (tagRules && (!(e.flags & TAGS_OK) || rulesChanged))) continue;
    // Leave out as set now (Library, smart scopes, collections), from the lists on the card (X7, X8).
    if (memberCheck(s, e.id) != Check::Keep) continue;
    if (open > 0 && e.id == static_cast<uint64_t>(open)) continue;
    pool[n] = e;
    at[n++] = i;
  }
  const uint32_t epoch = nowEpoch();
  const uint64_t now = static_cast<uint64_t>(epoch) * 1000ULL;
  const Decision d =
      decide(Mode::Recommended, s.hours, now, pool, n, true, st.state, !redraw, randomBelow, nullptr);
  for (size_t i = 0; i < n; i++) st.batch.entries[at[i]].shows = pool[i].shows;
  const bool bag = hasMemberSources(s.from.c_str());
  if (d.show == Show::Pool && bag && s.hours != EVERY_SLEEP) {
    // From a bag in hours mode, a cover shown once makes room for the bag's next (core usedUp).
    const int i = st.batch.indexOf(d.id);
    if (i >= 0 && st.batch.entries[i].shows == 0) st.batch.entries[i].shows = 1;
  }
  if (!redraw) st.battery = batteryNow();
  saveStore(st);
  const char* why = s.hours == EVERY_SLEEP ? "every sleep" : (epoch ? "by the hours" : "no clock: kept");
  if (d.show != Show::Pool) {
    LOG_INF(TAG, "Sleep: BookOrbit Pick -> current book (%u of %u covers ready%s)", static_cast<unsigned>(n),
            static_cast<unsigned>(st.batch.count), redraw ? ", redraw" : "");
    return false;
  }
  char path[64];
  coverPath(d.id, "bmp", path, sizeof(path));
  bmpPath = path;
  LOG_INF(TAG, "Sleep: BookOrbit Pick -> cover %" PRIu32 " (%s, %u ready, shown %u times%s)", d.id, why,
          static_cast<unsigned>(n), static_cast<unsigned>(st.batch.entries[std::max(0, st.batch.indexOf(d.id))].shows),
          redraw ? ", redraw" : "");
  return true;
}

void coverFailed(const std::string& bmpPath) {
  const char* name = std::strrchr(bmpPath.c_str(), '/');
  const uint32_t id = name ? static_cast<uint32_t>(std::strtoul(name + 1, nullptr, 10)) : 0;
  if (!id) return;
  Store st = loadStore();
  st.batch.remove(id);
  if (st.state.shown == id) st.state.shown = 0;
  saveStore(st);
  removeCover(id);
  LOG_ERR(TAG, "Sleep: cover %" PRIu32 " did not draw: removed, fetched again by a sync", id);
}

// --- the extras -------------------------------------------------------------------------------------------

namespace {
constexpr int ICON_W = 22;
constexpr int ICON_H = 11;
constexpr int ICON_GAP = 4;

struct Extras {
  bool text = false;
  bool battery = false;
  int level = 0;
  char levelText[8] = {};
};

Extras extrasFor(const bool redraw) {
  const Settings& s = settings();
  Extras e;
  e.text = !s.text.empty();
  e.battery = s.battery;
  if (e.battery) {
    // One level per pass (the extras draw once per grey plane): the first pass records it in the
    // store, and the sleep sync's redraw, a new boot, draws the same.
    static uint8_t level = 0xFF;
    if (level > 100 && redraw) level = loadStore().battery;
    if (level > 100) {
      level = batteryNow();
      Store st = loadStore();
      if (st.battery != level) {
        st.battery = level;
        saveStore(st);
      }
    }
    e.level = level;
    std::snprintf(e.levelText, sizeof(e.levelText), "%d%%", e.level);
  }
  return e;
}

int batteryWidth(const GfxRenderer& r, const Extras& e) {
  return e.battery ? ICON_W + 2 + ICON_GAP + r.getTextWidth(UI_12_FONT_ID, e.levelText) : 0;
}

// The battery at (x, top): an outline with a nub, filled to the level, then the percent (L4).
void drawBattery(const GfxRenderer& r, const int x, const int top, const int lineH, const Extras& e) {
  const int iy = top + (lineH - ICON_H) / 2;
  r.drawRect(x, iy, ICON_W, ICON_H, true);
  r.fillRect(x + ICON_W, iy + 3, 2, ICON_H - 6, true);
  const int fill = (ICON_W - 4) * e.level / 100;
  if (fill > 0) r.fillRect(x + 2, iy + 2, fill, ICON_H - 4, true);
  r.drawText(UI_12_FONT_ID, x + ICON_W + 2 + ICON_GAP, top, e.levelText, true);
}

// A plate: white (or "no grey" in a relative grey plane) with a 1-px black outline (L3d).
void plate(const GfxRenderer& r, const Box& b, const bool plateState) {
  r.fillRect(b.left, b.top, b.width(), b.height(), plateState);
  r.drawRect(b.left, b.top, b.width(), b.height(), true);
}
}  // namespace

bool extrasOn() {
  const Settings& s = settings();
  return !s.text.empty() || s.battery;
}

int bandHeight(const GfxRenderer& renderer) {
  const Settings& s = settings();
  if (!extrasOn() || s.style != Style::Bar) return 0;
  int lines = 0;
  if (!s.text.empty()) {
    // The widest battery label: the band's lines do not depend on the level.
    Extras e;
    e.battery = s.battery;
    std::snprintf(e.levelText, sizeof(e.levelText), "100%%");
    const int w = renderer.getScreenWidth();
    const int h = renderer.getScreenHeight();
    const int maxW = maxTextWidth(w, h, Style::Bar, s.textPos, renderer.getLineHeight(UI_12_FONT_ID) / 2,
                                  batteryWidth(renderer, e));
    lines = static_cast<int>(renderer.wrappedText(UI_12_FONT_ID, s.text.c_str(), maxW, 2).size());
  }
  return orbify::sleep::bandHeight(renderer.getScreenHeight(), lines);
}

void drawExtras(const GfxRenderer& r, const bool redraw) {
  if (!extrasOn()) return;
  const Settings& s = settings();
  const Extras e = extrasFor(redraw);
  const auto orientation = r.getOrientation();
  const_cast<GfxRenderer&>(r).setOrientation(GfxRenderer::Orientation::Portrait);
  const int w = r.getScreenWidth();
  const int h = r.getScreenHeight();
  const int font = UI_12_FONT_ID;
  const int lineH = r.getLineHeight(font);
  const int pad = lineH / 2;
  // In a relative grey plane "white" is the cleared value; elsewhere it is a set bit (state false).
  const bool plateState = r.getRenderMode() != GfxRenderer::BW && !r.grayPlanesAreAbsolute();
  const int batW = batteryWidth(r, e);

  if (s.style == Style::Bar) {
    std::vector<std::string> lines;
    if (e.text) lines = r.wrappedText(font, s.text.c_str(), maxTextWidth(w, h, Style::Bar, s.textPos, pad, batW), 2);
    const int bandH = orbify::sleep::bandHeight(h, static_cast<int>(lines.size()));
    const BarLayout b = bar(w, h, bandH);
    r.fillRect(0, h - bandH, w, bandH, plateState);
    r.fillRect(0, h - bandH, w, 2, true);
    const int textTop = b.band.top + (b.band.height() - static_cast<int>(lines.size()) * lineH) / 2;
    for (size_t i = 0; i < lines.size(); i++) {
      r.drawText(font, b.textLeft, textTop + static_cast<int>(i) * lineH, lines[i].c_str(), true);
    }
    if (e.battery) drawBattery(r, b.batteryRight - batW, b.band.top + (b.band.height() - lineH) / 2, lineH, e);
  } else {
    if (e.text) {
      const int maxW = maxTextWidth(w, h, Style::Overlay, s.textPos, pad, 0);
      if (vertical(s.textPos)) {
        const std::string line = r.truncatedText(font, s.text.c_str(), maxW);
        const Box p = textPlate(w, h, s.textPos, r.getTextWidth(font, line.c_str()), lineH, pad);
        plate(r, p, plateState);
        // Rotated with the renderer itself (L3e): Right reads top to bottom (the panel's own
        // landscape), Left bottom to top; the letters' tops face the edge either way.
        if (s.textPos == TextPos::Right) {
          const_cast<GfxRenderer&>(r).setOrientation(GfxRenderer::Orientation::LandscapeCounterClockwise);
          r.drawText(font, p.top + pad, w - p.right + pad, line.c_str(), true);
        } else {
          const_cast<GfxRenderer&>(r).setOrientation(GfxRenderer::Orientation::LandscapeClockwise);
          r.drawText(font, h - p.bottom + pad, p.left + pad, line.c_str(), true);
        }
        const_cast<GfxRenderer&>(r).setOrientation(GfxRenderer::Orientation::Portrait);
      } else {
        const auto lines = r.wrappedText(font, s.text.c_str(), maxW, 2);
        int textW = 0;
        for (const auto& l : lines) textW = std::max(textW, r.getTextWidth(font, l.c_str()));
        const Box p = textPlate(w, h, s.textPos, textW, static_cast<int>(lines.size()) * lineH, pad);
        plate(r, p, plateState);
        for (size_t i = 0; i < lines.size(); i++) {
          const int lw = r.getTextWidth(font, lines[i].c_str());
          r.drawText(font, p.left + (p.width() - lw) / 2, p.top + pad + static_cast<int>(i) * lineH, lines[i].c_str(),
                     true);
        }
      }
    }
    if (e.battery) {
      const Corner corner = batteryCorner(s.batteryCorner, s.textPos, e.text);
      const Box p = batteryPlate(w, h, corner, batW, lineH, pad);
      plate(r, p, plateState);
      drawBattery(r, p.left + pad, p.top + pad, lineH, e);
    }
  }
  const_cast<GfxRenderer&>(r).setOrientation(orientation);
}

// --- the sleep sync --------------------------------------------------------------------------------------

namespace {

struct Run {
  bool (*stop)() = nullptr;
  unsigned long deadline = 0;
  int pagesLeft = PAGES_PER_SLEEP;
  bool over() const { return (stop && stop()) || static_cast<long>(millis() - deadline) >= 0; }
};

// The account's smart scopes and collections (first 100 of each), for Pick From's and Leave Out
// Scopes' lists in Settings, which never go online themselves.
bool saveScopes() {
  std::string out;
  for (const char* section : {"smart-scopes", "collections"}) {
    JsonDocument filter;
    filter["items"][0]["id"] = true;
    filter["items"][0]["title"] = true;
    filter["items"][0]["count"] = true;
    JsonDocument doc(OrbifyHeap::jsonAllocator());
    if (!getJson(std::string("/plugin/catalog/sections/") + section + "?page=1&size=100", filter, doc)) return false;
    for (JsonObjectConst item : doc["items"].as<JsonArrayConst>()) {
      const uint32_t id = jsonId(item["id"]);
      std::string title = item["title"] | "";
      for (char& c : title) {
        if (c == '\t' || c == '\n' || c == '\r') c = ' ';
      }
      if (!id) continue;
      char head[40];
      std::snprintf(head, sizeof(head), "%c\t%" PRIu32 "\t%d\t", section[0] == 'c' ? 'c' : 's', id,
                    item["count"] | 0);
      out += head;
      out += title;
      out += '\n';
    }
  }
  Storage.mkdir(DIR);
  return Storage.writeFile(SCOPES_PATH, String(out.c_str()));
}

// One more page of a books listing, its ids appended to `part` (kept on the card between sleeps).
// The file starts with the next page to ask for. Returns true when the listing is complete
// (`ids` then holds all of it).
bool listPages(const char* query, const char* partPath, Ids& ids, Run& run, const bool eligibleOnly) {
  uint32_t page = 1;
  if (Storage.exists(partPath)) {
    HalFile f;
    if (Storage.openFileForRead(TAG, partPath, f)) {
      uint32_t head = 0;
      if (f.read(&head, 4) == 4) page = head;
      uint32_t id = 0;
      while (ids.n < ids.cap && f.read(&id, 4) == 4) ids.add(id);
      f.close();
    }
  }
  bool complete = false;
  while (!complete && run.pagesLeft > 0 && !run.over()) {
    run.pagesLeft--;
    JsonDocument filter;
    filter["items"][0]["id"] = true;
    if (eligibleOnly) {
      filter["items"][0]["hasCover"] = true;
      filter["items"][0]["readStatus"] = true;
    }
    filter["hasNext"] = true;
    JsonDocument doc(OrbifyHeap::jsonAllocator());
    char path[192];
    std::snprintf(path, sizeof(path), "/plugin/catalog/books?page=%" PRIu32 "&size=%d&sort=recently_added&order=desc%s%s",
                  page, PAGE_SIZE, *query ? "&" : "", query);
    if (!getJson(path, filter, doc)) return false;
    for (JsonObjectConst item : doc["items"].as<JsonArrayConst>()) {
      if (eligibleOnly && (item["hasCover"] == false || std::strcmp(item["readStatus"] | "", "read") == 0)) continue;
      ids.add(jsonId(item["id"]));
    }
    page++;
    complete = !(doc["hasNext"] | false) || ids.n >= ids.cap;
  }
  if (complete) {
    if (Storage.exists(partPath)) Storage.remove(partPath);
    if (ids.n >= ids.cap) LOG_INF(TAG, "Sleep screen: %s lists over %u books: using the newest %u", query,
                                  static_cast<unsigned>(ids.cap), static_cast<unsigned>(ids.cap));
    return true;
  }
  // Carried to the next sleep.
  HalFile f;
  if (Storage.openFileForWrite(TAG, partPath, f)) {
    f.write(&page, 4);
    f.write(ids.p, ids.n * 4);
    f.close();
  }
  return false;
}

// --- Leave out's member lists: a sorted uint32 file per rule, searched in place (X5) -------------------

// A Pick from source's members, in the server's order (eligible books only).
void sourcePath(const From& f, char* out, const size_t size, const char* ext) {
  const char k = f.kind == FromKind::Library ? 'l' : (f.kind == FromKind::Scope ? 's' : 'c');
  std::snprintf(out, size, "%s/src_%c%" PRIu32 ".%s", DIR, k, f.id, ext);
}

void memberPath(const From& f, char* out, const size_t size, const char* ext) {
  std::snprintf(out, size, "%s/lo_%c%" PRIu32 ".%s", DIR, f.kind == FromKind::Scope ? 's' : 'c', f.id, ext);
}

struct MemberFile {
  HalFile f;
  uint32_t at = 0;
  uint32_t count = 0;
};

bool openMembers(const From& rule, MemberFile& m) {
  char path[64];
  memberPath(rule, path, sizeof(path), "bin");
  if (!Storage.exists(path) || !Storage.openFileForRead(TAG, path, m.f)) return false;
  uint32_t head[3] = {};
  if (m.f.read(head, sizeof(head)) != static_cast<int>(sizeof(head)) || head[0] != LO_MAGIC) {
    m.f.close();
    return false;
  }
  m.at = head[1];
  m.count = head[2];
  return true;
}

bool readMember(const size_t i, uint32_t* id, void* ctx) {
  auto* m = static_cast<MemberFile*>(ctx);
  return m->f.seek(12 + i * 4) && m->f.read(id, 4) == 4;
}

// Every member rule against one book: Out, Keep, or Unknown while a list is not complete (X7).
Check memberCheck(const Settings& s, const uint32_t id) {
  // Library leaves out every book (X8): the sleep shows the current book (F1).
  if (hasLibrary(s.leaveScopes.c_str())) return Check::Out;
  Check result = Check::Keep;
  From rule;
  for (const char* p = nextScopeRule(s.leaveScopes.c_str(), rule); p; p = nextScopeRule(p, rule)) {
    MemberFile m;
    if (!openMembers(rule, m)) {
      result = combine(result, Check::Unknown);
      continue;
    }
    const bool in = sortedContains(id, m.count, readMember, &m);
    m.f.close();
    if (in) return Check::Out;
  }
  return result;
}

void refreshMembers(const Settings& s, const uint32_t now, Run& run) {
  From rule;
  for (const char* p = nextScopeRule(s.leaveScopes.c_str(), rule); p && !run.over(); p = nextScopeRule(p, rule)) {
    MemberFile m;
    const bool have = openMembers(rule, m);
    if (have) m.f.close();
    if (have && !due(m.at, now)) continue;
    Ids ids(LEAVE_OUT_MAX);
    if (!ids.p) return;
    char part[64];
    memberPath(rule, part, sizeof(part), "part");
    char query[48];
    std::snprintf(query, sizeof(query), "%s=%" PRIu32, rule.kind == FromKind::Scope ? "smartScopeId" : "collectionId",
                  rule.id);
    if (!listPages(query, part, ids, run, false)) continue;
    ids.n = sortUnique(ids.p, ids.n);
    char path[64];
    memberPath(rule, path, sizeof(path), "bin");
    HalFile f;
    if (!Storage.openFileForWrite(TAG, path, f)) continue;
    const uint32_t head[3] = {LO_MAGIC, now, static_cast<uint32_t>(ids.n)};
    f.write(head, sizeof(head));
    f.write(ids.p, ids.n * 4);
    f.close();
    LOG_INF(TAG, "Sleep screen: Leave out %s %" PRIu32 " lists %u books", rule.kind == FromKind::Scope ? "scope" : "collection",
            rule.id, static_cast<unsigned>(ids.n));
  }
}

// --- the bag file ----------------------------------------------------------------------------------------

struct BagFile {
  uint32_t stamp = 0;
  uint32_t at = 0;
  Bag bag;
};

bool loadBag(BagFile& b, const uint32_t stamp) {
  b.bag.count = b.bag.pos = 0;
  b.bag.prev = 0;
  b.at = 0;
  b.stamp = stamp;
  if (!Storage.exists(BAG_PATH)) return true;
  HalFile f;
  if (!Storage.openFileForRead(TAG, BAG_PATH, f)) return true;
  uint32_t head[6] = {};
  if (f.read(head, sizeof(head)) == static_cast<int>(sizeof(head)) && head[0] == BAG_MAGIC && head[1] == stamp) {
    b.at = head[2];
    const size_t count = std::min<size_t>(head[5], b.bag.capacity);
    const int bytes = f.read(b.bag.order, count * 4);
    b.bag.count = bytes > 0 ? static_cast<size_t>(bytes) / 4 : 0;
    b.bag.pos = std::min<size_t>(head[3], b.bag.count);
    b.bag.prev = head[4];
  }
  f.close();
  return true;
}

void saveBag(const BagFile& b) {
  HalFile f;
  if (!Storage.openFileForWrite(TAG, BAG_PATH, f)) return;
  const uint32_t head[6] = {BAG_MAGIC, b.stamp, b.at, static_cast<uint32_t>(b.bag.pos), b.bag.prev,
                            static_cast<uint32_t>(b.bag.count)};
  f.write(head, sizeof(head));
  f.write(b.bag.order, b.bag.count * 4);
  f.close();
}

// One dashboard list into the store's slot for it: eligible books in the server's order.
bool fetchList(const FromKind kind, Store& st) {
  JsonDocument filter;
  filter["section"]["books"][0]["id"] = true;
  filter["section"]["books"][0]["hasCover"] = true;
  filter["section"]["books"][0]["readStatus"] = true;
  JsonDocument doc(OrbifyHeap::jsonAllocator());
  if (!getJson(std::string("/plugin/catalog/dashboard/sections/") + sectionType(kind), filter, doc)) return false;
  const size_t k = static_cast<size_t>(kind);
  uint8_t count = 0;
  for (JsonObjectConst b : doc["section"]["books"].as<JsonArrayConst>()) {
    const uint32_t id = jsonId(b["id"]);
    if (!id || b["hasCover"] == false || std::strcmp(b["readStatus"] | "", "read") == 0) continue;
    if (count < BATCH) st.list[k][count++] = id;
  }
  st.listCount[k] = count;
  return true;
}

// Every picked library, scope and collection listed (each its own file, re-listed once a day, 10 pages
// per sleep in all); `members` gets their union in order, a book once, up to BAG_MAX. False while a
// source has never been listed in full.
bool listBagSources(const Settings& s, const uint32_t now, Run& run, Ids& members) {
  bool complete = true;
  From f;
  for (const char* p = nextFrom(s.from.c_str(), f); p; p = nextFrom(p, f)) {
    if (isList(f.kind)) continue;
    char path[64], part[64];
    sourcePath(f, path, sizeof(path), "bin");
    sourcePath(f, part, sizeof(part), "part");
    uint32_t head[3] = {};
    bool have = false;
    {
      HalFile file;
      if (Storage.exists(path) && Storage.openFileForRead(TAG, path, file)) {
        have = file.read(head, sizeof(head)) == static_cast<int>(sizeof(head)) && head[0] == LO_MAGIC;
        file.close();
      }
    }
    if ((!have || due(head[1], now)) && !run.over()) {
      Ids ids(BAG_MAX);
      char query[48] = "";
      if (f.kind != FromKind::Library) {
        std::snprintf(query, sizeof(query), "%s=%" PRIu32, f.kind == FromKind::Scope ? "smartScopeId" : "collectionId",
                      f.id);
      }
      if (ids.p && listPages(query, part, ids, run, true)) {
        HalFile out;
        if (Storage.openFileForWrite(TAG, path, out)) {
          const uint32_t h[3] = {LO_MAGIC, now, static_cast<uint32_t>(ids.n)};
          out.write(h, sizeof(h));
          out.write(ids.p, ids.n * 4);
          out.close();
          have = true;
          LOG_INF(TAG, "Sleep screen: Pick from %s lists %u books", f.kind == FromKind::Library ? "library" : path,
                  static_cast<unsigned>(ids.n));
        }
      }
    }
    if (!have) {
      complete = false;
      continue;
    }
    HalFile file;
    if (!Storage.openFileForRead(TAG, path, file)) continue;
    file.read(head, sizeof(head));
    uint32_t id = 0;
    for (uint32_t i = 0; i < head[2] && members.n < members.cap && file.read(&id, 4) == 4; i++) {
      bool seen = false;
      for (size_t j = 0; j < members.n && !seen; j++) seen = members.p[j] == id;
      if (!seen) members.add(id);
    }
    file.close();
  }
  return complete;
}

// --- one book's detail: tags (Leave out), and a bag book's own checks -------------------------------------

enum class Probe : uint8_t { Keep, Skip, Out, Failed };

Probe probe(const uint32_t id, const Settings& s) {
  JsonDocument filter;
  filter["hasCover"] = true;
  filter["readStatus"] = true;
  filter["tags"] = true;
  JsonDocument doc(OrbifyHeap::jsonAllocator());
  char path[96];
  std::snprintf(path, sizeof(path), "/plugin/catalog/books/%" PRIu32 "?deviceId=%s", id, BookOrbitSyncClient::deviceId());
  if (!getJson(path, filter, doc)) return Probe::Failed;
  if (doc["hasCover"] == false || std::strcmp(doc["readStatus"] | "", "read") == 0) return Probe::Skip;
  for (JsonVariantConst t : doc["tags"].as<JsonArrayConst>()) {
    const char* tag = t.is<const char*>() ? t.as<const char*>() : (t["name"] | "");
    if (tagMatches(s.leaveTags.c_str(), tag)) return Probe::Out;
  }
  return Probe::Keep;
}

}  // namespace

void topUp(const std::string& openBookPath, bool (*stop)()) {
  const Settings& s = settings();
  if (!s.pick || !BOOKORBIT_STORE.hasCredentials()) return;
  Run run;
  run.stop = stop;
  run.deadline = millis() + TOP_UP_BUDGET_MS;
  const uint32_t now = nowEpoch();
  Store st = loadStore();
  Storage.mkdir(DIR);

  // Pick from is a set (R1c): the dashboard lists picked, and one bag over every picked library, smart
  // scope and collection.
  const bool isBag = hasMemberSources(s.from.c_str());
  const bool every = s.hours == EVERY_SLEEP;
  // Another source: the batch starts again (its covers were another list's).
  const uint32_t sourceStamp = fnv1a(s.from.c_str());
  if (st.sourceStamp != sourceStamp) {
    for (size_t i = 0; i < st.batch.count; i++) removeCover(st.batch.entries[i].id);
    const uint8_t battery = st.battery;
    st = Store{};
    st.battery = battery;
    st.sourceStamp = sourceStamp;
    if (Storage.exists(BAG_PATH)) Storage.remove(BAG_PATH);
    LOG_INF(TAG, "Sleep screen: Pick from is now %s; the batch starts again", oneLine(s.from).c_str());
  }
  // Other rules: every cover is checked again before it shows.
  const uint32_t rulesStamp = fnv1a(s.leaveScopes.c_str(), fnv1a(s.leaveTags.c_str()));
  if (st.rulesStamp != rulesStamp) {
    for (size_t i = 0; i < st.batch.count; i++) st.batch.entries[i].flags &= static_cast<uint8_t>(~TAGS_OK);
    st.rulesStamp = rulesStamp;
  }
  const bool tagRules = hasTagRules(s.leaveTags.c_str());
  const int64_t open = openBookId(openBookPath);

  if (due(st.scopesAt, now) && !run.over() && saveScopes()) st.scopesAt = now;
  refreshMembers(s, now, run);

  // The candidates, in the order they would be shown.
  Ids candidates(BAG_MAX + LIST_KINDS * BATCH);
  BagFile bagFile;
  bagFile.bag.order = allocIds(BAG_MAX);
  bagFile.bag.capacity = bagFile.bag.order ? BAG_MAX : 0;
  if (!candidates.p || !bagFile.bag.order) {
    heap_caps_free(bagFile.bag.order);
    LOG_ERR(TAG, "Sleep screen: no memory for the lists; next sync");
    return;
  }
  // The picked dashboard lists, once a day.
  bool picked[LIST_KINDS] = {};
  {
    From f;
    for (const char* p = nextFrom(s.from.c_str(), f); p; p = nextFrom(p, f)) {
      if (isList(f.kind)) picked[static_cast<size_t>(f.kind)] = true;
    }
  }
  if (due(st.listAt, now) && !run.over()) {
    bool all = true;
    for (size_t k = 0; k < LIST_KINDS && !run.over(); k++) {
      // The picked lists, and a fallback list in use (R1).
      if (picked[k] || st.listCount[k]) all = fetchList(static_cast<FromKind>(k), st) && all;
    }
    if (all) st.listAt = now;
  }
  // The bag over the picked library, scopes and collections (each listed into its own file).
  const uint32_t* next = nullptr;
  size_t bagCount = 0;
  if (isBag) {
    loadBag(bagFile, sourceStamp);
    Ids members(BAG_MAX);
    if (members.p && listBagSources(s, now, run, members)) {
      bagSync(bagFile.bag, members.p, members.n, randomBelow, nullptr);
      bagFile.at = now;
    }
    bagCount = bagNext(bagFile.bag, randomBelow, nullptr, &next);
  }
  struct ListCtx {
    Store* st;
  } listCtx{&st};
  const auto listAt = [](const FromKind kind, size_t* count, void* ctx) -> const uint32_t* {
    Store& store = *static_cast<ListCtx*>(ctx)->st;
    const size_t k = static_cast<size_t>(kind);
    *count = store.listCount[k];
    return store.list[k];
  };
  const FromKind* fallback = nullptr;
  candidates.n = orbify::sleep::candidates(s.from.c_str(), listAt, &listCtx, next, bagCount, candidates.p, candidates.cap,
                                           &fallback);
  if (candidates.n == 0 && !run.over()) {
    // R1: every picked source is empty: Up next, Want to read, Discover (not picked), fetched now.
    for (size_t k = 0; k < LIST_KINDS && candidates.n == 0 && !run.over(); k++) {
      if (picked[k] || st.listCount[k]) continue;
      fetchList(static_cast<FromKind>(k), st);
      candidates.n = orbify::sleep::candidates(s.from.c_str(), listAt, &listCtx, next, bagCount, candidates.p,
                                               candidates.cap, &fallback);
    }
  }
  if (fallback) LOG_INF(TAG, "Sleep screen: every picked source is empty, using %s", sectionType(*fallback));

  // The batch as it stands: covers now left out go, unknown ones wait hidden (X7); a list source in
  // hours mode follows the list.
  uint32_t gone[BATCH];
  size_t goneCount = 0;
  if (!isBag && !every && candidates.n) {
    goneCount = st.batch.followList(candidates.p, std::min<size_t>(candidates.n, BATCH), gone);
  }
  for (size_t i = 0; i < st.batch.count;) {
    Entry& e = st.batch.entries[i];
    const Check c = memberCheck(s, e.id);
    if (c == Check::Out) {
      gone[goneCount < BATCH ? goneCount++ : BATCH - 1] = e.id;
      st.batch.remove(e.id);
      continue;
    }
    e.flags = static_cast<uint8_t>(c == Check::Unknown ? (e.flags | HIDDEN) : (e.flags & ~HIDDEN));
    if (!tagRules) e.flags |= TAGS_OK;
    i++;
  }
  // Covers kept from before the tag rules changed: checked again (a few per sync).
  size_t probes = 0;
  for (size_t i = 0; tagRules && i < st.batch.count && probes < PROBE_PER_SYNC && !run.over();) {
    Entry& e = st.batch.entries[i];
    if (e.flags & TAGS_OK) {
      i++;
      continue;
    }
    probes++;
    const Probe p = probe(e.id, s);
    if (p == Probe::Out || p == Probe::Skip) {
      gone[goneCount < BATCH ? goneCount++ : BATCH - 1] = e.id;
      st.batch.remove(e.id);
      continue;
    }
    if (p == Probe::Keep) e.flags |= TAGS_OK;
    i++;
  }
  for (size_t i = 0; i < goneCount; i++) removeCover(gone[i]);

  // Fresh covers: a few per sync, inside the budget.
  uint32_t fresh[BAG_MAX < 64 ? BAG_MAX : 64];
  const size_t freshCount = freshOrder(candidates.p, candidates.n, st.batch, nullptr, 0, fresh, sizeof(fresh) / 4);
  size_t fetched = 0, replacedCount = 0, leftOut = 0, unknown = 0, failed = 0;
  uint32_t taken[FETCH_PER_SYNC];
  size_t takenCount = 0;
  for (size_t i = 0; i < freshCount; i++) {
    if (fetched >= FETCH_PER_SYNC || st.batch.wanted(every, isBag, st.state.shown) == 0 || run.over()) break;
    const uint32_t id = fresh[i];
    if (open > 0 && id == static_cast<uint64_t>(open)) continue;
    const Check c = memberCheck(s, id);
    if (c != Check::Keep) {
      (c == Check::Out ? leftOut : unknown)++;
      continue;
    }
    uint8_t flags = tagRules ? 0 : TAGS_OK;
    if (tagRules) {
      if (probes >= PROBE_PER_SYNC) break;
      probes++;
      const Probe p = probe(id, s);
      if (p == Probe::Failed) break;
      if (p != Probe::Keep) {
        leftOut += p == Probe::Out;
        continue;
      }
      flags = TAGS_OK;
    }
    if (!OrbifyHeap::roomForRequest("Sleep cover")) break;
    char jpg[64];
    coverPath(id, "jpg", jpg, sizeof(jpg));
    const auto result = BookOrbitCatalogClient::downloadThumbnail(id, jpg, stop);
    if (result != HttpDownloader::OK) {
      Storage.remove(jpg);
      failed++;
      LOG_INF(TAG, "Sleep cover: book %" PRIu32 " not fetched (err=%d, http=%d)", id, static_cast<int>(result),
              HttpDownloader::lastHttpStatus);
      continue;
    }
    uint32_t replaced = 0;
    if (!st.batch.admit(id, every, isBag, st.state.shown, &replaced)) {
      Storage.remove(jpg);
      break;
    }
    st.batch.entries[st.batch.indexOf(id)].flags = flags;
    if (replaced) {
      removeCover(replaced);
      replacedCount++;
    }
    if (takenCount < FETCH_PER_SYNC) taken[takenCount++] = id;
    fetched++;
  }
  if (isBag) {
    bagTake(bagFile.bag, taken, takenCount);
    saveBag(bagFile);
  }
  heap_caps_free(bagFile.bag.order);
  saveStore(st);
  LOG_INF(TAG,
          "Sleep screen: batch %u of %u (%u fetched, %u retired, %u left out, %u waiting for Leave out, %u failed); "
          "source %s, %u candidates",
          static_cast<unsigned>(st.batch.count), static_cast<unsigned>(BATCH), static_cast<unsigned>(fetched),
          static_cast<unsigned>(replacedCount), static_cast<unsigned>(leftOut), static_cast<unsigned>(unknown),
          static_cast<unsigned>(failed), oneLine(s.from).c_str(), static_cast<unsigned>(candidates.n));
}

void decodeCovers(const GfxRenderer& renderer, bool (*stop)()) {
  if (!settings().pick) return;
  Store st = loadStore();
  const bool crop = SETTINGS.sleepScreenCoverMode == CrossPointSettings::SLEEP_SCREEN_COVER_MODE::CROP;
  const ImageToneProfile tone = SETTINGS.sleepScreenCoverFilter != CrossPointSettings::NO_FILTER
                                    ? ImageToneProfile::Legacy
                                    : imageToneProfile(renderer.supportsAbsoluteGrayscale());
  const uint8_t want = static_cast<uint8_t>(READY | (crop ? CROP : 0) | (tone == ImageToneProfile::Legacy ? LEGACY : 0));
  size_t decoded = 0;
  bool changed = false;
  for (size_t i = 0; i < st.batch.count;) {
    if (stop && stop()) break;
    Entry& e = st.batch.entries[i];
    if ((e.flags & (READY | CROP | LEGACY)) == want) {
      i++;
      continue;
    }
    char jpg[64], bmp[64], tmp[64];
    coverPath(e.id, "jpg", jpg, sizeof(jpg));
    coverPath(e.id, "bmp", bmp, sizeof(bmp));
    coverPath(e.id, "tmp", tmp, sizeof(tmp));
    if (!Storage.exists(jpg)) {
      // Decoded for another Fit/Crop or filter and its JPEG is gone: it still draws; else it goes.
      if (!(e.flags & READY)) {
        st.batch.remove(e.id);
        changed = true;
        continue;
      }
      i++;
      continue;
    }
    const size_t psram = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (psram < DECODE_MIN_PSRAM_BLOCK && heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0) {
      LOG_INF(TAG, "Sleep cover: decode waits for PSRAM (largest %u)", static_cast<unsigned>(psram));
      break;
    }
    HalFile in, out;
    bool ok = false;
    if (Storage.openFileForRead(TAG, jpg, in)) {
      if (Storage.openFileForWrite(TAG, tmp, out)) {
        ok = JpegToBmpConverter::jpegFileToBmpStream(in, out, crop, tone);
        out.close();
      }
      in.close();
    }
    if (ok && Storage.exists(bmp)) Storage.remove(bmp);
    if (ok) ok = Storage.rename(tmp, bmp);
    if (!ok) {
      // A bad file: it leaves, and the next sync fetches it again (F6).
      Storage.remove(tmp);
      Storage.remove(jpg);
      if (!(e.flags & READY)) {
        LOG_ERR(TAG, "Sleep cover: book %" PRIu32 " dropped (bad JPEG)", e.id);
        st.batch.remove(e.id);
        changed = true;
        continue;
      }
      i++;
      continue;
    }
    e.flags = static_cast<uint8_t>((e.flags & ~(READY | CROP | LEGACY)) | want);
    decoded++;
    changed = true;
    LOG_INF(TAG, "Sleep cover: book %" PRIu32 " decoded (%s, %ux%u)", e.id, crop ? "crop" : "fit",
            static_cast<unsigned>(renderer.getScreenWidth()), static_cast<unsigned>(renderer.getScreenHeight()));
    i++;
  }
  if (changed) saveStore(st);
  if (decoded) OrbifyHeap::logHeap("after the sleep covers' decode");
}

}  // namespace OrbifySleep

#endif
