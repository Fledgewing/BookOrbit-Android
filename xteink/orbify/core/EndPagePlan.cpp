#include "EndPagePlan.h"

namespace orbify {

size_t planRows(const PlanInput& input, RowSpec* out, const size_t capacity) {
  size_t n = 0;
  const auto add = [&](RowKind kind, uint8_t index, bool heading) {
    if (n < capacity) out[n++] = RowSpec{kind, index, heading};
  };
  add(RowKind::Status, 0, false);
  if (input.ratings && input.finished) add(RowKind::Rating, 0, false);
  const SeriesCard* card = input.card;
  if (card) {
    switch (card->next) {
      case SeriesCard::Next::Next:
      case SeriesCard::Next::LastUnread:
        add(RowKind::Next, 0, true);
        break;
      case SeriesCard::Next::Gap:
      case SeriesCard::Next::SeriesDone:
        add(RowKind::Info, 0, true);
        break;
      case SeriesCard::Next::None:
        break;
    }
    const uint8_t count = card->suggestionCount < input.maxSuggestions ? card->suggestionCount : input.maxSuggestions;
    for (uint8_t i = 0; i < count; ++i) {
      // A heading where the source changes: "Also by <author>", then "You might like".
      add(RowKind::Suggestion, i, i == 0 || card->sources[i] != card->sources[i - 1]);
    }
    if (input.authorRow && card->author[0]) add(RowKind::Author, 0, false);
  } else {
    for (uint8_t i = 0; i < input.folderCount; ++i) add(RowKind::Folder, i, i == 0);
  }
  add(RowKind::Home, 0, false);
  return n;
}

int rowsHeight(const RowSpec* rows, const size_t count, const FitMetrics& metrics) {
  int height = 0;
  for (size_t i = 0; i < count; ++i) height += metrics.rowHeight + (rows[i].heading ? metrics.headingHeight : 0);
  return height;
}

namespace {
// The last row of this kind, or -1.
int lastOf(const RowSpec* rows, const size_t count, const RowKind kind) {
  for (size_t i = count; i-- > 0;) {
    if (rows[i].kind == kind) return static_cast<int>(i);
  }
  return -1;
}
}  // namespace

size_t fitRows(RowSpec* rows, size_t count, const FitMetrics& metrics) {
  static const RowKind DROP_ORDER[] = {RowKind::Suggestion, RowKind::Folder, RowKind::Author, RowKind::Rating};
  for (const RowKind kind : DROP_ORDER) {
    while (rowsHeight(rows, count, metrics) > metrics.available) {
      const int at = lastOf(rows, count, kind);
      if (at < 0) break;
      for (size_t i = static_cast<size_t>(at); i + 1 < count; ++i) rows[i] = rows[i + 1];
      --count;
    }
  }
  return count;
}

}  // namespace orbify
