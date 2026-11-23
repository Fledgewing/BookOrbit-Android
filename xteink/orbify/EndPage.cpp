#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_FINISH
#include "EndPage.h"

#include <I18n.h>
#include <Logging.h>

#include <cstdio>

#include "BookOrbitCredentialStore.h"
#include "BookOrbitDownloadIndex.h"
#include "FinishSync.h"
#include "activities/reader/BookReadingStats.h"
#include "sync/BookSyncFile.h"

namespace {

using orbify::RowKind;
using orbify::SeriesCard;

std::string format(const char* pattern, const char* text) {
  char buf[160];
  snprintf(buf, sizeof(buf), pattern, text);
  return buf;
}

std::string bookLabel(const orbify::CardBook& book) {
  if (!book.index[0]) return book.title;
  return format(tr(STR_ORBIFY_BOOK_N), book.index) + " \xC2\xB7 " + book.title;  // "Book 3 · Title"
}

}  // namespace

void OrbifyEndPage::load(const std::string& path, const std::vector<std::string>& names,
                         const std::vector<std::string>& namePaths) {
  bookPath = path;
  folderNames = names;
  folderPaths = namePaths;
  const std::string cachePath = BookSyncFile::cachePathFor(bookPath);
  finished = !cachePath.empty() && BookReadingStats::load(cachePath).isCompleted;
  hasCard = OrbifyFinish::loadCard(bookPath, card);
  authorName = hasCard ? card.author : "";
  savedRating = shownRating = finished ? OrbifyFinish::rating(bookPath) : 0;
  sendState = finished ? OrbifyFinish::jobState(bookPath) : OrbifyFinish::JobState::None;
  // Which card books are on the device, looked up once (the index lives on the SD card).
  if (hasCard) {
    bookOnDevice(card.nextBook.id, nextPath);
    for (uint8_t k = 0; k < card.suggestionCount; ++k) bookOnDevice(card.suggestions[k].id, suggestionPaths[k]);
  }
  build();
  LOG_INF("ORB", "End page: %s, card %s, %u rows", finished ? "finished" : "not finished", hasCard ? "yes" : "no",
          static_cast<unsigned>(plannedCount));
}

void OrbifyEndPage::finishedChanged(const bool isFinished) {
  finished = isFinished;
  savedRating = shownRating = finished ? OrbifyFinish::rating(bookPath) : 0;
  sendState = finished ? OrbifyFinish::jobState(bookPath) : OrbifyFinish::JobState::None;
  build();
}

void OrbifyEndPage::build() {
  orbify::PlanInput input;
  input.finished = finished;
  input.ratings = CROSSINK_TAILNET_ORBIFY_RATING != 0;
  input.card = hasCard ? &card : nullptr;
  input.folderCount = static_cast<uint8_t>(folderNames.size() < 3 ? folderNames.size() : 3);
  input.maxSuggestions = CROSSINK_TAILNET_ORBIFY_SUGGESTIONS;
  input.authorRow = CROSSINK_TAILNET_ORBIFY_AUTHOR_ROW != 0;
  plannedCount = orbify::planRows(input, planned, orbify::MAX_ROWS);
  rowCount = plannedCount;
  for (size_t i = 0; i < rowCount; ++i) {
    rows[i] = planned[i];
    labelRow(i);
  }
  if (selection >= static_cast<int>(rowCount) || !orbify::selectable(rows[selection].kind)) selection = 0;
}

void OrbifyEndPage::fit(const orbify::FitMetrics& metrics) {
  const RowKind selectedKind = rows[selection].kind;
  const uint8_t selectedIndex = rows[selection].index;
  rowCount = plannedCount;
  for (size_t i = 0; i < rowCount; ++i) rows[i] = planned[i];
  rowCount = orbify::fitRows(rows, rowCount, metrics);
  selection = 0;
  for (size_t i = 0; i < rowCount; ++i) {
    labelRow(i);
    if (rows[i].kind == selectedKind && rows[i].index == selectedIndex) selection = static_cast<int>(i);
  }
}

bool OrbifyEndPage::bookOnDevice(const int64_t bookId, std::string& outPath) {
  outPath.clear();
  const bool found = bookId > 0 && BookOrbitDownloadIndex::lookup(bookId, outPath);
  BookOrbitDownloadIndex::unload();
  return found;
}

