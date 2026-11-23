#include <CrossInkTailnetCuts.h>

#include "EndPage.h"

#include <GfxRenderer.h>
#include <I18n.h>
#include <Logging.h>
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
#include <Bitmap.h>
#include <HalStorage.h>

#include "core/NextCover.h"
#endif

#include <cstdio>
#if CROSSINK_SCALABLE_FONTS
#include <ScalableBuiltins.h>
#endif

#include "BookOrbitDownloadIndex.h"
#include "FinishSync.h"
#include "activities/reader/BookReadingStats.h"
#include "fontIds.h"
#include "sync/BookSyncFile.h"

namespace {

using orbify::RowKind;
using orbify::SeriesCard;
namespace eob = orbify::eob;

const char* const DOT = " \xC2\xB7 ";  // " · "

std::string format(const char* pattern, const char* text) {
  char buf[160];
  snprintf(buf, sizeof(buf), pattern, text);
  return buf;
}

std::string bookLabel(const orbify::CardBook& book) {
  if (!book.index[0]) return book.title;
  return format(tr(STR_ORBIFY_BOOK_N), book.index) + DOT + book.title;  // "Book 3 · Title"
}

// The page's fonts by role: large serif title, the reader's large UI sizes for the rows.
struct FontRole {
  int id;
  EpdFontFamily::Style regular;
};
FontRole fontFor(const eob::Font font) {
  switch (font) {
    case eob::Font::Title:
      return {BITTER_16_FONT_ID, EpdFontFamily::BOLD};
    case eob::Font::Subtitle:
      return {BITTER_12_FONT_ID, EpdFontFamily::ITALIC};
    case eob::Font::Row:
      return {LEXENDDECA_12_FONT_ID, EpdFontFamily::REGULAR};
    case eob::Font::Small:
      return {LEXENDDECA_10_FONT_ID, EpdFontFamily::REGULAR};
    case eob::Font::Heading:
    default:
      return {LEXENDDECA_10_FONT_ID, EpdFontFamily::BOLD};
  }
}

EpdFontFamily::Style styleOf(const eob::Font font, const bool bold, const bool italic) {
  if (font == eob::Font::Title) return EpdFontFamily::BOLD;
  if (font == eob::Font::Subtitle) return EpdFontFamily::ITALIC;
  int style = EpdFontFamily::REGULAR;
  if (bold) style |= EpdFontFamily::BOLD;
  if (italic) style |= EpdFontFamily::ITALIC;
  return static_cast<EpdFontFamily::Style>(style);
}

int measure(void* ctx, const eob::Font font, const bool bold, const char* text) {
  const auto* renderer = static_cast<const GfxRenderer*>(ctx);
  return renderer->getTextWidth(fontFor(font).id, text, styleOf(font, bold, false));
}

eob::Metrics metricsFor(GfxRenderer& renderer) {
  eob::Metrics m;
  for (int f = 0; f < static_cast<int>(eob::Font::COUNT); ++f) {
    m.lineHeight[f] = renderer.getLineHeight(fontFor(static_cast<eob::Font>(f)).id);
  }
  m.textWidth = measure;
  m.ctx = &renderer;
  return m;
}

#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
// The next book's cover, fitted and centred in its box, framed as Home frames its covers. A file that
// went missing or does not parse leaves the box empty (the label already sits beside it).
void drawCover(GfxRenderer& renderer, const eob::Op& op) {
  HalFile file;
  if (!Storage.openFileForRead("ORB", op.text.c_str(), file)) return;
  Bitmap bitmap(file);
  if (bitmap.parseHeaders() == BmpReaderError::Ok && bitmap.getWidth() > 0 && bitmap.getHeight() > 0) {
    int w = op.w, h = op.h;
    if (bitmap.getWidth() * op.h > bitmap.getHeight() * op.w) {
      h = bitmap.getHeight() * op.w / bitmap.getWidth();
    } else {
      w = bitmap.getWidth() * op.h / bitmap.getHeight();
    }
    if (w > bitmap.getWidth() && h > bitmap.getHeight()) {
      w = bitmap.getWidth();  // never scaled up
      h = bitmap.getHeight();
    }
    const int x = op.x + (op.w - w) / 2, y = op.y + (op.h - h) / 2;
    renderer.fillRect(x, y, w, h, false);
    renderer.drawBitmap(bitmap, x, y, w, h);
    renderer.drawRect(x, y, w, h, !op.white);
  }
  file.close();
}
#endif

void drawOps(GfxRenderer& renderer, const eob::Layout& layout, const int dx, const int dy) {
  for (eob::Op op : layout.ops) {
    op.x += dx;
    op.y += dy;
    switch (op.kind) {
      case eob::Op::Kind::Text:
        renderer.drawText(fontFor(op.font).id, op.x, op.y, op.text.c_str(), !op.white,
                          styleOf(op.font, op.bold, op.italic));
        break;
      case eob::Op::Kind::FillRect:
        renderer.fillRect(op.x, op.y, op.w, op.h, !op.white);
        break;
      case eob::Op::Kind::Line:
        renderer.fillRectDither(op.x, op.y, op.w, op.h, Color::DarkGray);
        break;
      case eob::Op::Kind::Check: {
        int s[8];
        eob::checkStrokes(op.x, op.y, op.w, s);
        renderer.drawLine(s[0], s[1], s[2], s[3], 4, !op.white);
        renderer.drawLine(s[4], s[5], s[6], s[7], 4, !op.white);
        break;
      }
      case eob::Op::Kind::Image:
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
        drawCover(renderer, op);
#endif
        break;
      case eob::Op::Kind::Star: {
        int pts[20];
        eob::starPoints(op.x, op.y, op.w, pts);
        int xs[10], ys[10];
        for (int i = 0; i < 10; ++i) {
          xs[i] = pts[2 * i];
          ys[i] = pts[2 * i + 1];
        }
        renderer.fillPolygon(xs, ys, 10, !op.white);
        if (!op.filled) {
          // An empty star: the outline, 3 px thick.
          eob::starPoints(op.x, op.y, op.w - 4, pts);
          for (int i = 0; i < 10; ++i) {
            xs[i] = pts[2 * i];
            ys[i] = pts[2 * i + 1];
          }
          renderer.fillPolygon(xs, ys, 10, op.white);
        }
        break;
      }
    }
  }
}

}  // namespace

