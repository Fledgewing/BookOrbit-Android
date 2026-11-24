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

// Pick From: the three lists, then each smart scope and collection by name.
std::vector<std::string> fromLabels() {
  std::vector<std::string> out = {"Up Next", "Want to Read", "Discover"};
  for (const Scope& s : scopes()) out.push_back(scopeLabel(s));
  const std::string& from = settings().from;
  bool listed = from == "up_next" || from == "want_to_read" || from == "discover";
  for (const Scope& s : scopes()) listed = listed || ruleOf(s) == from;
  if (!listed) out.push_back(from);  // a scope the last sync did not list (yet)
  return out;
}

uint8_t fromIndex() {
  const std::string& from = settings().from;
  if (from == "want_to_read") return 1;
  if (from == "discover") return 2;
  if (from == "up_next") return 0;
  uint8_t i = 3;
  for (const Scope& s : scopes()) {
    if (ruleOf(s) == from) return i;
    i++;
  }
  return i;  // the unlisted one, last
}

void setFrom(const uint8_t index) {
  static const char* const LISTS[] = {"up_next", "want_to_read", "discover"};
  if (index < 3) {
    edit().from = LISTS[index];
  } else if (index - 3u < scopes().size()) {
    edit().from = ruleOf(scopes()[index - 3]);
  } else {
    return;  // the unlisted one stays
  }
  save();
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

bool leftOut(const std::string& rule) {
  From r;
  for (const char* p = nextScopeRule(settings().leaveScopes.c_str(), r); p; p = nextScopeRule(p, r)) {
    char text[32];
    if (formatFrom(r, text, sizeof(text)) && rule == text) return true;
  }
  return false;
}

// Leave Out Scopes on the reader: the first option sums up, each other one toggles a scope.
std::vector<std::string> leaveScopeLabels() {
  size_t chosen = 0;
  From r;
  for (const char* p = nextScopeRule(settings().leaveScopes.c_str(), r); p; p = nextScopeRule(p, r)) chosen++;
  std::vector<std::string> out;
  out.push_back(chosen == 0 ? std::string(tr(STR_NONE_OPT)) : std::to_string(chosen) + " left out");
  for (const Scope& s : scopes()) out.push_back((leftOut(ruleOf(s)) ? "[x] " : "[ ] ") + scopeLabel(s));
  return out;
}

void toggleLeaveScope(const uint8_t index) {
  if (index == 0 || index - 1u >= scopes().size()) return;
  const std::string rule = ruleOf(scopes()[index - 1]);
  std::string next;
  From r;
  for (const char* p = nextScopeRule(settings().leaveScopes.c_str(), r); p; p = nextScopeRule(p, r)) {
    char text[32];
    if (!formatFrom(r, text, sizeof(text)) || rule == text) continue;
    if (!next.empty()) next += ',';
    next += text;
  }
  if (!leftOut(rule)) {
    if (!next.empty()) next += ',';
    next += rule;
  }
  edit().leaveScopes = next;
  save();
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

SettingInfo fromRow() { return choice(StrId::STR_ORBIFY_SLEEP_FROM, fromLabels(), fromIndex, setFrom, "orbifySleepFrom"); }

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
  add(fromRow());
  add(text(StrId::STR_ORBIFY_SLEEP_TAGS, &Settings::leaveTags, "orbifySleepLeaveTags", false));
  // The web page types the rules ("scope:<id>,collection:<id>"); the reader toggles them by name.
  add(text(StrId::STR_ORBIFY_SLEEP_SCOPES, &Settings::leaveScopes, "orbifySleepLeaveScopes", false));
  add(hoursRow());
  add(text(StrId::STR_ORBIFY_SLEEP_TEXT, &Settings::text, "orbifySleepText", true));
  add(onOff(StrId::STR_ORBIFY_SLEEP_BATTERY, &Settings::battery, "orbifySleepBattery"));
  add(styleRow());
  add(positionRow());
  add(cornerRow());
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
    rows.push_back(fromRow());
    rows.push_back(text(StrId::STR_ORBIFY_SLEEP_TAGS, &Settings::leaveTags, "orbifySleepLeaveTags", false));
    rows.push_back(choice(StrId::STR_ORBIFY_SLEEP_SCOPES, leaveScopeLabels(), [] { return uint8_t{0}; },
                          toggleLeaveScope, "orbifySleepLeaveScopes"));
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
