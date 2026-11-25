// Host test for Orbify's local-first catalog decisions (xteink/orbify/core/LocalFirst): the shared
// stamp and overlay tables in shared/fixtures/localfirst/ (Android reads the same ones) and the
// design's offline rules (docs/design/local-first/DESIGN.md, item 4).
#include <ArduinoJson.h>

#include <cstring>
#include <ctime>
#include <string>

#include "LocalFirst.h"
#include "TestSupport.h"

using namespace orbify;

namespace {

uint32_t isoSeconds(const char* iso) {
  if (!iso) return 0;
  struct tm t = {};
  if (std::sscanf(iso, "%d-%d-%dT%d:%d:%d", &t.tm_year, &t.tm_mon, &t.tm_mday, &t.tm_hour, &t.tm_min, &t.tm_sec) != 6)
    return 0;
  t.tm_year -= 1900;
  t.tm_mon -= 1;
  return static_cast<uint32_t>(timegm(&t));
}

BookState stateOf(const char* s) {
  if (!s) return BookState::Unknown;
  if (!std::strcmp(s, "complete") || !std::strcmp(s, "read")) return BookState::Complete;
  return BookState::Reading;
}

void stampCases(const std::string& dir) {
  JsonDocument doc;
  // @fixture localfirst/stamp-cases.json
  if (!loadJsonFile((dir + "/stamp-cases.json").c_str(), doc)) {
    CHECK(false);
    return;
  }
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    char out[64];
    formatStamp(c["online"].as<bool>(), c["fetched_at"].isNull() ? 0 : c["fetched_at"].as<uint32_t>(),
                c["now"].as<uint32_t>(), c["failed"].as<bool>(), out, sizeof(out));
    CHECK_NAMED((std::string(out) + " != " + c["expect"].as<std::string>()).c_str(), c["expect"].as<std::string>() == out);
  }
}

// Each expected book's percent, status and "not synced" mark. List membership, order and the goal
// are the Android Home's (Xteink rows show one book at a time).
void overlayCases(const std::string& dir) {
  JsonDocument doc;
  // @fixture localfirst/overlay-cases.json
  if (!loadJsonFile((dir + "/overlay-cases.json").c_str(), doc)) {
    CHECK(false);
    return;
  }
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    const bool autoSync = c["autoSync"].isNull() ? true : c["autoSync"].as<bool>();
    for (JsonPairConst list : c["expect"].as<JsonObjectConst>()) {
      if (!list.value().is<JsonArrayConst>()) continue;
      for (JsonObjectConst want : list.value().as<JsonArrayConst>()) {
        const int64_t id = want["id"].as<int64_t>();
        // The server's row for this book, from any list of the body.
        ServerBook server;
        for (JsonPairConst bodyList : c["body"].as<JsonObjectConst>()) {
          if (!bodyList.value().is<JsonArrayConst>()) continue;
          for (JsonObjectConst b : bodyList.value().as<JsonArrayConst>()) {
            if (b["id"].as<int64_t>() != id) continue;
            server.percent = b["progressPercentage"].isNull() ? -1 : b["progressPercentage"].as<int>();
            server.state = stateOf(b["readStatus"].as<const char*>());
            server.lastReadAt = isoSeconds(b["lastReadAt"].as<const char*>());
          }
        }
        DeviceBook device;
        JsonObjectConst local = c["local"][std::to_string(id)];
        if (!local.isNull()) {
          device.known = true;
          device.percent = local["percent"].as<int>();
          device.state = stateOf(local["status"].as<const char*>());
          device.changedAt = local["changedAt"].as<uint32_t>();
          device.pending = local["pending"].as<bool>();
          device.blocked = local["blocked"].as<bool>();
        }
        const ShownBook shown = overlayBook(server, device, autoSync);
        if (!want["progressPercentage"].isNull()) CHECK_NAMED(name, shown.percent == want["progressPercentage"].as<int>());
        if (!want["readStatus"].isNull()) CHECK_NAMED(name, shown.state == stateOf(want["readStatus"].as<const char*>()));
        JsonVariantConst mark = c["notSynced"][std::to_string(id)];
        if (!mark.isNull()) CHECK_NAMED(name, shown.notSynced == mark.as<bool>());
      }
    }
  }
}

void offlineRules() {
  CHECK(catalogOpensInPlace(true, true) && !catalogOpensInPlace(false, true) && !catalogOpensInPlace(true, false));
  CHECK(offlineTapAction(RowTarget::List, true, false) == OfflineTap::Open);
  CHECK(offlineTapAction(RowTarget::List, false, false) == OfflineTap::ConnectAndOpen);
  CHECK(offlineTapAction(RowTarget::Book, false, true) == OfflineTap::OpenBook);
  CHECK(offlineTapAction(RowTarget::Book, true, false) == OfflineTap::ConnectAndDownload);
  CHECK(canSortLocally(12, 12) && canSortLocally(40, 12) && !canSortLocally(20, 142) && !canSortLocally(0, 0));
  CHECK(searchMatches("wayfarer", "The Wayfarer, Book Two", "Ann Writer"));
  CHECK(searchMatches("ann two", "The Wayfarer, Book Two", "Ann Writer"));
  CHECK(searchMatches("ELOISE", "\xC3\x89lo\xC3\xAFse", ""));  // Éloïse
  CHECK(!searchMatches("wayfarer three", "The Wayfarer, Book Two", "Ann Writer"));
  CHECK(!searchMatches("  ", "anything", "anyone"));

  uint32_t saved[100];
  for (size_t i = 0; i < 100; ++i) saved[i] = 1000 + static_cast<uint32_t>(i);
  saved[50] = 0;  // an unstamped page is the oldest
  size_t drop[8];
  const size_t n = pagesToEvict(saved, 100, drop, 8);
  CHECK(n == 4 && drop[0] == 50 && drop[1] == 0 && drop[2] == 1 && drop[3] == 2);
  CHECK(pagesToEvict(saved, 96, drop, 8) == 0);
  CHECK(ownerKey("https://a", "kid") != ownerKey("https://a", "parent") &&
        ownerKey("https://a", "kid") == ownerKey("https://a", "kid"));

  char out[48];
  CHECK(formatStamp(false, 0, 5000, false, out, sizeof(out)) && std::string(out) == "Offline");
  CHECK(formatStamp(true, 1000, 1030, true, out, sizeof(out)) && std::string(out) == "Not updated \xC2\xB7 saved just now");
  CHECK(formatStamp(true, 1000, 999000, false, out, 8) == 7);  // truncated, terminated
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/localfirst";
  stampCases(dir);
  overlayCases(dir);
  offlineRules();
  return report("local-first");
}
