// Host render of the End-of-Book page (xteink/orbify/core/EndPageLayout): the same layout and draw
// operations the firmware runs, drawn with FreeType from the TTFs CrossInk's built-in fonts are
// made from, at the same sizes (pt at 150 DPI), to PNGs for review against the mockups. It also
// checks the touch rules on every screen it draws.
//
//   eob_render <crossink checkout> <out dir>
//
// Font roles as on the device (orbify/EndPage.cpp): title Bitter 16 bold, subtitle Bitter 12
// italic, rows Lexend Deca 12, small lines Lexend Deca 10, headings Lexend Deca 10 bold.
#include <ft2build.h>
#include FT_FREETYPE_H
#include <png.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "EndPageLayout.h"

using namespace orbify::eob;

namespace {

int failed = 0, passed = 0;
#define CHECK(c, what)                                         \
  do {                                                         \
    if (c) {                                                   \
      ++passed;                                                \
    } else {                                                   \
      ++failed;                                                \
      std::printf("FAIL %s: %s\n", what, #c);                  \
    }                                                          \
  } while (0)

FT_Library ft;
struct Face {
  FT_Face regular = nullptr, bold = nullptr, italic = nullptr;
  int ppem = 0;
};
Face faces[static_cast<int>(Font::COUNT)];

FT_Face load(const std::string& path, int ppem) {
  FT_Face f = nullptr;
  if (FT_New_Face(ft, path.c_str(), 0, &f)) {
    std::fprintf(stderr, "cannot load %s\n", path.c_str());
    std::exit(2);
  }
  FT_Set_Pixel_Sizes(f, 0, ppem);
  return f;
}

int ppem(int pt) { return static_cast<int>(std::lround(pt * 150.0 / 72.0)); }

FT_Face faceFor(Font font, bool bold, bool italic) {
  const Face& f = faces[static_cast<int>(font)];
  if (italic && f.italic) return f.italic;
  if (bold && f.bold) return f.bold;
  return f.regular;
}

// UTF-8 to code points.
std::vector<uint32_t> decode(const std::string& s) {
  std::vector<uint32_t> out;
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = s[i];
    uint32_t cp = c;
    int n = 0;
    if (c >= 0xF0) cp = c & 0x07, n = 3;
    else if (c >= 0xE0) cp = c & 0x0F, n = 2;
    else if (c >= 0xC0) cp = c & 0x1F, n = 1;
    for (int k = 1; k <= n && i + k < s.size(); ++k) cp = (cp << 6) | (s[i + k] & 0x3F);
    out.push_back(cp);
    i += n + 1;
  }
  return out;
}

int textWidth(void*, Font font, bool bold, const char* text) {
  FT_Face f = faceFor(font, bold, false);
  int w = 0;
  for (uint32_t cp : decode(text)) {
    if (FT_Load_Char(f, cp, FT_LOAD_DEFAULT)) continue;
    w += f->glyph->advance.x >> 6;
  }
  return w;
}

struct Canvas {
  int w, h;
  std::vector<uint8_t> px;  // 255 white
  Canvas(int w_, int h_) : w(w_), h(h_), px(static_cast<size_t>(w_ * h_), 255) {}
  void set(int x, int y, uint8_t v) {
    if (x >= 0 && y >= 0 && x < w && y < h) px[static_cast<size_t>(y * w + x)] = v;
  }
  void fill(int x, int y, int ww, int hh, uint8_t v) {
    for (int j = y; j < y + hh; ++j)
      for (int i = x; i < x + ww; ++i) set(i, j, v);
  }
  void text(Font font, bool bold, bool italic, int x, int y, const std::string& s, bool white) {
    FT_Face f = faceFor(font, bold, italic);
    const int ascender = f->size->metrics.ascender >> 6;
    int pen = x;
    for (uint32_t cp : decode(s)) {
      if (FT_Load_Char(f, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_MONO)) continue;
      const FT_Bitmap& b = f->glyph->bitmap;
      for (unsigned r = 0; r < b.rows; ++r)
        for (unsigned c = 0; c < b.width; ++c) {
          const bool on = (b.buffer[r * b.pitch + (c >> 3)] >> (7 - (c & 7))) & 1;
          if (on) set(pen + f->glyph->bitmap_left + static_cast<int>(c), y + ascender - f->glyph->bitmap_top + static_cast<int>(r),
                      white ? 255 : 0);
        }
      pen += f->glyph->advance.x >> 6;
    }
  }
  // A thick line, as GfxRenderer::drawLine(x1, y1, x2, y2, lineWidth, state).
  void line(int x1, int y1, int x2, int y2, int width, uint8_t v) {
    const int steps = std::max(std::abs(x2 - x1), std::abs(y2 - y1));
    for (int i = 0; i <= steps; ++i) {
      const int x = x1 + (steps ? (x2 - x1) * i / steps : 0), y = y1 + (steps ? (y2 - y1) * i / steps : 0);
      fill(x - width / 2, y - width / 2, width, width, v);
    }
  }
  // Even-odd scanline fill, as GfxRenderer::fillPolygon.
  void polygon(const int* pts, int n, uint8_t v) {
    int minY = pts[1], maxY = pts[1];
    for (int i = 0; i < n; ++i) minY = std::min(minY, pts[2 * i + 1]), maxY = std::max(maxY, pts[2 * i + 1]);
    for (int y = minY; y <= maxY; ++y) {
      std::vector<int> xs;
      for (int i = 0; i < n; ++i) {
        const int x1 = pts[2 * i], y1 = pts[2 * i + 1], x2 = pts[2 * ((i + 1) % n)], y2 = pts[2 * ((i + 1) % n) + 1];
        if ((y1 <= y && y2 > y) || (y2 <= y && y1 > y)) xs.push_back(x1 + (y - y1) * (x2 - x1) / (y2 - y1));
      }
      std::sort(xs.begin(), xs.end());
      for (size_t k = 0; k + 1 < xs.size(); k += 2)
        for (int x = xs[k]; x <= xs[k + 1]; ++x) set(x, y, v);
    }
  }
  void png(const std::string& path) const {
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) return;
    png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png_create_info_struct(p);
    png_init_io(p, fp);
    png_set_IHDR(p, info, w, h, 8, PNG_COLOR_TYPE_GRAY, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
                 PNG_FILTER_TYPE_DEFAULT);
    png_write_info(p, info);
    for (int y = 0; y < h; ++y) png_write_row(p, const_cast<uint8_t*>(&px[static_cast<size_t>(y * w)]));
    png_write_end(p, nullptr);
    png_destroy_write_struct(&p, &info);
    std::fclose(fp);
  }
};

