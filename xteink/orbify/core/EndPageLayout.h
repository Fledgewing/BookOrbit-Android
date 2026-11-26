#pragma once
// BookSync End-of-Book page, the drawing (docs/design/end-of-book mockups 7 and 10): a full-screen
// page in large type. Pure C++: it turns the page's rows into draw operations and tap targets, so
// the firmware (../EndPage.cpp) draws them with GfxRenderer and the host harness
// (xteink/test/eob_render.cpp) draws the same operations to a PNG with the same fonts.
//
//                      The End                          title, large bold serif
//            The Lighthouse Keepers · Mara Quill        book · author, italic
//                Book 2 of Harbour Lights                its place in its series, small ("" = none)
//   ─────────────────────────────────────────────
//   ✓ Finished                                 Undo     status row
//     sends at next sync
//   Your rating      ★ ★ ★ ★ ☆                          five stars, each a tap target (X4 Pro)
//     tap a star                                         ◀ ▶ and Confirm on buttons
//   NEXT IN SERIES                                       section heading
//   ┌──┐ Book 3 · The Storm Signal                       rows: label, then a smaller line; the
//   └──┘ On BookOrbit · Download & open                  next book's cover at the left (X4)
//   ...
//   Home
//
// Rows keep their place: the rating row is there before the book is finished (dimmed), so a
// tap after Undo or Mark finished never lands on a row that moved under the finger.
#include <cstdint>
#include <string>
#include <vector>

namespace orbify::eob {

enum class Font : uint8_t { Title, Subtitle, Row, Small, Heading, COUNT };

// The built-in families the page's fonts come from, and each role's face: the device (EndPage.cpp)
// registers and picks its fonts from this table, the host render loads the same TTFs from it, so a
// role can't use a family the device never registered (rc3: every row blank on an X4 Pro reading
// in Bitter, its Lexend Deca never loaded).
enum class Family : uint8_t { LexendDeca, Bitter, COUNT };
struct FontSpec {
  Family family;
  int points;
  bool bold;
  bool italic;
};
FontSpec fontSpec(Font font);

// Fonts by role, measured on the device (GfxRenderer) or the host (FreeType, same TTFs and sizes).
struct Metrics {
  int lineHeight[static_cast<int>(Font::COUNT)] = {};
  int (*textWidth)(void* ctx, Font font, bool bold, const char* text) = nullptr;
  void* ctx = nullptr;
};

enum class RowRole : uint8_t { Plain, Status, Rating, Info, Home };

struct Row {
  RowRole role = RowRole::Plain;
  std::string heading;  // drawn above the row ("Next in series"); "" = none
  std::string label;
  std::string sub;      // the smaller second line; "" = none
  std::string value;    // right-aligned action ("Undo", "Open", "›"); "" = none
  bool enabled = true;  // false: drawn grey, never selected or tapped
  bool check = false;   // a check mark before the label (drawn, not a glyph: the fonts lack ✓)
  std::string image;    // a cover BMP drawn at the left, COVER_WIDTH x COVER_HEIGHT; the row grows
                        // to hold it and its text moves right. "" = none: the row as without covers
};

struct Page {
  std::string title;     // "The End"
  std::string subtitle;  // "<book> · <author>"
  std::string seriesLine;  // "Book 2 of Harbour Lights" (mockup 7's series line); "" = none
  std::vector<Row> rows;
  int rating = 0;        // stars shown, 0..5
  bool touch = false;    // X4 Pro: larger rows and star targets
  int selected = -1;     // highlighted row (buttons), -1 = none
};

struct Op {
  enum class Kind : uint8_t { Text, FillRect, Line, Star, Check, Image };
  Kind kind = Kind::Text;
  Font font = Font::Row;
  bool bold = false;
  bool italic = false;
  bool white = false;  // text or fill in white (on the selected row's black band)
  bool grey = false;   // dimmed text (a disabled row)
  int x = 0, y = 0, w = 0, h = 0;  // Text: x,y = top-left; Star: centre x,y and outer radius w;
                                   // Check, Image: the w x h box it sits in
  bool filled = false;             // Star
  std::string text;                // Text: the text; Image: the BMP's path
};

struct Target {
  int x = 0, y = 0, w = 0, h = 0;
  int row = -1;  // index into Page::rows
  int star = 0;  // 1..5 on the rating row's stars, 0 elsewhere
};

struct Layout {
  std::vector<Op> ops;
  std::vector<Target> targets;
  int bottom = 0;  // y below the last row
};

// Geometry, in pixels. touch rows are at least MIN_TOUCH_ROW tall (44 px is the floor).
constexpr int MARGIN = 16;
constexpr int ROW_PAD = 9;
constexpr int MIN_TOUCH_ROW = 64;
constexpr int STAR_RADIUS = 21;  // a 42 px star; its target is the 52 px cell around it
constexpr int STAR_CELL = 52;
// The next book's cover (2:3, Home's shape), with COVER_PAD above and below it in its row.
constexpr int COVER_WIDTH = 60;
constexpr int COVER_HEIGHT = 90;
constexpr int COVER_PAD = 8;
constexpr int COVER_GAP = 14;  // between the cover and the label

// The height one row takes (heading included), so the caller can drop rows that do not fit.
int rowHeight(const Row& row, const Metrics& m, bool touch);
int headerHeight(const Page& page, const Metrics& m);

// Lays the page out in a width x height area (the hints band already taken off the height).
// Rows that do not fit are left out from the end; the caller drops rows before that (fitRows).
Layout layout(const Page& page, const Metrics& m, int width, int height);

// The target under (x, y), or nullptr.
const Target* hit(const Layout& layout, int x, int y);

// The text cut to maxWidth with "…" (UTF-8 aware).
std::string ellipsize(const Metrics& m, Font font, bool bold, const std::string& text, int maxWidth);

// The ten corner points of a five-pointed star, for fillPolygon (x0, y0, x1, y1, ...).
void starPoints(int cx, int cy, int radius, int out[20]);

// A check mark in a size x size box at (x, y): two strokes, as line segments (x1,y1,x2,y2 each).
void checkStrokes(int x, int y, int size, int out[8]);

}  // namespace orbify::eob
