// Host test for Orbify's end-of-book card (xteink/orbify/core/SeriesCard, EndPagePlan): the next,
// gap, done, suggestion and author rules in shared/fixtures/bookorbit/finish-cases.json "picker"
// (Android's picker reads the same table) over the catalog-book.*.json details, read through the
// device's detail filter; the cache record; and the page's rows on both panels.
#include <ArduinoJson.h>

#include <cstdlib>
#include <cstring>
#include <string>

#include "CatalogCache.h"
#include "EndPagePlan.h"
#include "NextCover.h"
#include "SeriesCard.h"
#include "TestSupport.h"

using namespace orbify;

namespace {

const char* nextName(SeriesCard::Next n) {
  switch (n) {
    case SeriesCard::Next::Next: return "next";
    case SeriesCard::Next::Gap: return "gap";
    case SeriesCard::Next::SeriesDone: return "series_done";
    case SeriesCard::Next::LastUnread: return "last_unread";
    default: return "none";
  }
}

// The reply as the device reads it: streamed through cardFilter.
bool loadFiltered(const std::string& path, JsonDocument& doc) {
  JsonDocument full;
  if (!loadJsonFile(path.c_str(), full)) return false;
  std::string text;
  serializeJson(full, text);
  JsonDocument filter;
  cardFilter(filter);
  return deserializeJson(doc, text, DeserializationOption::Filter(filter)) == DeserializationError::Ok;
}

// §5 rows for one card, on both panels in both orientations, with the tallest theme's rows
// (RoundedRaff: 42 px rows) and a 30 px heading. The list band is what EndOfBookOptions leaves:
// below the title block (safe/8 + two text lines + spacing, at most 130 px) and above the hints.
void checkLayouts(const std::string& name, const SeriesCard& card) {
  static const int PANELS[][2] = {{480, 800}, {528, 792}, {800, 480}, {792, 528}};
  for (const bool ratings : {false, true}) {
    for (const bool finished : {false, true}) {
      PlanInput input;
      input.finished = finished;
      input.ratings = ratings;
      input.card = &card;
      RowSpec rows[MAX_ROWS];
      const size_t planned = planRows(input, rows, MAX_ROWS);
      CHECK_NAMED(name.c_str(), planned >= 2 && rows[0].kind == RowKind::Status && rows[planned - 1].kind == RowKind::Home);
      // The rating row is there whether or not the book is finished: rows never move under a tap.
      CHECK_NAMED(name.c_str(), (planned > 1 && rows[1].kind == RowKind::Rating) == ratings);
      const bool hasNext = card.next == SeriesCard::Next::Next || card.next == SeriesCard::Next::LastUnread;
      for (const auto& panel : PANELS) {
        RowSpec fitted[MAX_ROWS];
        for (size_t i = 0; i < planned; ++i) fitted[i] = rows[i];
        FitMetrics m;
        m.rowHeight = 42;
        m.headingHeight = 30;
        m.available = panel[1] - 130 - 40 - 20;
        const size_t n = fitRows(fitted, planned, m);
        const std::string where = name + " " + std::to_string(panel[0]) + "x" + std::to_string(panel[1]);
        CHECK_NAMED(where.c_str(), rowsHeight(fitted, n, m) <= m.available);
        bool next = false;
        for (size_t i = 0; i < n; ++i) next = next || fitted[i].kind == RowKind::Next;
        CHECK_NAMED(where.c_str(), next == hasNext);
        CHECK_NAMED(where.c_str(), fitted[0].kind == RowKind::Status && fitted[n - 1].kind == RowKind::Home);
        // Portrait keeps every row.
        if (panel[1] > panel[0]) CHECK_NAMED(where.c_str(), n == planned);
      }
    }
  }
}

void checkCase(const std::string& dir, JsonObjectConst c, const size_t maxSuggestions) {
  const std::string file = c["fixture"].as<const char*>();
  const std::string name = file + " max=" + std::to_string(maxSuggestions);
  JsonDocument doc;
  CHECK_NAMED(name.c_str(), loadFiltered(dir + "/" + file, doc));
  SeriesCard card;
  CHECK_NAMED(name.c_str(), pickCard(doc.as<JsonObjectConst>(), maxSuggestions, card));
  JsonVariantConst next = c["next"];
  const std::string kind = next.isNull() ? "none" : next["kind"].as<std::string>();
  CHECK_NAMED(name.c_str(), kind == nextName(card.next));
  if (!next["id"].isNull()) {
    CHECK_NAMED(name.c_str(), card.nextBook.id == next["id"].as<int64_t>());
    CHECK_NAMED(name.c_str(), card.nextBook.title[0] != '\0');
  }
  if (!next["read"].isNull()) CHECK_NAMED(name.c_str(), card.nextRead == next["read"].as<bool>());
  if (!next["number"].isNull()) {
    // gap: the missing book's number; last_unread: that book's series index.
    const double number = card.next == SeriesCard::Next::Gap ? card.missing : std::strtod(card.nextBook.index, nullptr);
    CHECK_NAMED(name.c_str(), number == next["number"].as<double>());
  }
  JsonArrayConst sugg = c[maxSuggestions == 1 ? "suggest1" : "suggest2"];
  CHECK_NAMED(name.c_str(), card.suggestionCount == sugg.size());
  for (size_t i = 0; i < sugg.size() && i < card.suggestionCount; ++i) {
    CHECK_NAMED(name.c_str(), card.suggestions[i].id == sugg[i].as<int64_t>());
    CHECK_NAMED(name.c_str(), card.suggestions[i].title[0] != '\0');
  }
  const char* author = c["author"].isNull() ? "" : c["author"].as<const char*>();
  CHECK_NAMED(name.c_str(), std::strcmp(card.author, author) == 0);
  // The page's "<series> · Book 2 of 4" line: the detail's own series name, index and member count.
  JsonObjectConst detail = doc.as<JsonObjectConst>();
  const char* seriesName = detail["seriesName"] | "";
  CHECK_NAMED(name.c_str(), std::strncmp(card.seriesName, seriesName, sizeof(card.seriesName) - 1) == 0);
  CHECK_NAMED(name.c_str(), card.seriesCount == detail["seriesMembers"].as<JsonArrayConst>().size());
  if (const char* index = detail["seriesIndex"].as<const char*>()) {
    CHECK_NAMED(name.c_str(), std::strcmp(card.seriesIndex, index) == 0);
  }

  // The cache record round-trips, and any flipped byte is refused.
  uint8_t buf[CARD_BYTES];
  CHECK_NAMED(name.c_str(), serializeCard(card, buf, sizeof(buf)) == CARD_BYTES);
  SeriesCard back;
  CHECK_NAMED(name.c_str(), deserializeCard(buf, sizeof(buf), back) && back.nextBook.id == card.nextBook.id &&
                                std::strcmp(back.author, card.author) == 0 &&
                                back.suggestionCount == card.suggestionCount &&
                                std::strcmp(back.seriesName, card.seriesName) == 0 &&
                                std::strcmp(back.seriesIndex, card.seriesIndex) == 0 &&
                                back.seriesCount == card.seriesCount);
  bool allRefused = true;
  for (size_t i = 0; i < CARD_BYTES; i += 7) {
    buf[i] ^= 0x20;
    allRefused = allRefused && !deserializeCard(buf, sizeof(buf), back);
    buf[i] ^= 0x20;
  }
  CHECK_NAMED(name.c_str(), allRefused);
  checkLayouts(name, card);
}

// The next book's cover (core/NextCover, X4 Pro and X4): the card's version 2, the version lookup,
// the file names and the sync's plan.
void checkCovers() {
  // Version 3 keeps the cover versions and the series line. A version 1 record (before covers) reads
  // as a card with none, never as a bad one, whatever its padding held; version 1 and 2 records
  // (before the series line, a shorter record) read as cards with no series name, index or count.
  SeriesCard card;
  card.bookId = 7;
  card.next = SeriesCard::Next::Next;
  card.nextBook.id = 8;
  std::strcpy(card.nextBook.title, "The Storm Signal");
  card.nextBook.coverVer = 0xABCD1234u;
  card.suggestionCount = 1;
  card.suggestions[0].id = 9;
  card.suggestions[0].coverVer = 0x55u;
  std::strcpy(card.author, "Mara Quill");
  std::strcpy(card.seriesName, "Harbour Lights");
  std::strcpy(card.seriesIndex, "2");
  card.seriesCount = 4;
  uint8_t buf[CARD_BYTES];
  SeriesCard back;
  CHECK(serializeCard(card, buf, sizeof(buf)) == CARD_BYTES && buf[4] == 3);
  CHECK(deserializeCard(buf, sizeof(buf), back) && back.nextBook.coverVer == 0xABCD1234u);
  CHECK(std::strcmp(back.seriesName, "Harbour Lights") == 0 && std::strcmp(back.seriesIndex, "2") == 0 &&
        back.seriesCount == 4);
  // What a version 2 firmware wrote: the same bytes up to the author, then its CRC.
  const size_t legacy = legacyCardBytes();
  CHECK(legacy < CARD_BYTES);
  const size_t legacyStruct = legacy - 12;
  auto relabel = [&](const uint8_t version) {
    buf[4] = version;
    buf[5] = static_cast<uint8_t>(legacyStruct & 0xFF);
    buf[6] = static_cast<uint8_t>(legacyStruct >> 8);
    const uint32_t c = slot::crc32(buf, 8 + legacyStruct);
    for (int i = 0; i < 4; ++i) buf[8 + legacyStruct + i] = static_cast<uint8_t>(c >> (8 * i));
  };
  relabel(2);
  CHECK(deserializeCard(buf, legacy, back));
  CHECK(back.nextBook.id == 8 && back.nextBook.coverVer == 0xABCD1234u && std::strcmp(back.author, "Mara Quill") == 0);
  CHECK(back.seriesName[0] == '\0' && back.seriesIndex[0] == '\0' && back.seriesCount == 0);
  CHECK(!deserializeCard(buf, CARD_BYTES, back));  // a version 2 record is the shorter one
  relabel(1);  // version 1: its padding where coverVer is now
  CHECK(deserializeCard(buf, legacy, back));
  CHECK(back.nextBook.id == 8 && std::strcmp(back.nextBook.title, "The Storm Signal") == 0 &&
        std::strcmp(back.author, "Mara Quill") == 0 && back.suggestionCount == 1 && back.suggestions[0].id == 9);
  CHECK(back.nextBook.coverVer == 0 && back.suggestions[0].coverVer == 0);
  CHECK(serializeCard(card, buf, sizeof(buf)) == CARD_BYTES);
  buf[4] = 4;  // a newer version than this firmware knows
  uint32_t crc = slot::crc32(buf, CARD_BYTES - 4);
  for (int i = 0; i < 4; ++i) buf[CARD_BYTES - 4 + i] = static_cast<uint8_t>(crc >> (8 * i));
  CHECK(!deserializeCard(buf, sizeof(buf), back));

  // The version is the Home store's FNV-1a 32 of updatedAt (BookOrbitCatalogClient hashText).
  CHECK(cover::versionOfUpdatedAt("") == 0x811C9DC5u && cover::versionOfUpdatedAt(nullptr) == 0x811C9DC5u);
  CHECK(cover::versionOfUpdatedAt("a") == 0xE40C292Cu);
  CHECK(cover::versionOfUpdatedAt("2026-11-02T10:00:00.000Z") == cache::coverVersion("2026-11-02T10:00:00.000Z"));
  // From the related sections, read through the device's filter (cardFilter + addToFilter).
  const char* detail = R"({"id":102,"seriesId":1,"seriesIndex":"2","authors":["A"],"description":"long",
    "seriesMembers":[{"id":101,"seriesIndex":"1"},{"id":102,"seriesIndex":"2"},{"id":103,"seriesIndex":"3"},
                     {"id":104,"seriesIndex":"4"},{"id":110,"seriesIndex":"10"}],
    "relatedSections":[{"id":"series","books":[{"id":101,"hasCover":true,"updatedAt":"x"},
        {"id":103,"title":"Three","hasCover":true,"updatedAt":"2026-11-02T10:00:00.000Z","thumbnailUrl":"t"},
        {"id":104,"hasCover":false,"updatedAt":"y"}]},
      {"id":"author","books":[{"id":201,"title":"B","hasCover":true,"updatedAt":"z"}]}]})";
  JsonDocument filter;
  cardFilter(filter);
  cover::addToFilter(filter);
  JsonDocument doc;
  CHECK(deserializeJson(doc, detail, DeserializationOption::Filter(filter)) == DeserializationError::Ok);
  CHECK(doc["description"].isNull() && doc["relatedSections"][0]["books"][1]["thumbnailUrl"].isNull());
  CHECK(pickCard(doc.as<JsonObjectConst>(), 2, card) && card.next == SeriesCard::Next::Next && card.nextBook.id == 103);
  CHECK(card.nextBook.coverVer == 0);  // pickCard leaves it to the cover switch
  uint32_t version = 1;
  CHECK(cover::versionIn(doc.as<JsonObjectConst>(), 103, version) == cover::Lookup::Found &&
        version == cache::coverVersion("2026-11-02T10:00:00.000Z"));
  CHECK(cover::versionIn(doc.as<JsonObjectConst>(), 201, version) == cover::Lookup::Found &&
        version == cache::coverVersion("z"));
  CHECK(cover::versionIn(doc.as<JsonObjectConst>(), 104, version) == cover::Lookup::NoCover && version == 0);
  // Book 10 is past the series section's first 8: its own detail answers.
  CHECK(cover::versionIn(doc.as<JsonObjectConst>(), 110, version) == cover::Lookup::NotListed && version == 0);
  CHECK(cover::versionIn(doc.as<JsonObjectConst>(), 0, version) == cover::Lookup::NotListed);
  JsonDocument own;
  deserializeJson(own, R"({"id":110,"hasCover":true,"updatedAt":"w"})");
  CHECK(cover::versionOf(own.as<JsonObjectConst>(), version) == cover::Lookup::Found && version == cache::coverVersion("w"));
  deserializeJson(own, R"({"id":110,"hasCover":false,"updatedAt":"w"})");
  CHECK(cover::versionOf(own.as<JsonObjectConst>(), version) == cover::Lookup::NoCover && version == 0);

  // Paths: the cards' directory, never the Home store's (its prune lists only that one).
  char path[96];
  CHECK(cover::bmpPath(cover::DIR, 103, 0x0000ABCDu, 60, 90, path, sizeof(path)) &&
        std::strcmp(path, "/.crosspoint/orbify_series/103_0000abcd_60x90.bmp") == 0);
  CHECK(std::strncmp(path, cover::HOME_DIR, std::strlen(cover::HOME_DIR)) != 0);
  CHECK(std::strncmp(path, "/.crosspoint/bookorbit_home/", 28) != 0);
  CHECK(cover::jpgPath(103, 0x0000ABCDu, path, sizeof(path)) &&
        std::strcmp(path, "/.crosspoint/orbify_series/103_0000abcd.jpg") == 0);
  CHECK(!cover::bmpPath(cover::DIR, 103, 1, 60, 90, path, 20));
  // The Home store's names (BookOrbitHomeStore::coverPath) parse the same way.
  CHECK(cover::bmpPath(cover::HOME_DIR, 103, 0xFFFFFFFFu, 96, 144, path, sizeof(path)) &&
        std::strcmp(path, "/.crosspoint/bookorbit_home/103_ffffffff_96x144.bmp") == 0);
  cover::Name name;
  CHECK(cover::parseName("103_0000abcd_60x90.bmp", name) && name.bookId == 103 && name.version == 0xABCDu &&
        name.width == 60 && name.height == 90 && !name.jpg);
  CHECK(cover::parseName("103_0000abcd.jpg", name) && name.bookId == 103 && name.version == 0xABCDu && name.jpg);
  const char* notCovers[] = {"103.bin", "103_abcd_60x90.bmp", "103_0000abcd_60x90.jpg", "103_0000abcd_60x.bmp",
                             "_0000abcd.jpg", "103_0000abcg.jpg", "103_0000abcd_60x90.bmp.tmp", "x", ""};
  for (const char* n : notCovers) CHECK_NAMED(n, !cover::parseName(n, name));
  // Stale: this book at another version; other books and this version stay.
  cover::parseName("103_00000001_60x90.bmp", name);
  CHECK(cover::isStale(name, 103, 2, 60, 90) && !cover::isStale(name, 103, 1, 60, 90) &&
        !cover::isStale(name, 104, 2, 60, 90));
  CHECK(cover::isStale(name, 103, 1, 64, 96));  // another size: an older page's
  cover::parseName("103_00000001.jpg", name);
  CHECK(cover::isStale(name, 103, 2, 60, 90) && !cover::isStale(name, 103, 1, 60, 90));

  // The sync's plan.
  cover::Disk disk;
  CHECK(cover::plan(0, disk) == cover::Step::None);  // no cover known: nothing, the row looks as today
  CHECK(cover::plan(5, disk) == cover::Step::Download);
  disk.bmp = true;
  CHECK(cover::plan(5, disk) == cover::Step::None);
  disk = cover::Disk{};
  disk.pending = true;  // fetched, waiting for the radio-off decode
  CHECK(cover::plan(5, disk) == cover::Step::None);
  disk = cover::Disk{};
  disk.homeBmp = true;  // Home shows this book: its BMP is copied, nothing downloaded
  disk.kept = true;
  disk.keptVersion = 4;
  disk.hasEtag = true;
  CHECK(cover::plan(5, disk) == cover::Step::CopyHome);
  disk.homeBmp = false;
  CHECK(cover::plan(5, disk) == cover::Step::Conditional);
  // A 304 to If-None-Match: the kept file takes the new name; no JPEG, no decode.
  CHECK(cover::afterFetch(false, 304, cover::Step::Conditional) == cover::After::RenameKept);
  CHECK(cover::afterFetch(true, 200, cover::Step::Conditional) == cover::After::Decode);
  CHECK(cover::afterFetch(false, 500, cover::Step::Conditional) == cover::After::Drop);
  CHECK(cover::afterFetch(false, 304, cover::Step::Download) == cover::After::Drop);
  disk.hasEtag = false;
  CHECK(cover::plan(5, disk) == cover::Step::Download);
  disk.hasEtag = true;
  disk.keptVersion = 5;  // the record says this version, the file is not here: fetch it whole
  CHECK(cover::plan(5, disk) == cover::Step::Download);

  // The Next row with a cover is taller: fitRows counts it, and drops the rest before it.
  SeriesCard full;
  full.next = SeriesCard::Next::Next;
  full.suggestionCount = 2;
  std::strcpy(full.author, "A");
  PlanInput in;
  in.finished = in.ratings = true;
  in.card = &full;
  RowSpec rows[MAX_ROWS];
  size_t n = planRows(in, rows, MAX_ROWS);
  FitMetrics plain{0, 40, 20};
  FitMetrics tall = plain;
  tall.nextRowHeight = 100;
  CHECK(rowsHeight(rows, n, tall) == rowsHeight(rows, n, plain) + 60);
  tall.available = plain.available = rowsHeight(rows, n, plain);
  RowSpec copy[MAX_ROWS];
  for (size_t i = 0; i < n; ++i) copy[i] = rows[i];
  CHECK(fitRows(copy, n, plain) == n);  // without a cover, every row fits as before
  const size_t kept = fitRows(rows, n, tall);
  CHECK(kept < n && rowsHeight(rows, kept, tall) <= tall.available);
  bool next = false;
  for (size_t i = 0; i < kept; ++i) next = next || rows[i].kind == RowKind::Next;
  CHECK(next && rows[kept - 1].kind == RowKind::Home);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  const std::string dir = argv[1];
  JsonDocument doc;
  if (!loadJsonFile((dir + "/finish-cases.json").c_str(), doc)) return 1;
  for (JsonObjectConst c : doc["picker"].as<JsonArrayConst>()) {
    checkCase(dir, c, 1);
    checkCase(dir, c, 2);
  }

  // Numbers for seriesIndex (older servers), long titles cut on a UTF-8 boundary, no id.
  JsonDocument d;
  deserializeJson(d, R"({"id":5,"seriesId":1,"seriesIndex":1,"authors":["A"],
    "seriesMembers":[{"id":5,"seriesIndex":1},{"id":6,"seriesIndex":2,"title":
    "ééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé"}]})");
  SeriesCard card;
  CHECK(pickCard(d.as<JsonObjectConst>(), 2, card) && card.next == SeriesCard::Next::Next &&
        card.nextBook.id == 6 && std::strcmp(card.nextBook.index, "2") == 0);
  const size_t len = std::strlen(card.nextBook.title);
  CHECK(len > 0 && len < sizeof(card.nextBook.title) && len % 2 == 0);
  JsonDocument none;
  deserializeJson(none, "{}");
  CHECK(!pickCard(none.as<JsonObjectConst>(), 2, card));
  // No card: the folder rows under one heading; the drop order takes suggestions first, then
  // folder rows, then the author row.
  PlanInput folder;
  folder.folderCount = 3;
  RowSpec rows[MAX_ROWS];
  size_t n = planRows(folder, rows, MAX_ROWS);
  CHECK(n == 5 && rows[1].kind == RowKind::Folder && rows[1].heading && !rows[2].heading);
  SeriesCard full;
  full.next = SeriesCard::Next::Next;
  full.suggestionCount = 2;
  full.sources[1] = SeriesCard::Source::Similar;
  std::strcpy(full.author, "A");
  PlanInput in;
  in.finished = in.ratings = true;
  in.card = &full;
  n = planRows(in, rows, MAX_ROWS);
  CHECK(n == 7 && rows[3].heading && rows[4].heading && rows[5].kind == RowKind::Author);
  FitMetrics tight{0, 40, 20};
  tight.available = rowsHeight(rows, n, tight) - 1;
  CHECK(fitRows(rows, n, tight) == 6 && rows[3].kind == RowKind::Suggestion && rows[4].kind == RowKind::Author);
  n = planRows(in, rows, MAX_ROWS);
  tight.available = 5 * 40 + 20;  // status, rating, next + heading, author, home
  n = fitRows(rows, n, tight);
  CHECK(n == 5 && rows[3].kind == RowKind::Author);
  in.maxSuggestions = 0;
  in.authorRow = false;
  CHECK(planRows(in, rows, MAX_ROWS) == 4);
  // No card (offline): the EPUB's series under "Next in series" with "Connect to see what's
  // next" (Info index 1), the folder rows, then "All books by" from the EPUB's author.
  PlanInput offline;
  offline.ratings = true;
  offline.offlineSeries = true;
  offline.offlineAuthor = true;
  offline.folderCount = 2;
  n = planRows(offline, rows, MAX_ROWS);
  CHECK(n == 7 && rows[0].kind == RowKind::Status && rows[1].kind == RowKind::Rating);
  CHECK(rows[2].kind == RowKind::Info && rows[2].index == 1 && rows[2].heading);
  CHECK(rows[3].kind == RowKind::Folder && rows[3].heading && rows[4].kind == RowKind::Folder);
  CHECK(rows[5].kind == RowKind::Author && rows[6].kind == RowKind::Home);
  // Unfinished: the same rows in the same places (the rating row is dimmed, not removed).
  RowSpec unfinished[MAX_ROWS];
  offline.finished = false;
  CHECK(planRows(offline, unfinished, MAX_ROWS) == n);
  offline.finished = true;
  RowSpec finishedRows[MAX_ROWS];
  CHECK(planRows(offline, finishedRows, MAX_ROWS) == n);
  for (size_t i = 0; i < n; ++i) CHECK(unfinished[i].kind == finishedRows[i].kind);
  // The offline series row names the next book, never the finished one.
  {
    char next[8];
    const char* cases[][2] = {{"2", "3"}, {"2.5", "3"}, {" 7 ", "8"}, {"0", "1"}, {"12.0", "13"},
                              {"", ""}, {"two", ""}, {"2a", ""}, {"-1", ""}, {"1234567", ""}};
    for (const auto& c : cases) {
      nextSeriesIndex(c[0], next, sizeof(next));
      CHECK_NAMED(c[0], std::strcmp(next, c[1]) == 0);
    }
    nextSeriesIndex(nullptr, next, sizeof(next));
    CHECK(next[0] == '\0');
  }
  // Nothing known about the book: no offline series row, no author row.
  PlanInput bare;
  CHECK(planRows(bare, rows, MAX_ROWS) == 2);
  bare.authorRow = false;
  bare.offlineAuthor = true;
  CHECK(planRows(bare, rows, MAX_ROWS) == 2);
  checkCovers();
  return report("end-of-book");
}
