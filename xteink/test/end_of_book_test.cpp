// Host test for Orbify's end-of-book card (xteink/orbify/core/SeriesCard, EndPagePlan): the next,
// gap, done, suggestion and author rules in shared/fixtures/bookorbit/finish-cases.json "picker"
// (Android's picker reads the same table) over the catalog-book.*.json details, read through the
// device's detail filter; the cache record; and the page's rows on both panels.
#include <ArduinoJson.h>

#include <cstdlib>
#include <cstring>
#include <string>

#include "EndPagePlan.h"
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

  // The cache record round-trips, and any flipped byte is refused.
  uint8_t buf[CARD_BYTES];
  CHECK_NAMED(name.c_str(), serializeCard(card, buf, sizeof(buf)) == CARD_BYTES);
  SeriesCard back;
  CHECK_NAMED(name.c_str(), deserializeCard(buf, sizeof(buf), back) && back.nextBook.id == card.nextBook.id &&
                                std::strcmp(back.author, card.author) == 0 &&
                                back.suggestionCount == card.suggestionCount);
  bool allRefused = true;
  for (size_t i = 0; i < CARD_BYTES; i += 7) {
    buf[i] ^= 0x20;
    allRefused = allRefused && !deserializeCard(buf, sizeof(buf), back);
    buf[i] ^= 0x20;
  }
  CHECK_NAMED(name.c_str(), allRefused);
  checkLayouts(name, card);
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
  return report("end-of-book");
}