void OrbifyEndPage::load(const std::string& path, const BookInfo& info, const std::vector<std::string>& names,
                         const std::vector<std::string>& namePaths) {
  bookPath = path;
  book = info;
  folderNames = names;
  folderPaths = namePaths;
  const std::string cachePath = BookSyncFile::cachePathFor(bookPath);
  finished = !cachePath.empty() && BookReadingStats::load(cachePath).isCompleted;
  cardGeneration = OrbifyFinish::cardGeneration();
  hasCard = OrbifyFinish::loadCard(bookPath, card);
  authorName = hasCard && card.author[0] ? card.author : book.author;
  savedRating = shownRating = finished ? OrbifyFinish::rating(bookPath) : 0;
  sendState = finished ? OrbifyFinish::jobState(bookPath) : OrbifyFinish::JobState::None;
  // Which card books are on the device, looked up once (the index lives on the SD card).
  if (hasCard) {
    bookOnDevice(card.nextBook.id, nextPath);
    for (uint8_t k = 0; k < card.suggestionCount; ++k) bookOnDevice(card.suggestions[k].id, suggestionPaths[k]);
  }
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
  nextCover.clear();
  // The next book's cover, when a sync fetched and decoded it (FinishSync::fetchNextCover). The page
  // never fetches: without the file the row is drawn as without covers.
  const bool hasNext = hasCard && (card.next == SeriesCard::Next::Next || card.next == SeriesCard::Next::LastUnread);
  char cover[96];
  if (hasNext && card.nextBook.coverVer != 0 &&
      orbify::cover::bmpPath(orbify::cover::DIR, card.nextBook.id, card.nextBook.coverVer, eob::COVER_WIDTH,
                             eob::COVER_HEIGHT, cover, sizeof(cover)) &&
      Storage.exists(cover)) {
    nextCover = cover;
  }
  if (hasNext) LOG_INF("ORB", "End page: next book's cover %s", nextCover.empty() ? "none" : nextCover.c_str());
#endif
  build();
  LOG_INF("ORB", "End page: %s, card %s, series %s, %u rows", finished ? "finished" : "not finished",
          hasCard ? "yes" : "no", book.series.empty() ? "none" : "offline", static_cast<unsigned>(plannedCount));
}

