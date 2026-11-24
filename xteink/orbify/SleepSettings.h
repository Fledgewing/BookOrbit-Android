#pragma once
// Orbify sleep screen settings (docs/design/lock-screen.md S3, S4), X4 Pro and X4. Every StrId the
// sleep screen uses lives in SleepSettings.cpp alone: tailnet_build.py leaves that file out of the
// i18n scan when CROSSINK_TAILNET_ORBIFY_SLEEP is 0, so the X3's string table stays as it was.
#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_SLEEP
#include <cstddef>
#include <string>
#include <vector>

struct SettingInfo;

namespace OrbifySleep {

// The rows forEachBaseSetting adds (the web settings page; they keep their own file, not
// CrossPointSettings' JSON).
constexpr size_t CATALOG_ROWS = 10;
void addCatalogRows(void (*visitor)(SettingInfo&&, void*), void* context);

// Settings > Display > Sleep: CrossInk's Sleep Screen row (from the catalog) with BookOrbit Pick
// added (S4), in its place.
SettingInfo sleepScreenRow(const SettingInfo& sleepScreen);
// Then Orbify's rows, after CrossInk's own sleep rows; the rows that only apply show only then.
void addSleepRows(std::vector<SettingInfo>& rows);

// Leave Out Scopes' list screen (SleepScopesActivity): every smart scope and collection by name
// with its rule ("scope:<id>"), whether a rule is left out, toggling one, the page's title, and the
// row's value in Settings.
void scopeChoices(std::vector<std::string>& labels, std::vector<std::string>& rules);
bool leftOutRule(const std::string& rule);
void toggleLeaveOut(const std::string& rule);
const char* leaveScopesTitle();
std::string leaveScopesSummary();
// A row's status, drawn on its own line under the row (never beside its value), or nullptr.
const char* statusLine(const SettingInfo& row);

}  // namespace OrbifySleep
#endif
