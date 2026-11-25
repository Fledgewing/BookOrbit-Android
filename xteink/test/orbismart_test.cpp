// @fixture orbismart/cases.json
// Host test for OrbiSmart sync (xteink/orbify/core/OrbiSmart): every case of the shared table in
// shared/fixtures/orbismart/cases.json (Android's logic/orbismart.lua reads the same one).
#include <ArduinoJson.h>

#include <cstring>
#include <set>
#include <string>

#include "OrbiSmart.h"
#include "OrbiSmartState.h"
#include "TestSupport.h"

using namespace orbify::orbismart;

namespace {
Input inputOf(JsonObjectConst j) {
  Input in;
  in.local = j["local"] | 0.0;
  in.hasServer = !j["server"].isNull();
  in.server = j["server"] | 0.0;
  in.tolerance = j["tolerance"] | 1.0;
  in.serverAt = j["server_at"] | 0LL;
  in.hasMarker = j["marker"].is<JsonObjectConst>();
  in.markerAt = j["marker"]["at"] | 0LL;
  in.markerPlace = j["marker"]["place"] | 0.0;
  in.turnAt = j["turn_at"] | 0LL;
  in.reset = j["reset"] | false;
  in.redated = j["redated"] | false;
  in.finished = j["finished"] | false;
  in.released = j["released"] | false;
  in.declinedAt = j["declined_at"] | 0LL;
  in.hasOverride = j["override"].is<JsonObjectConst>();
  in.overrideAt = j["override"]["at"] | 0LL;
  in.percentOnly = j["percent_only"] | false;
  return in;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/orbismart";
  JsonDocument doc;
  CHECK(loadJsonFile((dir + "/cases.json").c_str(), doc));
  CHECK(doc["skew_s"].as<int64_t>() == SKEW_S);

  int cases = 0;
  std::set<std::string> seen;
  for (JsonObjectConst c : doc["decide"].as<JsonArrayConst>()) {
    const char* name = c["name"] | "";
    const Input in = inputOf(c["in"]);
    const Result r = decide(in);
    CHECK_NAMED(name, std::string(decisionName(r.decision)) == (c["want"]["decision"] | ""));
    CHECK_NAMED(name, std::string(ruleName(r.rule)) == (c["want"]["rule"] | ""));
    CHECK_NAMED(name, r.dropped == (c["want"]["dropped"] | false));
    seen.insert(decisionName(r.decision));
    seen.insert(ruleName(r.rule));
    if (!c["line"].isNull()) {
      Moment m;
      CHECK_NAMED(name, momentFromName(c["moment"] | "", m));
      char line[160];
      formatLine(in, r, m, line, sizeof(line));
      CHECK_NAMED(name, std::string(line) == (c["line"] | ""));
    }
    cases++;
  }
  CHECK(cases >= 30);
  for (const char* k : {"same", "take", "follow", "push", "hold", "stay", "override", "rule1", "rule2", "rule3", "rule4",
                        "rule5", "rule6", "rule7", "declined", "percent", "no-server"}) {
    CHECK_NAMED(k, seen.count(k) == 1);
  }

  for (JsonObjectConst c : doc["apply"].as<JsonArrayConst>()) {
    const char* d = c["decision"] | "";
    Decision decision;
    Moment moment;
    CHECK_NAMED(d, decisionFromName(d, decision));
    CHECK_NAMED(d, momentFromName(c["moment"] | "", moment));
    CHECK_NAMED(d, std::string(appliedName(apply(decision, moment))) == (c["applied"] | ""));
  }

  for (JsonObjectConst c : doc["push"].as<JsonArrayConst>()) {
    const char* name = c["name"] | "";
    const bool exempt = !c["exempt"].isNull();
    CHECK_NAMED(name, mayPush(c["place"] | 0.0, !c["server"].isNull(), c["server"] | 0.0, c["tolerance"] | 1.0,
                              exempt) == (c["allowed"] | false));
  }

  // A short buffer is cut, never overrun.
  Input in;
  in.local = 120;
  in.hasServer = true;
  in.server = 214;
  char tiny[12];
  const size_t n = formatLine(in, decide(in), Moment::Open, tiny, sizeof(tiny));
  CHECK(n == sizeof(tiny) - 1 && std::strlen(tiny) == n);
  // A reboot retains the pending place, a No and the exact queued override, or falls back
  // to the other generation when any byte was torn. Account changes cannot replay intents.
  CHECK(!pauseDue(119999, 4, 1, 8, 1, 2));
  CHECK(pauseDue(120000, 4, 1, 8, 1, 2));
  CHECK(!pauseDue(120000, 4, 1, 3, 1, 2));
  CHECK(!pauseDue(120000, 4, 1, 2, 1, 2));
  CHECK(pauseDue(120000, 4, 2, 0, 1, 2));
  CHECK(!wakeDue(1599, 1000)); CHECK(wakeDue(1600, 1000)); CHECK(wakeDue(1000, 0));
  State state;
  state.generation = 7; state.server = 42;
  state.flags = State::PENDING | State::WAKE | State::OVERRIDE;
  state.declined = 1234; state.chosen.at = 5678;
  std::strcpy(state.pending.xpath, "/body/DocFragment[4]/body");
  std::strcpy(state.chosen.xpath, "/body/DocFragment[2]/body");
  seal(state);
  CHECK(sizeof(RemoteRecord) == 396);
  CHECK(sizeof(State) == 1629);
  CHECK(valid(state, 42));
  CHECK(!valid(state, 43));
  State reboot;
  std::memcpy(&reboot, &state, sizeof(state));
  CHECK(valid(reboot, 42) && reboot.declined == 1234 && reboot.chosen.at == 5678);
  const auto* raw = reinterpret_cast<const uint8_t*>(&state);
  for (size_t i = 0; i < sizeof(state); ++i) {
    std::memcpy(&reboot, raw, sizeof(state));
    reinterpret_cast<uint8_t*>(&reboot)[i] ^= 1;
    CHECK(!valid(reboot, 42));
  }
  state.generation = 0; seal(state);
  CHECK(!valid(state, 42));
  return report("orbismart");
}
