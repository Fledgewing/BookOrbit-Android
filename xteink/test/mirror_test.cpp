// orbify/core/Mirror: the X4 offline mirror (docs/design/write-through-cache.md "Offline mirror"):
// when it is due (the shared table shared/fixtures/cache/cases.json "mirror.due", which Android's
// tests read too), the plan of requests a Full refresh saves, and the catalog browser's own
// mapping from a facet row to its book list, so the mirror asks exactly what the browser will.
#include <ArduinoJson.h>

#include <cstring>
#include <string>

#include "Mirror.h"
#include "TestSupport.h"

using namespace orbify::mirror;

static void dueCases(JsonObjectConst all) {
  for (JsonObjectConst c : all["mirror"]["due"].as<JsonArrayConst>()) {
    const bool saved = !c["mirror"].isNull();
    const uint32_t at = saved ? c["mirror"]["at"].as<uint32_t>() : 0;
    const char* savedLib = saved ? (c["mirror"]["lib_version"] | "") : "";
    const char* libNow = c["lib_version"] | "";
    const Due d = due(saved, at, savedLib, libNow, c["now"].as<uint32_t>(), c["ttl_days"].as<uint32_t>());
    const char* want = c["due"].isNull() ? "none" : c["due"].as<const char*>();
    CHECK_NAMED(c["name"].as<const char*>(), std::strcmp(dueName(d), want) == 0);
  }
  // A clock that went backwards is not "older than the TTL"; no clock at all is never due by age.
  CHECK(due(true, 5000, "a", "a", 4000, 7) == Due::None);
  CHECK(due(true, 5000, "a", "a", 0, 7) == Due::None);
  // A library version unknown on either side never makes it due.
  CHECK(due(true, 1000, "", "b", 2000, 7) == Due::None);
  CHECK(due(true, 1000, "a", "", 2000, 7) == Due::None);
  // TTL 0: automatic Full refresh off; only a never-saved mirror or a hand start runs it.
  CHECK(due(true, 1000, "a", "a", 99999999, 0) == Due::None);
  CHECK(due(true, 1000, "a", "b", 2000, 0) == Due::None);
}

static void facets() {
  // The browser's root: these five list facets, the rest list books.
  for (const char* id : {"authors", "series", "collections", "libraries", "smart-scopes"}) CHECK(isFacetSection(id));
  for (const char* id : {"recent", "want-to-read", "reading", ""}) CHECK(!isFacetSection(id));
  // A facet row's book list: BookOrbitCatalogBrowserActivity::activateSelected, EntryType::FACET.
  FacetQuery q = facetQuery("series", "Harbour Lights", "4");
  CHECK(q.sort == "series" && q.seriesId == "4" && q.series.empty());
  q = facetQuery("series", "Harbour Lights", "");
  CHECK(q.sort == "series" && q.seriesId.empty() && q.series == "Harbour Lights");
  q = facetQuery("collections", "12", "");
  CHECK(q.sort == "title" && q.collectionId == "12" && q.author.empty());
  q = facetQuery("libraries", "3", "");
  CHECK(q.sort == "title" && q.libraryId == "3");
  q = facetQuery("smart-scopes", "9", "");
  CHECK(q.sort == "title" && q.smartScopeId == "9");
  q = facetQuery("authors", "Mara Quill", "");
  CHECK(q.sort.empty() && q.author == "Mara Quill" && q.seriesId.empty());
}

static void plan() {
  Plan p;
  CHECK(p.empty() && p.next() == nullptr);
  CHECK(p.add(Kind::Root, ""));
  CHECK(!p.add(Kind::Root, ""));  // once
  CHECK(p.add(Kind::Section, "series"));
  CHECK(p.add(Kind::Books, "sort=series\x1fseriesId=4"));
  CHECK(!p.add(Kind::Books, "sort=series\x1fseriesId=4"));
  CHECK(p.add(Kind::Detail, "1208"));
  CHECK(p.total() == 4 && p.doneCount() == 0);
  // In order, one at a time.
  CHECK(p.next()->kind == Kind::Root);
  p.advance();
  CHECK(p.next()->kind == Kind::Section && p.next()->arg == "series");
  // A step already done is not added again, even after it ran.
  CHECK(!p.add(Kind::Root, ""));
  // Kept on the card and read back where it stopped (a wake or a reset resumes it).
  const std::string text = p.serialize();
  Plan back;
  CHECK(back.parse(text));
  CHECK(back.total() == 4 && back.doneCount() == 1);
  CHECK(back.next()->kind == Kind::Section && back.next()->arg == "series");
  CHECK(!back.add(Kind::Detail, "1208"));
  back.advance();
  back.advance();
  back.advance();
  CHECK(back.next() == nullptr && back.finished());
  // Damaged or foreign files are not a plan.
  Plan bad;
  CHECK(!bad.parse(""));
  CHECK(!bad.parse("something else\n0\n"));
  CHECK(!bad.parse("orbify-mirror 1\nx\n"));
  CHECK(!bad.parse("orbify-mirror 1\n9\nR\t\n"));  // done past the end
  CHECK(!bad.parse("orbify-mirror 1\n0\nQ\tzz\n"));  // unknown kind
  // The cap: the 200-entry cache keeps room for the views read by hand.
  Plan big;
  size_t added = 0;
  for (int i = 0; i < 400; i++) added += big.add(Kind::Detail, std::to_string(i)) ? 1 : 0;
  CHECK(added == MAX_STEPS && big.total() == MAX_STEPS);
  // Per-kind caps leave room for the others: lists of one facet, details.
  CHECK(MAX_LISTS_PER_FACET * 5 + MAX_DETAILS < MAX_STEPS);
}

static void queries() {
  // A book query travels in the plan as one tab-free field, and comes back the same.
  FacetQuery q;
  q.sort = "series";
  q.seriesId = "4";
  q.series = "Harbour\tLights";  // a tab in a name must not split the line
  q.author = "Quill, Mara";
  const std::string enc = encodeQuery(q);
  CHECK(enc.find('\t') == std::string::npos && enc.find('\n') == std::string::npos);
  FacetQuery back;
  CHECK(decodeQuery(enc, back));
  CHECK(back.sort == "series" && back.seriesId == "4" && back.author == "Quill, Mara");
  CHECK(back.series == "Harbour Lights");  // tabs become spaces
  FacetQuery shelf;
  shelf.shelf = "want-to-read";
  CHECK(decodeQuery(encodeQuery(shelf), back) && back.shelf == "want-to-read" && back.sort.empty());
  CHECK(!decodeQuery("nonsense", back));
}

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/cache";
  JsonDocument doc;
  if (!loadJsonFile((dir + "/cases.json").c_str(), doc)) return 1;
  dueCases(doc.as<JsonObjectConst>());
  facets();
  plan();
  queries();
  return report("mirror");
}