Metrics metrics() {
  Metrics m;
  for (int f = 0; f < static_cast<int>(Font::COUNT); ++f) m.lineHeight[f] = faces[f].regular->size->metrics.height >> 6;
  m.textWidth = textWidth;
  return m;
}

// A stand-in for the decoded cover BMP (1-bit, dithered, as JpegToBmpConverter writes it): a dithered
// sky over a dark sea, a lighthouse, the book number; framed as orbify/EndPage.cpp frames it.
void cover(Canvas& cv, const Op& op) {
  static const int BAYER[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};
  const int horizon = op.h * 3 / 5;
  for (int j = 0; j < op.h; ++j) {
    for (int i = 0; i < op.w; ++i) {
      const int tone = j < horizon ? 2 + 8 * j / horizon : 12;  // 0 white .. 16 black
      // A lighthouse: a tapered tower standing on the horizon, its lamp lit.
      const int half = 3 + (j - op.h / 4) / 8;
      const bool tower = j >= op.h / 4 && j < horizon && std::abs(i - op.w / 3) <= half;
      const bool lamp = j >= op.h / 4 - 7 && j < op.h / 4 - 1 && std::abs(i - op.w / 3) <= 2;
      const bool on = lamp ? false : tower || BAYER[j % 4][i % 4] < tone;
      cv.set(op.x + i, op.y + j, on ? 0 : 255);
    }
  }
  const std::string n = "3";
  const int tw = textWidth(nullptr, Font::Title, true, n.c_str());
  cv.fill(op.x + (op.w - tw) / 2 - 4, op.y + op.h - 44, tw + 8, 38, 255);
  cv.text(Font::Title, true, false, op.x + (op.w - tw) / 2, op.y + op.h - 46, n, false);
  const uint8_t frame = op.white ? 255 : 0;
  cv.fill(op.x, op.y, op.w, 1, frame);
  cv.fill(op.x, op.y + op.h - 1, op.w, 1, frame);
  cv.fill(op.x, op.y, 1, op.h, frame);
  cv.fill(op.x + op.w - 1, op.y, 1, op.h, frame);
}

