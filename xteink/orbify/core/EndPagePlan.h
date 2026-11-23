#pragma once
// Orbify End-of-Book page (docs/design/end-of-book/DESIGN.md §5): which rows the page shows, in
// which order, and which go when the panel is too short for all of them. Pure C++: the firmware
// (../EndPage.cpp) supplies the theme's measured heights; xteink/test/end_of_book_test.cpp checks
// every card shape at 480x800 and 528x792 with the tallest theme.
#include <cstddef>
#include <cstdint>

#include "SeriesCard.h"

namespace orbify {

enum class RowKind : uint8_t {
  Status,      // "Finished · sends at next sync" / Undo
  Rating,      // X4 only; there before the book is finished too (dimmed), so rows never move
  Next,        // next in series, or the last unread one (card)
  Info,        // a gap, the series is done, or (index 1) the series without a card: text only
  Suggestion,  // a server suggestion (card), index = slot
  Folder,      // upstream's folder suggestion when there is no card, index = slot
  Author,      // "All books by <author>"
  Home,
};

struct RowSpec {
  RowKind kind = RowKind::Home;
  uint8_t index = 0;
  bool heading = false;  // a section heading is drawn above this row
};

struct PlanInput {
  bool finished = false;
  bool ratings = false;           // the platform has the rating row
  const SeriesCard* card = nullptr;
  uint8_t folderCount = 0;        // upstream's folder suggestions, used without a card
  uint8_t maxSuggestions = 2;     // CROSSINK_TAILNET_ORBIFY_SUGGESTIONS (X3 drop order)
  bool authorRow = true;          // CROSSINK_TAILNET_ORBIFY_AUTHOR_ROW (X3 drop order)
  // Without a card (offline, or the detail never fetched): what the book itself says.
  bool offlineSeries = false;     // the EPUB names a series: "<series> · Book n", connect to see more
  bool offlineAuthor = false;     // the EPUB names an author: "All books by <author>"
};

constexpr size_t MAX_ROWS = 9;

inline bool selectable(RowKind kind) { return kind != RowKind::Info; }

// The rows, top to bottom. Always ends with Home.
size_t planRows(const PlanInput& input, RowSpec* out, size_t capacity);

// Pixel heights the theme gives, measured on the device.
struct FitMetrics {
  int available = 0;  // the list band: below the title, above the button hints
  int rowHeight = 0;
  int headingHeight = 0;
};
int rowsHeight(const RowSpec* rows, size_t count, const FitMetrics& metrics);
// Drops rows until the rest fit: the last suggestion first, then the folder rows, then the author
// row, then the rating (§5's order; Status, Next and Home always stay). Returns the new count.
size_t fitRows(RowSpec* rows, size_t count, const FitMetrics& metrics);

// Offline, the series row names the book after this one from the EPUB's own series index:
// "2" -> "3", "2.5" -> "3", " 7 " -> "8". Empty (out has "") when the index is missing or not a
// number, and the row then names the series alone. out holds at least 8 bytes.
void nextSeriesIndex(const char* finishedIndex, char* out, size_t outSize);

}  // namespace orbify