bool OrbifyEndPage::reloadIfCardArrived() {
  if (hasCard || OrbifyFinish::cardGeneration() == cardGeneration) return false;
  // The arguments are this page's own copies: load() takes copies before it reassigns them.
  const std::string path = bookPath;
  const BookInfo info = book;
  const std::vector<std::string> names = folderNames;
  const std::vector<std::string> namePaths = folderPaths;
  load(path, info, names, namePaths);
  if (!hasCard) return false;
  LOG_INF("ORB", "End page: the series card arrived; drawn again");
  return true;
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
  input.offlineSeries = !book.series.empty();
  input.offlineAuthor = !book.author.empty();
  plannedCount = orbify::planRows(input, planned, orbify::MAX_ROWS);
  rowCount = plannedCount;
  for (size_t i = 0; i < rowCount; ++i) {
    rows[i] = planned[i];
    labelRow(i);
  }
  if (selection >= static_cast<int>(rowCount) || !rowEnabled(static_cast<size_t>(selection))) selection = 0;
}

bool OrbifyEndPage::rowEnabled(const size_t i) const {
  if (i >= rowCount || !orbify::selectable(rows[i].kind)) return false;
  return rows[i].kind != RowKind::Rating || finished;
}

void OrbifyEndPage::fit(const eob::Metrics& metrics, const int available, const bool touch) {
  const RowKind selectedKind = rows[selection].kind;
  const uint8_t selectedIndex = rows[selection].index;
  rowCount = plannedCount;
  for (size_t i = 0; i < rowCount; ++i) {
    rows[i] = planned[i];
    labelRow(i);
  }
  // Drop rows (core/EndPagePlan's order) until the tallest row shapes fit.
  eob::Row twoLine;
  twoLine.label = "A";
  twoLine.sub = "a";
  eob::Row heading = twoLine;
  heading.heading = "A";
  eob::Row rating;
  rating.role = eob::RowRole::Rating;
  rating.sub = "a";
  orbify::FitMetrics fm;
  fm.rowHeight = eob::rowHeight(twoLine, metrics, touch);
  fm.headingHeight = eob::rowHeight(heading, metrics, touch) - fm.rowHeight;
  fm.available = available;
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
  if (!nextCover.empty()) {
    // The Next row holds the cover: taller than the other rows (core/EndPagePlan counts it).
    eob::Row covered = twoLine;
    covered.image = nextCover;
    fm.nextRowHeight = eob::rowHeight(covered, metrics, touch);
  }
#endif
  for (size_t i = 0; i < rowCount; ++i) {
    if (rows[i].kind == RowKind::Rating) fm.available -= eob::rowHeight(rating, metrics, touch) - fm.rowHeight;
  }
  rowCount = orbify::fitRows(rows, rowCount, fm);
  selection = 0;
  for (size_t i = 0; i < rowCount; ++i) {
    labelRow(i);
    if (rows[i].kind == selectedKind && rows[i].index == selectedIndex) selection = static_cast<int>(i);
  }
  if (!rowEnabled(static_cast<size_t>(selection))) selection = 0;
}

bool OrbifyEndPage::bookOnDevice(const int64_t bookId, std::string& outPath) {
  outPath.clear();
  const bool found = bookId > 0 && BookOrbitDownloadIndex::lookup(bookId, outPath);
  BookOrbitDownloadIndex::unload();
  return found;
}