void draw(Canvas& cv, const Layout& layout) {
  for (const Op& op : layout.ops) {
    switch (op.kind) {
      case Op::Kind::Text:
        cv.text(op.font, op.bold, op.italic, op.x, op.y, op.text, op.white);
        break;
      case Op::Kind::FillRect:
        cv.fill(op.x, op.y, op.w, op.h, op.white ? 255 : 0);
        break;
      case Op::Kind::Line:
        // GfxRenderer's DarkGray dither: every other pixel.
        for (int i = op.x; i < op.x + op.w; ++i)
          if (i % 2 == 0) cv.set(i, op.y, 0);
        break;
      case Op::Kind::Check: {
        int s[8];
        checkStrokes(op.x, op.y, op.w, s);
        for (int k = 0; k < 2; ++k) cv.line(s[4 * k], s[4 * k + 1], s[4 * k + 2], s[4 * k + 3], 4, op.white ? 255 : 0);
        break;
      }
      case Op::Kind::Image:
        cover(cv, op);
        break;
      case Op::Kind::Star: {
        int pts[20];
        starPoints(op.x, op.y, op.w, pts);
        cv.polygon(pts, 10, op.white ? 255 : 0);
        if (!op.filled) {
          starPoints(op.x, op.y, op.w - 4, pts);
          cv.polygon(pts, 10, op.white ? 0 : 255);
        }
        break;
      }
    }
  }
}

// The button hints band (BaseTheme: 40 px, four labels).
void hints(Canvas& cv, const char* const labels[4]) {
  const int y = cv.h - 40, w = cv.w / 4;
  for (int i = 0; i < 4; ++i) {
    cv.fill(i * w + 6, y + 4, w - 12, 1, 0);
    cv.fill(i * w + 6, y + 4, 1, 32, 0);
    cv.fill(i * w + w - 7, y + 4, 1, 32, 0);
    const int tw = textWidth(nullptr, Font::Heading, false, labels[i]);
    cv.text(Font::Heading, false, false, i * w + (w - tw) / 2, y + 10, labels[i], false);
  }
}

void touchRules(const Layout& layout, const Page& page, int height, const char* name) {
  // Every target is at least 44 px tall and inside the page; targets of different rows never overlap.
  for (const Target& t : layout.targets) {
    CHECK(t.h >= 44, name);
    CHECK(t.y >= 0 && t.y + t.h <= height, name);
    for (const Target& u : layout.targets) {
      if (&t == &u || t.row == u.row) continue;
      const bool overlap = t.x < u.x + u.w && u.x < t.x + t.w && t.y < u.y + u.h && u.y < t.y + t.h;
      CHECK(!overlap, name);
    }
  }
  // Each star has its own target, 52 px wide.
  int stars = 0;
  for (const Target& t : layout.targets) stars += t.star > 0 ? 1 : 0;
  bool rated = false;
  for (const Row& r : page.rows) rated = rated || (r.role == RowRole::Rating && r.enabled);
  CHECK(stars == (rated ? 5 : 0), name);
}

struct Scene {
  const char* file;
  Page page;
};

Row row(RowRole role, std::string label, std::string sub = "", std::string value = "", std::string heading = "",
        bool enabled = true) {
  Row r;
  r.role = role;
  r.label = std::move(label);
  r.sub = std::move(sub);
  r.value = std::move(value);
  r.heading = std::move(heading);
  r.enabled = enabled;
  return r;
}

