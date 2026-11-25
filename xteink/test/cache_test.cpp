// Host test for Orbify's write-through cache rules (xteink/orbify/core/CatalogCache): the shared
// table shared/fixtures/cache/cases.json (Android's tests read the same one) and the Xteink size cap.
#include <ArduinoJson.h>

#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "CatalogCache.h"
#include "LocalFirst.h"
#include "TestSupport.h"

using namespace orbify;
using namespace orbify::cache;

namespace {

Query queryOf(JsonObjectConst q) {
  Query out;
  for (JsonPairConst p : q) out.emplace_back(p.key().c_str(), p.value().as<std::string>());
  return out;
}

std::string keyOf(JsonObjectConst k) {
  return makeKey(k["account"].as<std::string>(), k["server"].as<std::string>(), k["method"].as<std::string>(),
                 k["path"].as<std::string>(), queryOf(k["query"]));
}

void keys(JsonObjectConst all) {
  // @fixture cache/cases.json#keys
  for (JsonObjectConst c : all["keys"].as<JsonArrayConst>()) {
    const bool same = keyOf(c["a"]) == keyOf(c["b"]);
    CHECK_NAMED(c["name"].as<const char*>(), same == c["same"].as<bool>());
  }
  // The firmware builds keys from the request URL: the same key as from its parts.
  CHECK(keyForUrl("reader", "GET", "https://Books.Example/koreader/plugin/catalog/books?sort=title&q=&page=1") ==
        makeKey("reader", "https://books.example", "GET", "/koreader/plugin/catalog/books",
                {{"page", "1"}, {"sort", "title"}}));
  CHECK(keyForUrl("reader", "GET", "https://books.example:8443/base/plugin/catalog/dashboard") !=
        keyForUrl("reader", "GET", "https://books.example/base/plugin/catalog/dashboard"));
  CHECK(keyHash("a") != keyHash("b"));
  // @fixture cache/cases.json#cacheable
  for (JsonObjectConst c : all["cacheable"].as<JsonArrayConst>()) {
    const std::string name = c["method"].as<std::string>() + " " + c["path"].as<std::string>();
    CHECK_NAMED(name.c_str(), isCacheable(c["method"], c["path"]) == c["cached"].as<bool>());
  }
  CHECK(!isCacheable("GET", "/plugin/catalog/books/42/download"));
}

Mode modeOf(const char* m) {
  if (m && !std::strcmp(m, "refresh")) return Mode::Refresh;
  if (m && !std::strcmp(m, "full")) return Mode::Full;
  return Mode::Open;
}

void reads(JsonObjectConst all) {
  // @fixture cache/cases.json#reads
  for (JsonObjectConst c : all["reads"].as<JsonArrayConst>()) {
    const bool has = !c["entry"].isNull();
    // A write marks an entry stale by clearing its stamp (IndexEntry::validatedAt 0 = due).
    const uint32_t validated = has && !(c["entry"]["stale"] | false) ? c["entry"]["validated_at"].as<uint32_t>() : 0;
    const ReadPlan p = planRead(has, validated, c["now"], modeOf(c["mode"]),
                                c["offline"] | false);
    CHECK_NAMED(c["name"].as<const char*>(), p.serve == c["serve"].as<bool>() && p.fetch == c["fetch"].as<bool>());
    // A read asks the server only when its plan fetches (offline: never).
    CHECK_NAMED(c["name"].as<const char*>(), (readStep(p) == ReadStep::Request) == p.fetch);
  }
  // The cache-first catalog's next page (X4 Pro, .194): offline, a page never saved is a miss with
  // no request, in every mode; a saved one is read from the card.
  for (const Mode m : {Mode::Open, Mode::Refresh, Mode::Full}) {
    CHECK(readStep(planRead(false, 0, 5000, m, true)) == ReadStep::Miss);
    CHECK(readStep(planRead(true, 4000, 5000, m, true)) == ReadStep::Saved);
  }
  CHECK(readStep(planRead(false, 0, 5000, Mode::Open, false)) == ReadStep::Request);
  CHECK(readStep(planRead(true, 4990, 5000, Mode::Open, false)) == ReadStep::Saved);
  // @fixture cache/cases.json#revalidate
  for (JsonObjectConst c : all["revalidate"].as<JsonArrayConst>()) {
    const Revalidated r = revalidate(c["status"], true, canonicalHash(c["cached"]), canonicalHash(c["reply"]));
    CHECK_NAMED(c["name"].as<const char*>(),
                r.changed == c["changed"].as<bool>() && r.stored == c["stored"].as<bool>());
  }
  // A first fetch stores a 2xx reply and nothing else.
  CHECK(revalidate(200, false, 0, 7).stored);
  CHECK(!revalidate(404, false, 0, 7).stored);
  // Canonical: nested key order doesn't matter, values and array order do.
  JsonDocument a, b, c;
  deserializeJson(a, R"({"x":{"p":1,"q":[1,2]},"y":"s"})");
  deserializeJson(b, R"({"y":"s","x":{"q":[1,2],"p":1}})");
  deserializeJson(c, R"({"y":"s","x":{"q":[2,1],"p":1}})");
  CHECK(canonicalHash(a.as<JsonVariantConst>()) == canonicalHash(b.as<JsonVariantConst>()));
  CHECK(canonicalHash(a.as<JsonVariantConst>()) != canonicalHash(c.as<JsonVariantConst>()));
}

void writes(JsonObjectConst all) {
  // @fixture cache/cases.json#writes
  for (JsonObjectConst c : all["writes"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    JsonObjectConst w = c["write"];
    const WriteEffect e = writeEffect(w["method"], w["path"], w["status"], w["body"]);
    JsonDocument entries;
    entries.set(c["entries"]);
    for (JsonPair p : entries.as<JsonObject>()) patchBook(p.value(), e.bookId, e.fields.as<JsonObjectConst>());
    std::string got, want;
    serializeJson(entries, got);
    serializeJson(c["expect"], want);
    CHECK_NAMED((std::string(name) + ": " + got).c_str(), got == want);
    const bool wantStale = c["stale"].as<JsonArrayConst>().size() > 0;
    CHECK_NAMED(name, e.homeStale == wantStale);
  }
  JsonDocument none;
  // Progress and book states only mark Home stale; GETs and failures do nothing.
  CHECK(writeEffect("PUT", "/syncs/progress", 200, none.as<JsonVariantConst>()).homeStale);
  CHECK(writeEffect("PUT", "/syncs/progress", 200, none.as<JsonVariantConst>()).bookId == 0);
  CHECK(writeEffect("POST", "/plugin/catalog/book-states", 204, none.as<JsonVariantConst>()).homeStale);
  CHECK(!writeEffect("GET", "/plugin/catalog/books/7/read-status", 200, none.as<JsonVariantConst>()).homeStale);
  CHECK(!writeEffect("PUT", "/syncs/progress", 401, none.as<JsonVariantConst>()).homeStale);
}

// The shared cover cases, played against a simulated server: a conditional request is answered 304
// when the ETag on the card is the server's, else 200 with the server's ETag.
void covers(JsonObjectConst all) {
  // @fixture cache/cases.json#covers
  for (JsonObjectConst c : all["covers"].as<JsonArrayConst>()) {
    const std::string name = c["name"].as<std::string>();
    const Mode mode = modeOf(c["mode"]);
    std::vector<int> failed;
    for (int id : c["failed"].as<JsonArrayConst>()) failed.push_back(id);
    std::vector<int> download, removed, conditional, notModified;
    for (JsonObjectConst book : c["listed"].as<JsonArrayConst>()) {
      const int id = book["id"];
      const std::string idText = std::to_string(id);
      JsonObjectConst d = c["disk"][idText];
      CoverOnDisk disk;
      if (!d.isNull()) {
        disk.present = true;
        disk.version = coverVersion(d["version"]);
        const char* f = d["file"] | "ok";
        disk.file = !std::strcmp(f, "ok")      ? CoverFile::Ok
                    : !std::strcmp(f, "empty") ? CoverFile::Empty
                    : !std::strcmp(f, "corrupt") ? CoverFile::Corrupt
                                                 : CoverFile::Missing;
        disk.hasEtag = !d["etag"].isNull();
      }
      const bool failedBefore = std::find(failed.begin(), failed.end(), id) != failed.end();
      const CoverPlan p = planCover(mode, book["hasCover"] | true, coverVersion(book["updatedAt"]), disk, failedBefore);
      if (p.removeFirst) removed.push_back(id);
      if (p.action == CoverAction::Download) download.push_back(id);
      if (p.action == CoverAction::Conditional) {
        conditional.push_back(id);
        const bool same = !book["server_etag"].isNull() && book["server_etag"].as<std::string>() == d["etag"].as<std::string>();
        (same ? notModified : download).push_back(id);
        // Either way the file ends at the listed version with the server's ETag.
        JsonObjectConst after = c["after"][idText];
        if (!after.isNull()) {
          CHECK_NAMED(name.c_str(), after["version"].as<std::string>() == book["updatedAt"].as<std::string>());
          CHECK_NAMED(name.c_str(), after["etag"].as<std::string>() == book["server_etag"].as<std::string>());
        }
      }
    }
    auto list = [](JsonVariantConst v) {
      std::vector<int> out;
      for (int id : v.as<JsonArrayConst>()) out.push_back(id);
      return out;
    };
    CHECK_NAMED((name + ": download").c_str(), download == list(c["download"]));
    CHECK_NAMED((name + ": remove").c_str(), removed == list(c["remove"]));
    if (!c["conditional"].isNull()) CHECK_NAMED((name + ": conditional").c_str(), conditional == list(c["conditional"]));
    if (!c["not_modified"].isNull())
      CHECK_NAMED((name + ": not modified").c_str(), notModified == list(c["not_modified"]));
  }
  // Open never retries a cover that failed this session; Refresh does.
  CoverOnDisk none;
  CHECK(planCover(Mode::Open, true, 1, none, true).action == CoverAction::None);
  CHECK(planCover(Mode::Open, true, 1, none, false).action == CoverAction::Download);
  // The X4 Home covers' <ver> is this hash (BookOrbitHomeStore: FNV-1a 32 of updatedAt).
  CHECK(coverVersion("") == 2166136261u);
}

// The overlay stays on top of a Full refresh: the server's entry is stored as sent, and the
// unsent local finish still takes the book out of Continue reading.
void fullRefreshOverlay(JsonObjectConst all) {
  // @fixture cache/cases.json#full_refresh_overlay
  for (JsonObjectConst c : all["full_refresh_overlay"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    JsonDocument entry;
    entry.set(c["server"]);
    const uint32_t stored = canonicalHash(entry.as<JsonVariantConst>());
    std::vector<int> shown;
    for (JsonObjectConst book : entry["continueReading"].as<JsonArrayConst>()) {
      const int id = book["id"];
      ServerBook s;
      s.percent = book["progressPercentage"] | -1;
      s.state = !std::strcmp(book["readStatus"] | "", "read") ? BookState::Complete : BookState::Reading;
      DeviceBook d;
      JsonObjectConst local = c["local"][std::to_string(id)];
      if (!local.isNull()) {
        d.known = true;
        d.percent = local["percent"];
        d.state = !std::strcmp(local["status"] | "", "complete") ? BookState::Complete : BookState::Reading;
        d.pending = local["pending"] | false;
      }
      if (overlayBook(s, d, true).state != BookState::Complete) shown.push_back(id);
    }
    std::vector<int> want;
    for (int id : c["expect_continue_reading"].as<JsonArrayConst>()) want.push_back(id);
    CHECK_NAMED(name, shown == want);
    CHECK_NAMED(name, canonicalHash(entry.as<JsonVariantConst>()) == stored);
  }
}

void sizeCap() {
  // Over the entry cap: the least recently used unpinned entries go first.
  std::vector<EntryInfo> e(5);
  for (size_t i = 0; i < e.size(); i++) e[i] = {100, static_cast<uint32_t>(10 + i), false};
  e[0].pinned = true;  // Home: oldest, but never evicted
  size_t drop[8];
  size_t n = entriesToEvict(e.data(), e.size(), 1000000, 3, drop, 8);
  CHECK(n == 2 && drop[0] == 1 && drop[1] == 2);
  // Over the byte cap.
  e[4].bytes = 900;
  n = entriesToEvict(e.data(), e.size(), 1000, 200, drop, 8);
  CHECK(n == 3 && drop[0] == 1 && drop[1] == 2 && drop[2] == 3);
  // Within both: nothing.
  CHECK(entriesToEvict(e.data(), e.size(), 2u * 1024u * 1024u, 200, drop, 8) == 0);
}


void indexRoundTrip() {
  Index index;
  index.owner = 0xABCD;
  index.clock = 9;
  IndexEntry e;
  e.hash = 1, e.bytes = 2, e.fetchedAt = 3, e.validatedAt = 4, e.usedAt = 5, e.replyHash = 6, e.flags = FLAG_NOT_UPDATED;
  e.url = "https://books.example/plugin/catalog/dashboard";
  index.entries.push_back(e);
  index.covers.push_back({7, coverVersion("2026-11-01T10:00:00Z"), "\"1730000000000\""});
  const std::string bytes = serializeIndex(index);
  Index back;
  CHECK(deserializeIndex(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), back));
  CHECK(back.owner == 0xABCD && back.clock == 9 && back.entries.size() == 1 && back.covers.size() == 1);
  CHECK(back.find(1) && back.find(1)->url == e.url && back.find(1)->replyHash == 6 && back.find(1)->flags == 1);
  CHECK(back.cover(7) && back.cover(7)->etag == "\"1730000000000\"" && !back.cover(8));
  // A torn or altered file reads as no cache.
  std::string bad = bytes;
  bad[10] ^= 1;
  CHECK(!deserializeIndex(reinterpret_cast<const uint8_t*>(bad.data()), bad.size(), back) && back.entries.empty());
  CHECK(!deserializeIndex(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size() - 3, back));
}

}  // namespace

static void recentItems() {
  JsonDocument saved, recent;
  deserializeJson(saved, R"({"items":[{"id":7,"title":"Old","authors":[{"name":"A"}],"local":"keep"},{"id":8,"title":"Other","authors":[]}],"facet":{"id":7,"title":"Scope"}})");
  deserializeJson(recent, R"([{"id":7,"title":"New","authors":[{"name":"B"}],"newField":"ignored"}])");
  CHECK(mergeRecentBooks(saved.as<JsonVariant>(), recent.as<JsonArrayConst>()));
  CHECK(saved["items"][0]["title"] == "New" && saved["items"][0]["authors"][0]["name"] == "B");
  CHECK(saved["items"][0]["local"] == "keep" && saved["items"][0]["newField"].isUnbound());
  CHECK(saved["items"][1]["title"] == "Other" && saved["facet"]["title"] == "Scope");
  CHECK(!mergeRecentBooks(saved.as<JsonVariant>(), recent.as<JsonArrayConst>()));
  std::string bytes;
  serializeJson(saved, bytes);
  JsonDocument reopened;
  CHECK(!deserializeJson(reopened, bytes));
  CHECK(reopened["items"][0]["title"] == "New");
}

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/cache";
  JsonDocument doc;
  if (!loadJsonFile((dir + "/cases.json").c_str(), doc)) return 1;
  JsonObjectConst all = doc.as<JsonObjectConst>();
  keys(all);
  reads(all);
  writes(all);
  covers(all);
  fullRefreshOverlay(all);
  recentItems();
  sizeCap();
  indexRoundTrip();
  return report("cache");
}