void OrbifyEndPage::labelRow(const size_t i) {
  const orbify::RowSpec& row = rows[i];
  eob::Row& out = shown[i];
  out = eob::Row{};
  paths[i].clear();
  switch (row.kind) {
    case RowKind::Status:
      out.role = eob::RowRole::Status;
      if (!finished) {
        out.label = tr(STR_ORBIFY_NOT_FINISHED);
        out.value = tr(STR_ORBIFY_MARK_FINISHED);
        break;
      }
      out.label = tr(STR_ORBIFY_FINISHED);
      out.check = true;
      if (sendState == OrbifyFinish::JobState::Pending) out.sub = tr(STR_ORBIFY_SENDS_NEXT_SYNC);
      if (sendState == OrbifyFinish::JobState::SignIn) out.sub = tr(STR_ORBIFY_SIGN_IN_TO_SEND);
      out.value = tr(STR_ORBIFY_UNDO);
      break;
    case RowKind::Rating:
      out.role = eob::RowRole::Rating;
      out.label = tr(STR_ORBIFY_YOUR_RATING);
      out.enabled = finished;
      if (!finished) {
        out.sub = tr(STR_ORBIFY_RATE_WHEN_FINISHED);
      } else if (shownRating != savedRating) {
        out.sub = tr(STR_ORBIFY_RATE_CONFIRM);
      } else {
        out.sub = tr(STR_ORBIFY_TAP_A_STAR);
      }
      break;
    case RowKind::Next:
      out.heading = card.next == SeriesCard::Next::LastUnread ? tr(STR_ORBIFY_LAST_UNREAD) : tr(STR_ORBIFY_NEXT_IN_SERIES);
      out.label = bookLabel(card.nextBook);
      if (card.nextRead) out.label += DOT + std::string(tr(STR_ORBIFY_READ));
      paths[i] = nextPath;
      out.sub = paths[i].empty() ? tr(STR_ORBIFY_ON_SERVER_DOWNLOAD) : tr(STR_ORBIFY_ON_READER_OPEN);
#if CROSSINK_TAILNET_ORBIFY_EOB_COVER
      out.image = nextCover;
#endif
      break;
    case RowKind::Info:
      out.role = eob::RowRole::Info;
      out.heading = tr(STR_ORBIFY_NEXT_IN_SERIES);
      out.enabled = false;
      if (row.index == 1) {
        // No card: the book after this one, from the series the EPUB names ("Book 3 of
        // Harbour Lights"; its title is the server's), and what it takes to see it.
        char next[8];
        orbify::nextSeriesIndex(book.seriesIndex.c_str(), next, sizeof(next));
        if (next[0]) {
          char label[192];
          snprintf(label, sizeof(label), tr(STR_ORBIFY_BOOK_N_OF), next, book.series.c_str());
          out.label = label;
        } else {
          out.label = book.series;
        }
        out.sub = tr(STR_ORBIFY_CONNECT_NEXT);
      } else if (card.next == SeriesCard::Next::Gap) {
        out.label = format(tr(STR_ORBIFY_GAP), std::to_string(card.missing).c_str());
      } else {
        out.label = tr(STR_ORBIFY_SERIES_DONE);
      }
      break;
    case RowKind::Suggestion: {
      const bool byAuthor = card.sources[row.index] == SeriesCard::Source::Author;
      if (row.heading) {
        out.heading = byAuthor && authorName[0] ? format(tr(STR_ORBIFY_ALSO_BY), authorName.c_str())
                                                : std::string(tr(STR_ORBIFY_YOU_MIGHT_LIKE));
      }
      out.label = card.suggestions[row.index].title;
      paths[i] = suggestionPaths[row.index];
      out.sub = paths[i].empty() ? tr(STR_ORBIFY_ON_SERVER_DOWNLOAD) : tr(STR_ORBIFY_ON_READER_OPEN);
      break;
    }
    case RowKind::Folder:
      if (row.heading) out.heading = tr(STR_EOB_CONTINUE_WITH);
      out.label = row.index < folderNames.size() ? folderNames[row.index] : "";
      out.sub = tr(STR_ORBIFY_ON_READER_OPEN);
      break;
    case RowKind::Author:
      out.label = format(tr(STR_ORBIFY_ALL_BY), authorName.c_str());
      out.value = "\xE2\x80\xBA";  // ›
      break;
    case RowKind::Home:
      out.role = eob::RowRole::Home;
      out.label = tr(STR_HOME);
      break;
  }
}

eob::Page OrbifyEndPage::page(const bool touch) const {
  eob::Page p;
  p.title = tr(STR_ORBIFY_THE_END);
  p.subtitle = book.title;
  if (!authorName.empty()) p.subtitle += (p.subtitle.empty() ? "" : DOT) + authorName;
  // "Book 2 of Harbour Lights": the server's series (the card), else the one the EPUB names.
  const char* seriesName = hasCard && card.seriesName[0] ? card.seriesName : book.series.c_str();
  const char* seriesIndex = hasCard && card.seriesName[0] ? card.seriesIndex : book.seriesIndex.c_str();
  if (seriesName[0] && seriesIndex[0]) {
    char line[192];
    snprintf(line, sizeof(line), tr(STR_ORBIFY_BOOK_N_OF), seriesIndex, seriesName);
    p.seriesLine = line;
  } else {
    p.seriesLine = seriesName;
  }
  p.touch = touch;
  p.rating = shownRating;
  p.selected = selection;
  for (size_t i = 0; i < rowCount; ++i) p.rows.push_back(shown[i]);
  return p;
}

