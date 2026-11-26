// SPDX-License-Identifier: GPL-3.0-or-later
#include "TestSupport.h"
#include "WifiPolicy.h"
int main(int argc, char** argv) {
  using namespace orbify::wifi;
  JsonDocument doc;
  const std::string path =
      std::string(argc > 1 ? argv[1] : "shared/fixtures/bookorbit") + "/../wifi/policy.json";
  CHECK(loadJsonFile(path.c_str(), doc));
  // @fixture wifi/policy.json#connect
  for (JsonObjectConst row : doc["connect"].as<JsonArrayConst>())
    CHECK(shouldConnect(row["mode"] | "", row["reason"] | "", row["saved"].as<bool>()) ==
          row["connect"].as<bool>());
  for (const char* mode : {"always_on", "off_reading", "jit"}) {
    Policy p;
    p.mode = mode;
    p.acquire(false, 0, 0);
    p.release(0, 10);
    CHECK(!p.off(true, 0, false, 12));
    CHECK(p.off(true, 0, false, 13));  // restore previously off after grace
    CHECK(!p.off(true, 1, false, 300));
  }
  // The .407 miss path: miss -> joined -> page fetch -> Home, all within
  // one flow. No owner may turn its own started radio into a pre-existing one.
  for (const char* mode : {"always_on", "off_reading", "jit"}) {
    Policy handoff;handoff.mode=mode;
    handoff.acquire(false,0,0);handoff.release(0,12);
    handoff.acquire(true,0,12);handoff.release(0,14);
    handoff.acquire(true,0,15);handoff.release(0,16);
    CHECK(!handoff.off(true,0,false,18));
    CHECK(handoff.off(true,0,false,19));
    CHECK(!handoff.off(true,1,false,19));
    CHECK(!handoff.off(true,0,true,19));
    handoff.wifiOff();
    handoff.acquire(true,0,20);handoff.release(0,21);
    CHECK(!handoff.off(true,0,false,24));  // originally on remains on
  }
  Policy p;
  CHECK(!p.off(true, 0, false, 119));
  CHECK(p.off(true, 0, false, 120));
  p.mode = "off_reading";
  CHECK(!p.book(true, true));
  CHECK(p.off(true, 0, false, 0));
  CHECK(p.book(false, false));
  p.mode = "always_on";
  p.wifiOff();
  CHECK(!p.off(true, 0, false, 10000));
  return report("wifi_policy");
}
