#pragma once
// Orbify sleep screen settings (docs/design/lock-screen.md S3, S4), X4 Pro and X4. Every StrId the
// sleep screen uses lives in SleepSettings.cpp alone: tailnet_build.py leaves that file out of the
// i18n scan when CROSSINK_TAILNET_ORBIFY_SLEEP is 0, so the X3's string table stays as it was.
#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_SLEEP
#include <cstddef>
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

}  // namespace OrbifySleep
#endif
