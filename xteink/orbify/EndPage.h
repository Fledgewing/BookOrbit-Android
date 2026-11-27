#pragma once
// BookSync: the End-of-Book page (docs/design/end-of-book/DESIGN.md §5, mockups 7 and 10; ROADMAP
// item 2). CrossInk's EndOfBookOptions (overlay patches 0028, 0032) hands it the whole screen:
//
//                         The End
//              <book title> · <author>
//   ✓ Finished · sends at next sync                Undo
//   Your rating                           ★ ★ ★ ★ ☆     (X4: stars; tap one on the X4 Pro)
//   NEXT IN SERIES
//   ┌──┐ Book 3 · The Wayfarer                    Open / Download
//   └──┘   On this reader · Open / On BookOrbit · Download & open
//        (the cover: X4 Pro and X4, once a sync fetched it; without it the row is as before)
//   ALSO BY <author> / YOU MIGHT LIKE                 (up to 2)
//   All books by <author>                              ›
//   Home
//
// The next book and the suggestions come from the book's series card (FinishSync::loadCard).
// Without one (offline, nothing fetched yet), the EPUB's own series and author fill those rows
// with "Connect to see what's next", and upstream's folder suggestions follow. Rows that do not
// fit go in core/EndPagePlan's order; core/EndPageLayout draws them.
#include <cstdint>
#include <string>
#include <vector>

#include "activities/browser/bookorbit/BookOrbitCatalogLink.h"
#include "core/EndPageLayout.h"
#include "core/EndPagePlan.h"
#include "core/SeriesCard.h"
#include "FinishSync.h"

class GfxRenderer;

class OrbifyEndPage {
 public:
  enum class Act : uint8_t { None, Redraw, ToggleFinished, OpenPath, Catalog, Home };
  struct Result {
    Act act = Act::None;
    std::string path;          // OpenPath
    BookOrbitCatalogLink link;  // Catalog
  };

  // What the book itself says (its EPUB metadata); any of them may be empty.
  struct BookInfo {
    std::string title, author, series, seriesIndex;
  };

  // Reads the book's state and card. folderNames/folderPaths: upstream's folder suggestions.
  void load(const std::string& bookPath, const BookInfo& info, const std::vector<std::string>& folderNames,
            const std::vector<std::string>& folderPaths);
  // The book was marked finished or unfinished from this page: status and rating rows again.
  void finishedChanged(bool finished);
  // A sync wrote a series card since load() (FinishSync::cardGeneration) while the page had none:
  // reads the book's state and card again. True when the page must be drawn again.
  bool reloadIfCardArrived();

  // Lays the page out in this area of the screen (the safe area, hints excluded; the
  // orientation may have changed since the last draw) and draws it.
  void draw(GfxRenderer& renderer, int x, int y, int width, int height, bool touch);

  int selected() const { return selection; }

  // A tap at (x, y), in the coordinates draw() used: a star rates, a row acts. Taps outside
  // every target do nothing.
  Result tap(int x, int y);
  // Confirm on the selected row.
  Result activate();
  // Up/Down (-1/+1) move the selection over selectable rows, wrapping.
  void move(int direction);
  // Left/Right on the rating row change the rating Confirm saves. False elsewhere.
  bool adjust(int direction);

 private:
  void build();
  void fit(const orbify::eob::Metrics& metrics, int available, bool touch);
  void labelRow(size_t i);
  orbify::eob::Page page(bool touch) const;
  Result act(size_t row);
  static bool bookOnDevice(int64_t bookId, std::string& outPath);
  bool rowEnabled(size_t i) const;

  std::string bookPath;
  BookInfo book;
  std::string authorName;  // the card's, else the EPUB's
  bool finished = false;
  bool hasCard = false;
  uint32_t cardGeneration = 0;  // FinishSync::cardGeneration() at load()
  orbify::SeriesCard card;
  int8_t savedRating = 0;
  int8_t shownRating = 0;
  OrbifyFinish::JobState sendState = OrbifyFinish::JobState::None;
  std::vector<std::string> folderNames;
  std::vector<std::string> folderPaths;
  std::string nextPath;  // on-device paths of the card's books, "" = download
  std::string nextCover;  // the next book's cover BMP (FinishSync::fetchNextCover), "" = none
  std::string suggestionPaths[orbify::SeriesCard::MAX_SUGGESTIONS];

  orbify::RowSpec planned[orbify::MAX_ROWS];
  size_t plannedCount = 0;
  orbify::RowSpec rows[orbify::MAX_ROWS];
  size_t rowCount = 0;
  int selection = 0;
  orbify::eob::Row shown[orbify::MAX_ROWS];
  std::string paths[orbify::MAX_ROWS];  // on-device path of a card book row, "" = download
  orbify::eob::Layout lastLayout;       // the targets of the last draw()
  int originX = 0, originY = 0;         // where the last draw() put the layout's (0, 0)
};
