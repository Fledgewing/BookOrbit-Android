// SPDX-License-Identifier: MIT
// @fixture status/format.json
#include "TestSupport.h"
#include "StatusFormat.h"
#include <filesystem>
int main(int argc, char** argv) {
  if (argc < 2) return 2;
  JsonDocument doc;
  auto path = std::filesystem::path(argv[1]).parent_path() / "status/format.json";
  if (!loadJsonFile(path.string().c_str(), doc)) return 1;
  for (JsonObjectConst row : doc["progress"].as<JsonArrayConst>()) {
    char pages[48], percent[24];
    orbify::statusPages(pages, sizeof(pages), row["page"], row["total"]);
    orbify::statusPercent(percent, sizeof(percent), row["fraction"].as<double>()*100, 0, true);
    const std::string actual = std::string(pages) + " " + percent;
    CHECK_NAMED(actual.c_str(), actual == row["text"].as<std::string>());
  }
  char estimated[48];
  orbify::statusPages(estimated, sizeof(estimated), 12, 340, true);
  CHECK(std::string(estimated) == "~12 / 340");
  orbify::statusPercent(estimated, sizeof(estimated), 4, 0, false);
  CHECK(std::string(estimated) == "4%");
  return report("status format");
}