void OrbifyEndPage::labelRow(const size_t i) {
  const orbify::RowSpec& row = rows[i];
  std::string& label = labels[i];
  std::string& value = values[i];
  std::string& heading = headings[i];
  label.clear();
  value.clear();
  heading.clear();
  paths[i].clear();
  switch (row.kind) {
    case RowKind::Status: {
      if (!finished) {
        label = tr(STR_ORBIFY_NOT_FINISHED);
        value = tr(STR_ORBIFY_MARK_FINISHED);
        break;
      }
      label = tr(STR_ORBIFY_FINISHED);
      switch (sendState) {
        case OrbifyFinish::JobState::Pending:
          label += std::string(" \xC2\xB7 ") + tr(STR_ORBIFY_SENDS_NEXT_SYNC);
          break;
        case OrbifyFinish::JobState::SignIn:
          label += std::string(" \xC2\xB7 ") + tr(STR_ORBIFY_SIGN_IN_TO_SEND);
          break;
        default:
          break;
      }
      value = tr(STR_ORBIFY_UNDO);
      break;
    }
    case RowKind::Rating: {
      label = tr(STR_ORBIFY_RATING);
      char stars[32];
      if (shownRating > 0) {
        snprintf(stars, sizeof(stars), "\xE2\x80\xB9 %d / 5 \xE2\x80\xBA", shownRating);  // ‹ 4 / 5 ›
      } else {
        snprintf(stars, sizeof(stars), "\xE2\x80\xB9 %s \xE2\x80\xBA", tr(STR_ORBIFY_NO_RATING));
      }
      value = stars;
      if (shownRating != savedRating) value += "  " + std::string(tr(STR_ORBIFY_SAVE));
      break;
    }
    case RowKind::Next: {
      heading = card.next == SeriesCard::Next::LastUnread ? tr(STR_ORBIFY_LAST_UNREAD) : tr(STR_ORBIFY_NEXT_IN_SERIES);
      label = bookLabel(card.nextBook);
      if (card.nextRead) label += std::string(" \xC2\xB7 ") + tr(STR_ORBIFY_READ);
      paths[i] = nextPath;
      value = paths[i].empty() ? tr(STR_DOWNLOAD) : tr(STR_OPEN);
      break;
    }
    case RowKind::Info: {
      heading = tr(STR_ORBIFY_NEXT_IN_SERIES);
      if (card.next == SeriesCard::Next::Gap) {
        label = format(tr(STR_ORBIFY_GAP), std::to_string(card.missing).c_str());
      } else {
        label = tr(STR_ORBIFY_SERIES_DONE);
      }
      break;
    }
    case RowKind::Suggestion: {
      const bool byAuthor = card.sources[row.index] == SeriesCard::Source::Author;
      if (row.heading) heading = byAuthor && card.author[0] ? format(tr(STR_ORBIFY_ALSO_BY), card.author) : tr(STR_ORBIFY_YOU_MIGHT_LIKE);
      label = card.suggestions[row.index].title;
      paths[i] = suggestionPaths[row.index];
      value = paths[i].empty() ? tr(STR_DOWNLOAD) : tr(STR_OPEN);
      break;
    }
    case RowKind::Folder: {
      if (row.heading) heading = tr(STR_EOB_CONTINUE_WITH);
      label = row.index < folderNames.size() ? folderNames[row.index] : "";
      break;
    }
    case RowKind::Author:
      label = format(tr(STR_ORBIFY_ALL_BY), card.author);
      value = "\xE2\x80\xBA";  // ›
      break;
    case RowKind::Home:
      label = tr(STR_HOME);
      break;
  }
  freeink::ui::ListItem& item = listItems[i];
  item = freeink::ui::ListItem{};
  item.label = label.c_str();
  item.value = value.empty() ? nullptr : value.c_str();
  item.sectionHeading = heading.empty() ? nullptr : heading.c_str();
  item.enabled = orbify::selectable(row.kind);
  item.actionValue = static_cast<int16_t>(i);
}

void OrbifyEndPage::move(const int direction) {
  if (rowCount == 0) return;
  int next = selection;
  for (size_t step = 0; step < rowCount; ++step) {
    next = (next + direction + static_cast<int>(rowCount)) % static_cast<int>(rowCount);
    if (orbify::selectable(rows[next].kind)) break;
  }
  selection = next;
  // Leaving the rating row without Confirm drops the unsaved change.
  if (shownRating != savedRating) {
    shownRating = savedRating;
    for (size_t i = 0; i < rowCount; ++i) {
      if (rows[i].kind == RowKind::Rating) labelRow(i);
    }
  }
}

bool OrbifyEndPage::adjust(const int direction) {
  if (selection >= static_cast<int>(rowCount) || rows[selection].kind != RowKind::Rating) return false;
  const int next = shownRating + direction;
  shownRating = static_cast<int8_t>(next < 0 ? 5 : (next > 5 ? 0 : next));
  labelRow(static_cast<size_t>(selection));
  return true;
}

OrbifyEndPage::Result OrbifyEndPage::activate(const int row) {
  Result result;
  if (row >= 0) {
    if (row >= static_cast<int>(rowCount) || !orbify::selectable(rows[row].kind)) return result;
    // A tap on the rating row steps the rating and saves it (X4 Pro touch).
    if (rows[row].kind == RowKind::Rating) {
      selection = row;
      adjust(+1);
    }
    selection = row;
  }
  const size_t i = static_cast<size_t>(selection);
  if (i >= rowCount) return result;
  const orbify::RowSpec& spec = rows[i];
  switch (spec.kind) {
    case RowKind::Status:
      result.act = Act::ToggleFinished;
      break;
    case RowKind::Rating:
      OrbifyFinish::setRating(bookPath, shownRating);
      savedRating = shownRating;
      sendState = OrbifyFinish::jobState(bookPath);
      for (size_t k = 0; k < rowCount; ++k) {
        if (rows[k].kind == RowKind::Status) labelRow(k);
      }
      labelRow(i);
      result.act = Act::Redraw;
      break;
    case RowKind::Next:
    case RowKind::Suggestion: {
      const orbify::CardBook& book = spec.kind == RowKind::Next ? card.nextBook : card.suggestions[spec.index];
      if (!paths[i].empty()) {
        result.act = Act::OpenPath;
        result.path = paths[i];
      } else {
        result.act = Act::Catalog;
        result.link.bookId = book.id;
        result.link.title = book.title;
        result.link.returnPath = bookPath;
      }
      break;
    }
    case RowKind::Folder:
      if (spec.index < folderPaths.size()) {
        result.act = Act::OpenPath;
        result.path = folderPaths[spec.index];
      }
      break;
    case RowKind::Author:
      result.act = Act::Catalog;
      result.link.author = card.author;
      break;
    case RowKind::Home:
      result.act = Act::Home;
      break;
    case RowKind::Info:
      break;
  }
  return result;
}

#endif
