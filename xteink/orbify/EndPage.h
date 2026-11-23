#pragma once
// Orbify: the End-of-Book page (docs/design/end-of-book/DESIGN.md §5, ROADMAP item 2), drawn by
// CrossInk's EndOfBookOptions (overlay patch 0028) in place of its folder suggestions:
//
//   Finished · sends at next sync      Undo
//   Rating                        ‹ 4 / 5 ›     (X4 only, once finished)
//   Next in series
//   Book 3 · The Wayfarer               Open / Download
//   Also by <author> / You might like
//   <title>                             Open / Download   (up to 2)
//   All books by <author>               ›
//   Home
//
// The next book and the suggestions come from the book's series card (FinishSync::loadCard);
// without one the page keeps upstream's folder suggestions under the status row. Rows that do
// not fit the panel go in core/EndPagePlan's order.
#include <FreeInkApp.h>

#include <cstdint>
#include <string>
#include <vector>

#include "activities/browser/BookOrbitCatalogLink.h"
#include "core/EndPagePlan.h"
#include "core/SeriesCard.h"
#include "FinishSync.h"

class OrbifyEndPage {
 public:
  enum class Act : uint8_t { None, Redraw, ToggleFinished, OpenPath, Catalog, Home };
  struct Result {
    Act act = Act::None;
    std::string path;          // OpenPath
    BookOrbitCatalogLink link;  // Catalog
  };

  // Reads the book's state and card. folderNames/folderPaths: upstream's folder suggestions.
  void load(const std::string& bookPath, const std::vector<std::string>& folderNames,
            const std::vector<std::string>& folderPaths);
  // The book was marked finished or unfinished from this page: status and rating rows again.
  void finishedChanged(bool finished);
  // Keeps the rows that fit; call before drawing (the orientation may have changed).
  void fit(const orbify::FitMetrics& metrics);

  uint16_t count() const { return static_cast<uint16_t>(rowCount); }
  const freeink::ui::ListItem* items() const { return listItems; }
  int selected() const { return selection; }
  const std::string& author() const { return authorName; }

  // Confirm on the selected row, or a tap on row `row` (which selects it first).
  Result activate(int row = -1);
  // Up/Down (-1/+1) move the selection over selectable rows, wrapping.
  void move(int direction);
  // Left/Right on the rating row change the rating Confirm saves. False elsewhere.
  bool adjust(int direction);

 private:
  void build();
  void labelRow(size_t i);
  static bool bookOnDevice(int64_t bookId, std::string& outPath);

  std::string bookPath;
  std::string authorName;
  bool finished = false;
  bool hasCard = false;
  orbify::SeriesCard card;
  int8_t savedRating = 0;
  int8_t shownRating = 0;
  OrbifyFinish::JobState sendState = OrbifyFinish::JobState::None;
  std::vector<std::string> folderNames;
  std::vector<std::string> folderPaths;
  std::string nextPath;  // on-device paths of the card's books, "" = download
  std::string suggestionPaths[orbify::SeriesCard::MAX_SUGGESTIONS];

  orbify::RowSpec planned[orbify::MAX_ROWS];
  size_t plannedCount = 0;
  orbify::RowSpec rows[orbify::MAX_ROWS];
  size_t rowCount = 0;
  int selection = 0;

  // Labels and values the ListItems point at; rebuilt with the rows.
  std::string labels[orbify::MAX_ROWS];
  std::string values[orbify::MAX_ROWS];
  std::string headings[orbify::MAX_ROWS];
  std::string paths[orbify::MAX_ROWS];  // on-device path of a card book row, "" = download
  freeink::ui::ListItem listItems[orbify::MAX_ROWS];
};
