#pragma once
// BookSync sleep screen settings (docs/design/lock-screen.md S3, S4), X4 Pro and X4. Every StrId the
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
// Then BookSync's rows, after CrossInk's own sleep rows; the rows that only apply show only then.
void addSleepRows(std::vector<SettingInfo>& rows);

// The list screens (SleepListActivity): Pick From (pick true: Library, the three lists, the smart
// scopes and collections) and Leave Out Scopes (Library, the smart scopes and collections), each item
// ticked on one page (R1c, X8). items are the stored form ("library", "up_next", "scope:<id>").
void choices(bool pick, std::vector<std::string>& labels, std::vector<std::string>& items);
bool chosen(bool pick, const std::string& item);
void toggle(bool pick, const std::string& item);
const char* listTitle(bool pick);
// The row's value in Settings: the one item's name, or how many.
std::string setSummary(bool pick);
// A row's status, drawn on its own line under the row (never beside its value), or nullptr.
const char* statusLine(const SettingInfo& row);

}  // namespace OrbifySleep
#endif
