// Host test for "nothing interrupts reading" (xteink/orbify/core/ReadingQuiet): the shared table in
// shared/fixtures/reading-quiet/cases.json (only this test reads it so far: REGISTRY.json).
#include <ArduinoJson.h>

#include <string>

#include "ReadingQuiet.h"
#include "TestSupport.h"

using namespace orbify::quiet;

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/reading-quiet";
  JsonDocument doc;
  // @fixture reading-quiet/cases.json
  CHECK(loadJsonFile((dir + "/cases.json").c_str(), doc));
  int cases = 0;
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    Event e;
    const char* name = c["event"] | "";
    CHECK_NAMED(name, eventFromName(name, e));
    CHECK_NAMED(name, mayShow(e, c["reading"].as<bool>()) == c["show"].as<bool>());
    CHECK_NAMED(name, std::string(eventName(e)) == name);
    cases++;
  }
  CHECK(cases >= 16);
  // Every event the firmware knows is in the table, and every one is described.
  for (JsonPairConst p : doc["events"].as<JsonObjectConst>()) {
    Event e;
    CHECK_NAMED(p.key().c_str(), eventFromName(p.key().c_str(), e));
  }
  CHECK(doc["events"].as<JsonObjectConst>().size() == 9);
  Event unknown;
  CHECK(!eventFromName("popup", unknown));
  // The rule itself, beyond the table: while reading, only the three exceptions show.
  int shownWhileReading = 0;
  for (JsonPairConst p : doc["events"].as<JsonObjectConst>()) {
    Event e;
    if (eventFromName(p.key().c_str(), e) && mayShow(e, true)) shownWhileReading++;
  }
  CHECK(shownWhileReading == 3);
  return report("reading-quiet");
}