void OrbifyEndPage::draw(GfxRenderer& renderer, const int x, const int y, const int width, const int height,
                         const bool touch) {
#if CROSSINK_SCALABLE_FONTS
  // The X4 Pro and X4 build their Bitter and Lexend Deca sizes from outlines, and only the reader's
  // chosen family is registered with the renderer: the other one's text was not drawn at all
  // ("GFX Font ... not found" on an X4 Pro reading in Bitter). The page uses both.
  ensureScalableBuiltinFamily(renderer, 0);  // Lexend Deca
  ensureScalableBuiltinFamily(renderer, 1);  // Bitter
#endif
  const eob::Metrics metrics = metricsFor(renderer);
  fit(metrics, height - eob::headerHeight(page(touch), metrics), touch);
  lastLayout = eob::layout(page(touch), metrics, width, height);
  originX = x;
  originY = y;
  drawOps(renderer, lastLayout, x, y);
}

OrbifyEndPage::Result OrbifyEndPage::tap(const int x, const int y) {
  const eob::Target* target = eob::hit(lastLayout, x - originX, y - originY);
  if (!target || target->row < 0 || static_cast<size_t>(target->row) >= rowCount) return Result{};
  const size_t i = static_cast<size_t>(target->row);
  selection = target->row;
  if (target->star > 0) {
    // A star rates at once (a second tap on the same star keeps it).
    shownRating = static_cast<int8_t>(target->star);
  } else if (rows[i].kind == RowKind::Rating) {
    return Result{};  // the row around the stars: nothing to do
  }
  LOG_INF("ORB", "End page: tap row %u (kind %u, star %d)", static_cast<unsigned>(i),
          static_cast<unsigned>(rows[i].kind), target->star);
  return act(i);
}

OrbifyEndPage::Result OrbifyEndPage::activate() {
  if (!rowEnabled(static_cast<size_t>(selection))) return Result{};
  return act(static_cast<size_t>(selection));
}

void OrbifyEndPage::move(const int direction) {
  if (rowCount == 0) return;
  int next = selection;
  for (size_t step = 0; step < rowCount; ++step) {
    next = (next + direction + static_cast<int>(rowCount)) % static_cast<int>(rowCount);
    if (rowEnabled(static_cast<size_t>(next))) break;
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
  if (!rowEnabled(static_cast<size_t>(selection)) || rows[selection].kind != RowKind::Rating) return false;
  const int next = shownRating + direction;
  shownRating = static_cast<int8_t>(next < 0 ? 5 : (next > 5 ? 0 : next));
  labelRow(static_cast<size_t>(selection));
  return true;
}

OrbifyEndPage::Result OrbifyEndPage::act(const size_t i) {
  Result result;
  if (!rowEnabled(i)) return result;
  const orbify::RowSpec& spec = rows[i];
  switch (spec.kind) {
    case RowKind::Status:
      result.act = Act::ToggleFinished;
      break;
    case RowKind::Rating:
      OrbifyFinish::setRating(bookPath, shownRating);
      savedRating = shownRating;
      sendState = OrbifyFinish::jobState(bookPath);
      for (size_t k = 0; k < rowCount; ++k) labelRow(k);
      result.act = Act::Redraw;
      break;
    case RowKind::Next:
    case RowKind::Suggestion: {
      const orbify::CardBook& target = spec.kind == RowKind::Next ? card.nextBook : card.suggestions[spec.index];
      if (!paths[i].empty()) {
        result.act = Act::OpenPath;
        result.path = paths[i];
      } else {
        result.act = Act::Catalog;
        result.link.bookId = target.id;
        result.link.title = target.title;
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
      result.link.author = authorName;
      break;
    case RowKind::Home:
      result.act = Act::Home;
      break;
    case RowKind::Info:
      break;
  }
  if (result.act != Act::None && result.act != Act::Redraw) {
    LOG_INF("ORB", "End page: row %u acts (%u)", static_cast<unsigned>(i), static_cast<unsigned>(result.act));
  }
  return result;
}
