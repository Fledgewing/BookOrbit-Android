#pragma once
// Orbify end-of-book card (docs/design/end-of-book/DESIGN.md §5, §6): what the End-of-Book page
// offers next, picked from a BookOrbit book detail (GET /koreader/plugin/catalog/books/:id) and
// cached per book in /.crosspoint/orbify_series/<bookId>.bin.
//
// Pure C++ with ArduinoJson: xteink/test/end_of_book_test.cpp runs it against
// shared/fixtures/bookorbit/finish-cases.json "picker", the table Android's picker reads too.
#include <ArduinoJson.h>

#include <cstddef>
#include <cstdint>

#include "FinishQueue.h"

namespace orbify {

struct CardBook {
  int64_t id = 0;
  char index[12] = {};  // seriesIndex as the server sends it ("2", "1.5"); empty for suggestions
  char title[72] = {};
};

struct SeriesCard {
  enum class Next : uint8_t { None = 0, Next, Gap, SeriesDone, LastUnread };
  enum class Source : uint8_t { Author = 0, Similar };
  static constexpr size_t MAX_SUGGESTIONS = 2;

  int64_t bookId = 0;
  ServerStatus status = ServerStatus::Unknown;  // the server's status for this book (status_seen)
  Next next = Next::None;
  bool nextRead = false;  // Next / LastUnread: that book is read already
  uint16_t missing = 0;   // Gap: the book number not in the library (floor(c) + 1)
  CardBook nextBook;      // Next / LastUnread
  uint8_t suggestionCount = 0;
  CardBook suggestions[MAX_SUGGESTIONS];
  Source sources[MAX_SUGGESTIONS] = {};
  char author[48] = {};  // authors[0], "" when the book has none
};

// The fields pickCard reads, as an ArduinoJson filter for a streamed detail reply.
void cardFilter(JsonDocument& filter);

// The §6 rules. maxSuggestions: 2 on Xteink (the X3's drop order may lower it to 0), 1 on Android.
// False when the detail is not a book.
bool pickCard(JsonObjectConst detail, size_t maxSuggestions, SeriesCard& out);

// The cache record: fixed size, versioned, with a CRC; deserialize is false for anything else.
constexpr size_t CARD_BYTES = 8 + sizeof(SeriesCard) + 4;
size_t serializeCard(const SeriesCard& card, uint8_t* out, size_t capacity);
bool deserializeCard(const uint8_t* data, size_t size, SeriesCard& out);

}  // namespace orbify
