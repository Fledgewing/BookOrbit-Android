// SPDX-License-Identifier: GPL-3.0-or-later
#include "WifiPolicy.h"
#include "TestSupport.h"
int main(int argc,char** argv) {
  using namespace orbify::wifi;
  JsonDocument doc;
  const std::string path=std::string(argc>1?argv[1]:"shared/fixtures/bookorbit")+"/../wifi/policy.json";
  CHECK(loadJsonFile(path.c_str(),doc));
  // @fixture wifi/policy.json#connect
  for (JsonObjectConst row:doc["connect"].as<JsonArrayConst>())
    CHECK(shouldConnect(row["mode"]|"",row["reason"]|"",row["saved"].as<bool>())==row["connect"].as<bool>());
  for (const char* mode:{"always_on","off_reading","jit"}) {
    Policy p; p.mode=mode;
    p.acquire(false,0,0); p.release(0,10);
    CHECK(!p.off(true,0,false,12));
    CHECK(p.off(true,0,false,13)); // restore previously off after grace
    CHECK(!p.off(true,1,false,300));
  }
  Policy p;
  CHECK(!p.off(true,0,false,119)); CHECK(p.off(true,0,false,120));
  p.mode="off_reading";
  CHECK(!p.book(true,true)); CHECK(p.off(true,0,false,0));
  CHECK(p.book(false,false));
  p.mode="always_on"; p.wifiOff();
  CHECK(!p.off(true,0,false,10000));
  return report("wifi_policy");
}