// Every row says what it is, selected or not: each row with a label has text that is not empty
// and inks pixels against what is under it (no black on the selected row's black band, no text
// lost). Drawn twice per row: once without its text, once with.
void visibleText(Page page, const Metrics& m, const char* name) {
  for (size_t sel = 0; sel < page.rows.size(); ++sel) {
    page.selected = static_cast<int>(sel);
    const Layout layout = orbify::eob::layout(page, m, 480, 760);
    Layout bare = layout;
    bare.ops.clear();
    for (const Op& op : layout.ops)
      if (op.kind != Op::Kind::Text) bare.ops.push_back(op);
    Canvas under(480, 760), full(480, 760);
    draw(under, bare);
    draw(full, layout);
    for (const Target& t : layout.targets) {
      if (t.star > 0 || t.row < 0 || static_cast<size_t>(t.row) >= page.rows.size()) continue;
      if (page.rows[static_cast<size_t>(t.row)].label.empty()) continue;
      int texts = 0, inked = 0;
      for (const Op& op : layout.ops) {
        if (op.kind != Op::Kind::Text || op.y < t.y || op.y >= t.y + t.h) continue;
        ++texts;
        CHECK(!op.text.empty(), name);
        const int w = textWidth(nullptr, op.font, op.bold, op.text.c_str());
        const int h = m.lineHeight[static_cast<int>(op.font)];
        int ink = 0;
        for (int y = op.y; y < op.y + h && y < 760; ++y)
          for (int x = op.x; x < op.x + w && x < 480; ++x)
            ink += full.px[static_cast<size_t>(y * 480 + x)] != under.px[static_cast<size_t>(y * 480 + x)] ? 1 : 0;
        inked += ink >= 20 ? 1 : 0;
      }
      CHECK(texts > 0 && inked == texts, name);
      if (texts == 0 || inked != texts)
        std::printf("  row %d (%s), row %zu selected: %d text(s), %d visible\n", t.row,
                    page.rows[static_cast<size_t>(t.row)].label.c_str(), sel, texts, inked);
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <crossink checkout> <out dir>\n", argv[0]);
    return 2;
  }
  const std::string src = std::string(argv[1]) + "/lib/EpdFont/builtinFonts/source/";
  const std::string out = argv[2];
  FT_Init_FreeType(&ft);
  // The faces come from core/EndPageLayout's fontSpec, the table the device registers its fonts from.
  for (int i = 0; i < static_cast<int>(Font::COUNT); ++i) {
    const FontSpec spec = fontSpec(static_cast<Font>(i));
    const std::string dir = spec.family == Family::Bitter ? "Bitter/Bitter-" : "LexendDeca/LexendDeca-";
    Face& face = faces[i];
    face.ppem = ppem(spec.points);
    face.regular = load(src + dir + (spec.bold ? "Bold" : spec.italic ? "Italic" : "Regular") + ".ttf", face.ppem);
    face.bold = load(src + dir + (spec.italic ? "BoldItalic" : "Bold") + ".ttf", face.ppem);
    face.italic = load(src + dir + (spec.bold ? "BoldItalic" : "Italic") + ".ttf", face.ppem);
  }
  const Metrics m = metrics();

  const std::string DOT = " \xC2\xB7 ";
  const std::string book = "The Lighthouse Keepers" + DOT + "Mara Quill";
  // The strings orbify/EndPage.cpp's labelRow() gives each row (english.yaml).
  Row finished = row(RowRole::Status, "Finished", "sends at next sync", "Undo");
  finished.check = true;
  const Row rating = row(RowRole::Rating, "Your rating", "tap a star");
  const Row home = row(RowRole::Home, "Home");
  std::vector<Scene> scenes;
  {
    Scene s{"eob-x4pro-online.png", {}};
    s.page.title = "The End";
    s.page.subtitle = book;
    s.page.seriesLine = "Book 2 of Harbour Lights";  // EndPage::page(), STR_ORBIFY_BOOK_N_OF
    s.page.touch = true;
    s.page.rating = 4;
    s.page.rows = {finished, rating,
                   row(RowRole::Plain, "Book 3" + DOT + "The Storm Signal", "On BookOrbit" + DOT + "Download & open", "", "Next in series"),
                   row(RowRole::Plain, "Fog Days", "On this reader" + DOT + "Open", "", "Also by Mara Quill"),
                   row(RowRole::Plain, "The Salt Road", "On BookOrbit" + DOT + "Download & open"),
                   row(RowRole::Plain, "All books by Mara Quill", "", "\xE2\x80\xBA"), home};
    scenes.push_back(s);
  }
  {
    Scene s{"eob-x4pro-offline.png", {}};
    s.page.title = "The End";
    s.page.subtitle = book;
    s.page.touch = true;
    s.page.rating = 0;
    s.page.rows = {finished, rating,
                   row(RowRole::Info, "Book 3 of Harbour Lights", "Connect to see what's next", "", "Next in series", false),
                   row(RowRole::Plain, "Fog Days", "On this reader" + DOT + "Open", "", "Continue with"),
                   row(RowRole::Plain, "The Salt Road", "On this reader" + DOT + "Open"),
                   row(RowRole::Plain, "All books by Mara Quill", "", "\xE2\x80\xBA"), home};
    scenes.push_back(s);
  }
  {
    Scene s{"eob-x4pro-not-finished.png", {}};
    s.page = scenes[1].page;
    s.page.rows[0] = row(RowRole::Status, "Not finished", "", "Mark finished");
    s.page.rows[1] = row(RowRole::Rating, "Your rating", "rate it once it's finished", "", "", false);
    scenes.push_back(s);
  }
  {
    Scene s{"eob-x4-buttons.png", {}};
    s.page = scenes[0].page;
    s.page.touch = false;
    s.page.selected = 1;
    s.page.rows[1].sub = "Left/Right, then Confirm";
    scenes.push_back(s);
  }

  // The next book's cover at the left of the Next row (X4 Pro and X4, the card has its version).
  const size_t NEXT_ROW = 2;
  {
    Scene s{"eob-x4pro-cover.png", {}};
    s.page = scenes[0].page;
    s.page.rows[NEXT_ROW].image = "/.crosspoint/orbify_series/103_0000abcd_60x90.bmp";
    // With the series line and the cover the X4 Pro's rows run past the page: the device's fit()
    // (core/EndPagePlan) drops the last suggestion first.
    s.page.rows.erase(s.page.rows.begin() + 4);
    scenes.push_back(s);
  }
  {
    Scene s{"eob-x4-cover.png", {}};
    s.page = scenes.back().page;
    s.page.touch = false;
    s.page.selected = static_cast<int>(NEXT_ROW);
    scenes.push_back(s);
  }

  const char* const touchHints[4] = {"Back", "Open", "Up", "Down"};
  for (Scene& s : scenes) {
    Canvas cv(480, 800);
    const int area = cv.h - 40;
    const Layout layout = orbify::eob::layout(s.page, m, cv.w, area);
    draw(cv, layout);
    hints(cv, touchHints);
    cv.png(out + "/" + s.file);
    if (s.page.touch) touchRules(layout, s.page, area, s.file);
    // Every row of these scenes fits a 480x800 X4 Pro.
    size_t texts = 0;
    for (const Op& op : layout.ops) texts += op.kind == Op::Kind::Text ? 1 : 0;
    CHECK(layout.bottom <= area, s.file);
    CHECK(texts >= s.page.rows.size() + 2, s.file);
    // No row is lost: every enabled row the page holds is laid out (Home included), so a page whose rows
    // run past the screen fails here rather than dropping Home.
    for (size_t r = 0; r < s.page.rows.size(); ++r) {
      if (!s.page.rows[r].enabled) continue;  // a dimmed row is drawn but has no target
      bool laid = false;
      for (const Target& t : layout.targets) laid = laid || t.row == static_cast<int>(r);
      CHECK(laid, s.file);
      if (!laid) std::printf("  %s: row %zu (%s) not laid out\n", s.file, r, s.page.rows[r].label.c_str());
    }
  }
  // Visible text on every row, each row selected in turn, on touch and button readers.
  for (const Scene& s : scenes) {
    for (const bool touch : {true, false}) {
      Page p = s.page;
      p.touch = touch;
      visibleText(p, m, s.file);
    }
  }
  // Rows keep their place across Undo / Mark finished: the same targets, row for row.
  {
    const Layout a = orbify::eob::layout(scenes[1].page, m, 480, 760);
    const Layout b = orbify::eob::layout(scenes[2].page, m, 480, 760);
    int homeA = -1, homeB = -1;
    for (const Target& t : a.targets) if (t.row == 6) homeA = t.y;
    for (const Target& t : b.targets) if (t.row == 6) homeB = t.y;
    CHECK(homeA > 0 && homeA == homeB, "home stays put");
    // A tap on the status row never reaches Home.
    const Target* status = nullptr;
    for (const Target& t : b.targets) if (t.row == 0) status = &t;
    CHECK(status && hit(b, status->x + status->w / 2, status->y + status->h / 2)->row == 0, "status tap");
    CHECK(homeB - (status->y + status->h) > 200, "home far from status");
  }
  // A tap on a star picks that star.
  {
    const Layout a = orbify::eob::layout(scenes[0].page, m, 480, 760);
    for (const Target& t : a.targets) {
      if (t.star == 0) continue;
      const Target* h = hit(a, t.x + t.w / 2, t.y + t.h / 2);
      CHECK(h && h->star == t.star, "star tap");
    }
  }
  // The cover: one image at the left of the Next row, inside its target, the label and its second
  // line beside it; the row is taller only by what the cover needs, and the rows above stay put.
  for (const bool touch : {true, false}) {
    const char* name = touch ? "cover x4pro" : "cover x4";
    Page with = scenes[0].page, without = scenes[0].page;
    with.touch = without.touch = touch;
    // This fixed row set fills the page without the series line (the device's fit() drops
    // suggestion rows for it; checked below).
    with.seriesLine.clear();
    without.seriesLine.clear();
    with.rows[NEXT_ROW].image = "cover.bmp";
    const Layout a = orbify::eob::layout(with, m, 480, 760);
    const Layout b = orbify::eob::layout(without, m, 480, 760);
    const Op* image = nullptr;
    int images = 0;
    for (const Op& op : a.ops) {
      if (op.kind != Op::Kind::Image) continue;
      image = &op;
      ++images;
    }
    CHECK(images == 1 && image && image->text == "cover.bmp", name);
    for (const Op& op : b.ops) CHECK(op.kind != Op::Kind::Image, name);
    const Target* nextT = nullptr;
    const Target* rowWithout = nullptr;
    for (const Target& t : a.targets) if (t.row == static_cast<int>(NEXT_ROW)) nextT = &t;
    for (const Target& t : b.targets) if (t.row == static_cast<int>(NEXT_ROW)) rowWithout = &t;
    CHECK(nextT && rowWithout && image, name);
    if (!nextT || !rowWithout || !image) continue;
    CHECK(image->x == MARGIN + ROW_PAD && image->w == COVER_WIDTH && image->h == COVER_HEIGHT, name);
    CHECK(image->y >= nextT->y + COVER_PAD - 1 && image->y + image->h <= nextT->y + nextT->h - COVER_PAD + 1, name);
    CHECK(nextT->y == rowWithout->y && nextT->h == std::max(rowWithout->h, COVER_PAD + COVER_HEIGHT + COVER_PAD), name);
    // Label and sub line start right of the cover, at the same x, both inside the row.
    int texts = 0;
    for (const Op& op : a.ops) {
      if (op.kind != Op::Kind::Text || op.y < nextT->y || op.y >= nextT->y + nextT->h) continue;
      ++texts;
      CHECK(op.x == image->x + COVER_WIDTH + COVER_GAP, name);
      CHECK(textWidth(nullptr, op.font, op.bold, op.text.c_str()) + op.x <= 480 - MARGIN - ROW_PAD, name);
    }
    CHECK(texts == 2, name);
    // Every target above the Next row is where it was without the cover.
    for (size_t k = 0; k < a.targets.size() && k < b.targets.size(); ++k) {
      if (a.targets[k].row >= static_cast<int>(NEXT_ROW)) break;
      CHECK(a.targets[k].y == b.targets[k].y && a.targets[k].h == b.targets[k].h, name);
    }
    // Home stays put across Undo / Mark finished with the cover too.
    Page unfinished = with;
    unfinished.rows[0] = row(RowRole::Status, "Not finished", "", "Mark finished");
    unfinished.rows[1] = row(RowRole::Rating, "Your rating", "rate it once it's finished", "", "", false);
    const Layout u = orbify::eob::layout(unfinished, m, 480, 760);
    int homeA = -1, homeU = -1;
    const int homeRow = static_cast<int>(with.rows.size()) - 1;
    for (const Target& t : a.targets) if (t.row == homeRow) homeA = t.y;
    for (const Target& t : u.targets) if (t.row == homeRow) homeU = t.y;
    CHECK(homeA > 0 && homeA == homeU, name);
  }
  // The series line under the book line ("Book 2 of Harbour Lights", mockups 1-5): one Small line
  // more of header, centred, inside the margins.
  {
    Page with = scenes[0].page, without = scenes[0].page;
    without.seriesLine.clear();
    CHECK(orbify::eob::headerHeight(with, m) == orbify::eob::headerHeight(without, m) + m.lineHeight[static_cast<int>(Font::Small)],
          "series line height");
    const Layout a = orbify::eob::layout(with, m, 480, 760);
    int found = 0;
    for (const Op& op : a.ops) {
      if (op.kind != Op::Kind::Text || op.text != with.seriesLine) continue;
      ++found;
      CHECK(op.x >= MARGIN && op.x + textWidth(nullptr, op.font, op.bold, op.text.c_str()) <= 480 - MARGIN, "series line inside");
    }
    CHECK(found == 1, "series line drawn");
  }
  // Long titles are cut with an ellipsis, never drawn past the row.
  {
    const std::string cut = ellipsize(m, Font::Row, false, std::string(80, 'W'), 200);
    CHECK(textWidth(nullptr, Font::Row, false, cut.c_str()) <= 200, "ellipsis");
    CHECK(cut.size() > 3 && cut.compare(cut.size() - 3, 3, "\xE2\x80\xA6") == 0, "ellipsis");
  }
  std::printf("eob-render: %d passed, %d failed (%s)\n", passed, failed, out.c_str());
  return failed ? 1 : 0;
}
