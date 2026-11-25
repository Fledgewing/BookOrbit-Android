// SPDX-License-Identifier: GPL-3.0-or-later
// @fixture catalog/bulk-refresh/catalog.json
#include "BulkRefresh.h"
#include "TestSupport.h"
#include <filesystem>

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  JsonDocument fx;
  CHECK(loadJsonFile((std::filesystem::path(argv[1]).parent_path() / "catalog/bulk-refresh/catalog.json").string().c_str(), fx));
  const auto books = fx["manifest"].as<JsonArrayConst>();
  const auto rows = fx["rows"].as<JsonArrayConst>();
  CHECK(books.size() == rows.size());
  std::map<int64_t, size_t> primary;
  for (JsonObjectConst row : rows) ++primary[row["seriesId"].as<int64_t>()];
  unsigned extra = 0;
  for (JsonObjectConst series : fx["sections"]["series"].as<JsonArrayConst>()) {
    const auto id = series["seriesId"].as<int64_t>();
    if (orbify::bulk::needsSecondary(primary[id], series["count"].as<size_t>())) ++extra;
  }
  CHECK(extra == 1);
  CHECK(!orbify::bulk::reconcileSecondary(true, 5, 5, false));
  CHECK(orbify::bulk::reconcileSecondary(true, 5, 5, true));
  CHECK(orbify::bulk::reconcileSecondary(true, 5, 4, false));
  CHECK(orbify::bulk::status("on_hold") == "reading");
  CHECK(orbify::bulk::status("skimmed") == "finished");
  orbify::bulk::ManifestCursor cursor;
  JsonDocument page;
  page["items"].to<JsonArray>(); page["hasNext"] = true; page["nextCursor"] = "opaque-1";
  std::string error;
  CHECK(cursor.accept(page.as<JsonVariantConst>(), error));
  CHECK(!cursor.accept(page.as<JsonVariantConst>(), error));
  page["restartRequired"] = true;
  CHECK(cursor.accept(page.as<JsonVariantConst>(), error));
  CHECK(cursor.cursor.empty());
  CHECK(!cursor.accept(page.as<JsonVariantConst>(), error));
  orbify::bulk::Progress progress;
  progress.phase(60); progress.phase(20); CHECK(progress.shown == 60);
  progress.publishBase(); CHECK(progress.basePublished && progress.shown == 90);
  progress.finish(false); CHECK(!progress.complete && progress.shown < 100);
  progress.finish(true); CHECK(progress.complete && progress.shown == 100);
  return report("bulk-refresh");
}
