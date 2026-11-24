#include "SleepSettings.h"

#if CROSSINK_TAILNET_ORBIFY_SLEEP

#include <I18n.h>

#include <cinttypes>
#include <cstdio>
#include <string>
#include <utility>

#include "CrossPointSettings.h"
#include "SleepScreen.h"
#include "activities/settings/SettingsActivity.h"

namespace OrbifySleep {

using namespace orbify::sleep;

// The list screens' items (defined below).
void choices(bool pick, std::vector<std::string>& labels, std::vector<std::string>& items);

namespace {

// Option labels are runtime strings (enumStringValues): only row names need StrIds.
const char* const STYLE_LABELS[] = {"Bar", "Overlay"};
const char* const POSITION_LABELS[] = {"Right", "Left", "Top", "Bottom"};
const char* const CORNER_LABELS[] = {"Top left", "Top right", "Bottom left", "Bottom right"};

std::vector<std::string> labels(const char* const* names, const size_t count) {
  return std::vector<std::string>(names, names + count);
}

// The smart scopes and collections the last sleep sync saved, read once per boot: Settings never
// goes online for them (design "Scope sources and Leave out on the X4s").
const std::vector<Scope>& scopes() {
  static std::vector<Scope> list;
  static bool loaded = false;
  if (!loaded) {
    loaded = true;
    readScopes([](const Scope& s, void* ctx) { static_cast<std::vector<Scope>*>(ctx)->push_back(s); }, &list);
  }
  return list;
}

std::string ruleOf(const Scope& s) {
  char text[32];
  std::snprintf(text, sizeof(text), "%s:%" PRIu32, s.collection ? "collection" : "scope", s.id);
  return text;
}

std::string scopeLabel(const Scope& s) { return (s.collection ? "Collection: " : "Smart scope: ") + s.title; }

// A set as the web page shows and types it: comma-separated.
std::string commas(std::string text) {
  for (char& c : text) {
    if (c == '\n') c = ',';
  }
  return text;
}

std::string setFromText(const std::string& text, const bool sources) {
  std::string lines = text;
  for (char& c : lines) {
    if (c == ',') c = '\n';
  }
  char out[1024];
  const bool ok = sources ? normalizeSources(lines.c_str(), out, sizeof(out)) : normalizeRules(lines.c_str(), out, sizeof(out));
  return ok ? std::string(out) : std::string(sources ? "up_next" : "");
}

bool inSet(const std::string& set, const std::string& item) {
  size_t at = 0;
  while (at <= set.size()) {
    size_t end = set.find('\n', at);
    if (end == std::string::npos) end = set.size();
    if (set.compare(at, end - at, item) == 0) return true;
    at = end + 1;
  }
  return false;
}

size_t setSize(const std::string& set) {
  if (set.empty()) return 0;
  size_t n = 1;
  for (const char c : set) n += c == '\n';
  return n;
}

// The set's row value in Settings: its one item's name, or how many.
std::string summary(const bool pick) {
  std::vector<std::string> labels, items;
  choices(pick, labels, items);
  const std::string& set = pick ? settings().from : settings().leaveScopes;
  const size_t n = setSize(set);
  if (n == 0) return tr(STR_NONE_OPT);
  if (n == 1) {
    for (size_t i = 0; i < items.size(); i++) {
      if (items[i] == set) return labels[i];
    }
  }
  return std::to_string(n);
}

std::vector<std::string> hourLabels() {
  std::vector<std::string> out;
  for (const int h : HOURS) out.push_back(h == EVERY_SLEEP ? std::string("Every sleep") : std::to_string(h) + " h");
  return out;
}

uint8_t hoursIndex() {
  for (size_t i = 0; i < HOURS_COUNT; i++) {
    if (HOURS[i] == settings().hours) return static_cast<uint8_t>(i);
  }
  return 0;
}

SettingInfo onOff(const StrId name, bool Settings::* field, const char* key) {
  return SettingInfo::DynamicEnum(
      name, {StrId::STR_OFF, StrId::STR_ON}, [field] { return static_cast<uint8_t>(settings().*field ? 1 : 0); },
      [field](const uint8_t v) {
        edit().*field = v != 0;
        save();
      },
      key, StrId::STR_CAT_DISPLAY);
}

SettingInfo choice(const StrId name, std::vector<std::string> options, std::function<uint8_t()> getter,
                   std::function<void(uint8_t)> setter, const char* key) {
  SettingInfo s = SettingInfo::DynamicEnum(name, {}, std::move(getter), std::move(setter), key, StrId::STR_CAT_DISPLAY);
  s.enumStringValues = std::move(options);
  return s;
}

SettingInfo text(const StrId name, std::string Settings::* field, const char* key, const bool oneLine) {
  return SettingInfo::DynamicString(
      name, [field] { return settings().*field; },
      [field, oneLine](const std::string& v) {
        if (oneLine) {
          char clean[4 * TEXT_MAX + 1];
          cleanText(v.c_str(), clean, sizeof(clean));
          edit().*field = clean;
        } else {
          edit().*field = v;
        }
        save();
      },
      key, StrId::STR_CAT_DISPLAY);
}

// The web page's row for a set: typed, comma-separated (the reader ticks them on a list screen).
SettingInfo setRow(const StrId name, const bool sources, const char* key) {
  return SettingInfo::DynamicString(
      name, [sources] { return commas(sources ? settings().from : settings().leaveScopes); },
      [sources](const std::string& v) {
        (sources ? edit().from : edit().leaveScopes) = setFromText(v, sources);
        save();
      },
      key, StrId::STR_CAT_DISPLAY);
}

SettingInfo hoursRow() {
  return choice(
      StrId::STR_ORBIFY_SLEEP_EVERY, hourLabels(), hoursIndex,
      [](const uint8_t v) {
        if (v >= HOURS_COUNT) return;
        edit().hours = HOURS[v];
        save();
      },
      "orbifySleepEvery");
}

SettingInfo styleRow() {
  return choice(
      StrId::STR_ORBIFY_SLEEP_STYLE, labels(STYLE_LABELS, 2), [] { return static_cast<uint8_t>(settings().style); },
      [](const uint8_t v) {
        edit().style = v ? Style::Overlay : Style::Bar;
        save();
      },
      "orbifySleepStyle");
}

SettingInfo positionRow() {
  return choice(
      StrId::STR_ORBIFY_SLEEP_TEXT_POS, labels(POSITION_LABELS, 4),
      [] { return static_cast<uint8_t>(settings().textPos); },
      [](const uint8_t v) {
        if (v >= 4) return;
        edit().textPos = static_cast<TextPos>(v);
        save();
      },
      "orbifySleepTextPos");
}

SettingInfo cornerRow() {
  return choice(
      StrId::STR_ORBIFY_SLEEP_CORNER, labels(CORNER_LABELS, 4),
      [] { return static_cast<uint8_t>(settings().batteryCorner); },
      [](const uint8_t v) {
        if (v >= 4) return;
        edit().batteryCorner = static_cast<Corner>(v);
        save();
      },
      "orbifySleepCorner");
}

}  // namespace

void addCatalogRows(void (*visitor)(SettingInfo&&, void*), void* context) {
  const auto add = [visitor, context](SettingInfo s) { visitor(std::move(s), context); };
  add(onOff(StrId::STR_ORBIFY_SLEEP_PICK, &Settings::pick, "orbifySleep"));
  // The web page types the sets ("up_next,scope:<id>", "library"); the reader ticks them by name.
  add(setRow(StrId::STR_ORBIFY_SLEEP_FROM, true, "orbifySleepFrom"));
  add(text(StrId::STR_ORBIFY_SLEEP_TAGS, &Settings::leaveTags, "orbifySleepLeaveTags", false));
  add(setRow(StrId::STR_ORBIFY_SLEEP_SCOPES, false, "orbifySleepLeaveScopes"));
  add(hoursRow());
  add(text(StrId::STR_ORBIFY_SLEEP_TEXT, &Settings::text, "orbifySleepText", true));
  add(onOff(StrId::STR_ORBIFY_SLEEP_BATTERY, &Settings::battery, "orbifySleepBattery"));
  add(styleRow());
  add(positionRow());
  add(cornerRow());
}

void choices(const bool pick, std::vector<std::string>& labels, std::vector<std::string>& items) {
  labels.clear();
  items.clear();
  // Library first: every book (R1c, X8). Pick from adds the three lists.
  labels.emplace_back("Library");
  items.emplace_back("library");
  if (pick) {
    labels.insert(labels.end(), {"Up Next", "Want to Read", "Discover"});
    items.insert(items.end(), {"up_next", "want_to_read", "discover"});
  }
  for (const Scope& s : scopes()) {
    labels.push_back(scopeLabel(s));
    items.push_back(ruleOf(s));
  }
  // An item the last sync did not list (yet) stays visible, so it can be unticked.
  const std::string& set = pick ? settings().from : settings().leaveScopes;
  size_t at = 0;
  while (at < set.size()) {
    size_t end = set.find('\n', at);
    if (end == std::string::npos) end = set.size();
    const std::string item = set.substr(at, end - at);
    at = end + 1;
    bool listed = false;
    for (const auto& i : items) listed = listed || i == item;
    if (!listed && !item.empty()) {
      labels.push_back(item);
      items.push_back(item);
    }
  }
}

bool chosen(const bool pick, const std::string& item) {
  return inSet(pick ? settings().from : settings().leaveScopes, item);
}

void toggle(const bool pick, const std::string& item) {
  char out[1024];
  const std::string& set = pick ? settings().from : settings().leaveScopes;
  if (!toggleItem(set.c_str(), item.c_str(), pick, out, sizeof(out))) return;
  (pick ? edit().from : edit().leaveScopes) = out;
  save();
}

const char* listTitle(const bool pick) { return pick ? tr(STR_ORBIFY_SLEEP_FROM) : tr(STR_ORBIFY_SLEEP_SCOPES); }

std::string setSummary(const bool pick) { return summary(pick); }

const char* statusLine(const SettingInfo& row) {
  // X8: Library leaves out every book; the sleep screen shows the current book.
  if (row.action == SettingAction::OrbifySleepScopes && hasLibrary(settings().leaveScopes.c_str())) {
    return "Every book is left out: the current book shows";
  }
  // R6: without Keep Clock in Sleep the X4 learns the time only in the sleep sync.
  if (row.nameId == StrId::STR_ORBIFY_SLEEP_EVERY && settings().hours != EVERY_SLEEP && !SETTINGS.keepClockInSleep) {
    return "Changes when the time is known";
  }
  return nullptr;
}

SettingInfo sleepScreenRow(const SettingInfo& sleepScreen) {
  // The Sleep Screen row: CrossInk's choices, then BookOrbit Pick (S4). Choosing Pick leaves
  // sleepScreen alone; choosing a CrossInk mode turns Pick off and brings that mode back.
  SettingInfo row = sleepScreen;
  std::vector<std::string> options;
  for (const StrId id : sleepScreen.enumValues) options.emplace_back(I18N.get(id));
  options.emplace_back(tr(STR_ORBIFY_SLEEP_PICK));
  const std::vector<uint8_t> raw = sleepScreen.enumRawValues;
  const uint8_t pickIndex = static_cast<uint8_t>(options.size() - 1);
  row.valuePtr = nullptr;
  row.enumValues.clear();
  row.enumRawValues.clear();
  row.enumStringValues = std::move(options);
  row.valueGetter = [raw, pickIndex]() -> uint8_t {
    if (settings().pick) return pickIndex;
    for (size_t i = 0; i < raw.size(); i++) {
      if (raw[i] == SETTINGS.sleepScreen) return static_cast<uint8_t>(i);
    }
    return 0;
  };
  row.valueSetter = [raw, pickIndex](const uint8_t v) {
    const bool pick = v == pickIndex;
    if (!pick && v < raw.size()) SETTINGS.sleepScreen = raw[v];
    if (settings().pick != pick) {
      edit().pick = pick;
      save();
    }
  };
  return row;
}

void addSleepRows(std::vector<SettingInfo>& rows) {
  if (settings().pick) {
    // Lists of toggles, opened straight from their rows (SleepListActivity, R1c and X8).
    rows.push_back(SettingInfo::Action(StrId::STR_ORBIFY_SLEEP_FROM, SettingAction::OrbifySleepFrom));
    rows.push_back(text(StrId::STR_ORBIFY_SLEEP_TAGS, &Settings::leaveTags, "orbifySleepLeaveTags", false));
    rows.push_back(SettingInfo::Action(StrId::STR_ORBIFY_SLEEP_SCOPES, SettingAction::OrbifySleepScopes));
    rows.push_back(hoursRow());
  }
  rows.push_back(text(StrId::STR_ORBIFY_SLEEP_TEXT, &Settings::text, "orbifySleepText", true));
  rows.push_back(onOff(StrId::STR_ORBIFY_SLEEP_BATTERY, &Settings::battery, "orbifySleepBattery"));
  rows.push_back(styleRow());
  if (settings().style == Style::Overlay) {
    rows.push_back(positionRow());
    rows.push_back(cornerRow());
  }
}

}  // namespace OrbifySleep

#endif
