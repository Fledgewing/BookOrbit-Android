// orbify/core/Mirror: the X4 offline mirror (docs/design/write-through-cache.md "Offline mirror"):
// when it is due (the shared table shared/fixtures/cache/cases.json "mirror.due", which Android's
// tests read too), the plan of requests a Full refresh saves, and the catalog browser's own
// mapping from a facet row to its book list, so the mirror asks exactly what the browser will.
#include <ArduinoJson.h>

#include <cstring>
#include <string>
#include <vector>

#include "Mirror.h"
#include "TestSupport.h"

using namespace orbify::mirror;

static void dueCases(JsonObjectConst all) {
  // @fixture cache/cases.json#mirror.due
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
  // Patch 0038, cache-first: only a saved, current copy opens the catalog without Wi-Fi.
  CHECK(catalogFromCache(true, Due::None));
  CHECK(!catalogFromCache(true, Due::Ttl) && !catalogFromCache(true, Due::Library));
  CHECK(!catalogFromCache(false, Due::None) && !catalogFromCache(false, Due::Never));
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
  CHECK(!bad.parse("orbify-mirror 2\nx\n"));
  CHECK(!bad.parse("orbify-mirror 2\n9\nR\t\n"));  // done past the end
  CHECK(!bad.parse("orbify-mirror 2\n0\nQ\tzz\n"));  // unknown kind
  // A version 1 plan joined a book list's fields with a space (a 400 on the device): not resumed.
  CHECK(!bad.parse("orbify-mirror 1\n0\nB\tsort=recently_read readStatus=reading\n"));
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

// Every kind of book list the mirror asks for, through the plan and back: what the walker sends is
// what the browser sends. The X4 Pro test of rc3 sent "sort=recently_read readStatus=reading" as one
// sort value (the plan turned the field separator into a space): the server answered 400.
static void requestKinds() {
  std::vector<FacetQuery> lists;
  // The root's book sections (BookOrbitCatalogClient::sectionBookQuery).
  FacetQuery reading;
  reading.sort = "recently_read";
  reading.readStatus = "reading";
  lists.push_back(reading);
  FacetQuery all;
  all.sort = "title";
  lists.push_back(all);
  FacetQuery wanted;
  wanted.shelf = "want-to-read";
  lists.push_back(wanted);
  FacetQuery added;
  added.sort = "recently_added";
  lists.push_back(added);
  // A facet row's list, each facet section.
  lists.push_back(facetQuery("series", "Harbour Lights", "4"));
  lists.push_back(facetQuery("series", "Harbour Lights", ""));
  lists.push_back(facetQuery("collections", "12", ""));
  lists.push_back(facetQuery("libraries", "3", ""));
  lists.push_back(facetQuery("smart-scopes", "9", ""));
  lists.push_back(facetQuery("authors", "Quill, Mara", ""));
  // Every field at once, in case a later list sets more than these.
  FacetQuery every;
  every.sort = "s";
  every.order = "o";
  every.readStatus = "r";
  every.shelf = "sh";
  every.query = "q w";
  every.author = "a";
  every.seriesId = "1";
  every.series = "se";
  every.collectionId = "2";
  every.smartScopeId = "3";
  every.libraryId = "4";
  lists.push_back(every);

  // The request each one sends after the mirror's plan file (booksPath, which booksUrl() uses on the
  // X4s): one parameter per field, as BookOrbit's API takes them. The device's 400s were
  // "sort=recently_read%20readStatus%3Dreading" and "sort=series%20seriesId%3D3964".
  const char* B = "/plugin/catalog/books?page=1&size=20&format=epub";
  const std::vector<std::string> urls = {
      std::string(B) + "&sort=recently_read&readStatus=reading",
      std::string(B) + "&sort=title",
      "/plugin/catalog/dashboard/sections/want-to-read",
      std::string(B) + "&sort=recently_added",
      std::string(B) + "&sort=series&seriesId=4",
      std::string(B) + "&sort=series&series=Harbour%20Lights",
      std::string(B) + "&sort=title&collectionId=12",
      std::string(B) + "&sort=title&libraryId=3",
      std::string(B) + "&sort=title&smartScopeId=9",
      std::string(B) + "&author=Quill%2C%20Mara",
      "/plugin/catalog/dashboard/sections/sh",  // a shelf is listed alone
  };
  CHECK(urls.size() == lists.size());
  FacetQuery noShelf = every;
  noShelf.shelf.clear();
  CHECK(booksPath(noShelf, 2, 20, true) ==
        "/plugin/catalog/books?page=2&size=20&format=epub&buckets=true&sort=s&order=o&readStatus=r&q=q%20w&author=a"
        "&seriesId=1&collectionId=2&smartScopeId=3&libraryId=4");
  FacetQuery seriesId;
  seriesId.sort = "series";
  seriesId.seriesId = "3964";
  CHECK(booksPath(seriesId, 1, 20, false) == std::string(B) + "&sort=series&seriesId=3964");

  Plan p;
  CHECK(p.add(Kind::Root, ""));
  CHECK(p.add(Kind::Section, "series"));
  CHECK(p.add(Kind::Detail, "1207"));
  for (const FacetQuery& q : lists) CHECK(p.add(Kind::Books, encodeQuery(q)));
  Plan back;
  CHECK(back.parse(p.serialize()));
  CHECK(back.total() == p.total());
  size_t books = 0;
  while (const Step* step = back.next()) {
    if (step->kind == Kind::Root) CHECK(step->arg.empty());
    if (step->kind == Kind::Section) CHECK(step->arg == "series");
    if (step->kind == Kind::Detail) CHECK(step->arg == "1207");
    if (step->kind == Kind::Books) {
      FacetQuery got;
      CHECK(decodeQuery(step->arg, got));
      CHECK_NAMED(urls[books].c_str(), booksPath(got, 1, 20, false) == urls[books]);
      const FacetQuery& want = lists[books++];
      CHECK(got.sort == want.sort && got.order == want.order && got.readStatus == want.readStatus);
      CHECK(got.shelf == want.shelf && got.query == want.query && got.author == want.author);
      CHECK(got.seriesId == want.seriesId && got.series == want.series);
      CHECK(got.collectionId == want.collectionId && got.smartScopeId == want.smartScopeId);
      CHECK(got.libraryId == want.libraryId);
      // No field value carries another field inside it.
      CHECK(got.sort.find('=') == std::string::npos && got.sort.find(' ') == std::string::npos);
    }
    back.advance();
  }
  CHECK(books == lists.size());
  // The exact device case.
  Plan one;
  one.add(Kind::Books, encodeQuery(reading));
  FacetQuery got;
  CHECK(decodeQuery(one.next()->arg, got));
  CHECK(got.sort == "recently_read" && got.readStatus == "reading");
}

// One progress number for a Full refresh (docs/design/sqlite-cache.md "Xteink: the same rule"):
// done * 100 / total, never down while the root and the sections add their lists, 100 only at the
// end, kept across a wake or a reset with the plan.
static void progress() {
  Plan p;
  CHECK(p.percent() == 0);
  p.add(Kind::Root, "");
  p.add(Kind::Books, "a");
  CHECK(p.percent() == 0);
  p.advance();  // 1 of 2
  CHECK(p.percent() == 50);
  // The root landed: its sections add lists, so done / total falls to 1 / 10...
  for (int i = 0; i < 8; i++) p.add(Kind::Section, std::to_string(i));
  CHECK(p.total() == 10);
  // ...but the % shown never goes down.
  CHECK(p.percent() == 50);
  unsigned last = p.percent();
  bool rose = false;
  while (!p.finished()) {
    p.advance(p.doneCount() == 3);  // one request fails
    if (p.doneCount() == 4) {  // a section adds 20 more mid-run
      for (int i = 0; i < 20; i++) p.add(Kind::Books, "s" + std::to_string(i));
    }
    const unsigned now = p.percent();
    CHECK(now >= last);
    if (!p.finished()) CHECK(now < 100);
    rose = rose || now > last;
    last = now;
  }
  CHECK(rose && p.percent() == 100 && p.failures() == 1);
  // The fixed total: the plan's own (step count), whatever the walk added, read back from the card.
  Plan half;
  for (int i = 0; i < 40; i++) half.add(Kind::Detail, std::to_string(i));
  for (int i = 0; i < 10; i++) half.advance(i == 0);
  CHECK(half.percent() == 25 && half.total() == 40);
  for (int i = 0; i < 40; i++) half.add(Kind::Books, "x" + std::to_string(i));  // 10 of 80 now
  CHECK(half.percent() == 25);
  Plan back;
  CHECK(back.parse(half.serialize()));
  CHECK(back.percent() == 25 && back.failures() == 1 && back.doneCount() == 10 && back.total() == 80);
  back.advance();  // 11 / 80 = 13%: still 25
  CHECK(back.percent() == 25);
  // A version 2 plan (before the % was kept) still resumes, from its own done / total.
  Plan old;
  CHECK(old.parse("orbify-mirror 2\n1\nR\t\nB\tsort=title\n"));
  CHECK(old.percent() == 50 && old.failures() == 0);
  CHECK(!old.parse("orbify-mirror 3\n1\nR\t\n"));            // version 3 needs the % and failures
  CHECK(!old.parse("orbify-mirror 3\n1\t101\t0\nR\t\n"));   // no % over 100
  CHECK(!old.parse("orbify-mirror 3\n1\t10\t2\nR\t\n"));    // more failures than requests
  CHECK(old.parse("orbify-mirror 3\n1\t70\t1\nR\t\nB\tsort=title\n") && old.percent() == 70);
}

static void badge() {
  // The first paint is always due; then only a changed %, and at most every 3 s.
  CHECK(badgeDue(-1, 0, 0, 0));
  CHECK(!badgeDue(37, 37, 0, 99999));
  CHECK(!badgeDue(37, 38, 1000, 1000 + BADGE_REPAINT_MS - 1));
  CHECK(badgeDue(37, 38, 1000, 1000 + BADGE_REPAINT_MS));
  char text[40];
  badgeText(37, false, 2, text, sizeof(text));
  CHECK(std::strcmp(text, "37%") == 0);
  badgeText(100, true, 0, text, sizeof(text));
  CHECK(std::strcmp(text, "Done") == 0);
  badgeText(100, true, 1, text, sizeof(text));
  CHECK(std::strcmp(text, "Done with 1 error") == 0);
  badgeText(100, true, 12, text, sizeof(text));
  CHECK(std::strcmp(text, "Done with 12 errors") == 0);
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
  requestKinds();
  progress();
  badge();
  return report("mirror");
}
