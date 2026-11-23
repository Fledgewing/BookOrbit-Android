#include "EndPageLayout.h"

#include <cmath>

namespace orbify::eob {

namespace {

int lh(const Metrics& m, Font f) { return m.lineHeight[static_cast<int>(f)]; }

int width(const Metrics& m, Font f, bool bold, const std::string& s) {
  return m.textWidth ? m.textWidth(m.ctx, f, bold, s.c_str()) : static_cast<int>(s.size()) * lh(m, f) / 2;
}

Op text(Font f, int x, int y, std::string s, bool bold = false, bool italic = false) {
  Op op;
  op.kind = Op::Kind::Text;
  op.font = f;
  op.x = x;
  op.y = y;
  op.bold = bold;
  op.italic = italic;
  op.text = std::move(s);
  return op;
}

Op rect(Op::Kind kind, int x, int y, int w, int h, bool white = false) {
  Op op;
  op.kind = kind;
  op.x = x;
  op.y = y;
  op.w = w;
  op.h = h;
  op.white = white;
  return op;
}

// Height of the row itself, without its heading.
int bodyHeight(const Row& row, const Metrics& m, bool touch) {
  int h = ROW_PAD + lh(m, Font::Row) + ROW_PAD;
  if (row.role == RowRole::Rating) h = ROW_PAD + (touch ? STAR_CELL : lh(m, Font::Row) + 8) + ROW_PAD;
  // The status and rating rows always keep their second line, so Undo / Mark finished never
  // moves the rows below them.
  if (!row.sub.empty() || row.role == RowRole::Status || row.role == RowRole::Rating) h += 2 + lh(m, Font::Small);
  if (!row.image.empty() && h < COVER_PAD + COVER_HEIGHT + COVER_PAD) h = COVER_PAD + COVER_HEIGHT + COVER_PAD;
  if (touch && h < MIN_TOUCH_ROW) h = MIN_TOUCH_ROW;
  return h;
}

int headingHeight(const Row& row, const Metrics& m) { return row.heading.empty() ? 0 : 6 + lh(m, Font::Heading) + 2; }

std::string upper(const std::string& s) {
  std::string out = s;
  for (char& c : out) {
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
  }
  return out;
}

}  // namespace

int rowHeight(const Row& row, const Metrics& m, const bool touch) {
  return headingHeight(row, m) + bodyHeight(row, m, touch);
}

int headerHeight(const Page& page, const Metrics& m) {
  int h = 28 + lh(m, Font::Title) + 6;
  if (!page.subtitle.empty()) h += lh(m, Font::Subtitle);
  if (!page.seriesLine.empty()) h += lh(m, Font::Small);
  return h + 16;
}

std::string ellipsize(const Metrics& m, const Font font, const bool bold, const std::string& text, const int maxWidth) {
  if (maxWidth <= 0) return std::string();
  if (width(m, font, bold, text) <= maxWidth) return text;
  static const char* const ELLIPSIS = "\xE2\x80\xA6";
  std::string cut = text;
  while (!cut.empty()) {
    // Drop one UTF-8 character (its continuation bytes first).
    size_t end = cut.size() - 1;
    while (end > 0 && (static_cast<unsigned char>(cut[end]) & 0xC0) == 0x80) --end;
    cut.resize(end);
    while (!cut.empty() && cut.back() == ' ') cut.pop_back();
    if (width(m, font, bold, cut + ELLIPSIS) <= maxWidth) return cut + ELLIPSIS;
  }
  return ELLIPSIS;
}

void starPoints(const int cx, const int cy, const int radius, int out[20]) {
  const double inner = radius * 0.42;
  for (int i = 0; i < 10; ++i) {
    const double r = (i % 2 == 0) ? radius : inner;
    const double a = -M_PI / 2 + i * M_PI / 5;
    out[2 * i] = cx + static_cast<int>(std::lround(r * std::cos(a)));
    out[2 * i + 1] = cy + static_cast<int>(std::lround(r * std::sin(a)));
  }
}

void checkStrokes(const int x, const int y, const int size, int out[8]) {
  const int midX = x + size * 2 / 5, bottom = y + size - 1;
  out[0] = x;
  out[1] = y + size / 2;
  out[2] = midX;
  out[3] = bottom;
  out[4] = midX;
  out[5] = bottom;
  out[6] = x + size - 1;
  out[7] = y;
}

Layout layout(const Page& page, const Metrics& m, const int areaWidth, const int areaHeight) {
  Layout out;
  const int inner = areaWidth - 2 * MARGIN;

  // Title block, centred.
  int y = 28;
  {
    const std::string title = ellipsize(m, Font::Title, true, page.title, inner);
    out.ops.push_back(text(Font::Title, (areaWidth - width(m, Font::Title, true, title)) / 2, y, title, true));
    y += lh(m, Font::Title) + 6;
  }
  if (!page.subtitle.empty()) {
    const std::string sub = ellipsize(m, Font::Subtitle, false, page.subtitle, inner);
    out.ops.push_back(text(Font::Subtitle, (areaWidth - width(m, Font::Subtitle, false, sub)) / 2, y, sub, false, true));
    y += lh(m, Font::Subtitle);
  }
  if (!page.seriesLine.empty()) {
    const std::string line = ellipsize(m, Font::Small, false, page.seriesLine, inner);
    out.ops.push_back(text(Font::Small, (areaWidth - width(m, Font::Small, false, line)) / 2, y, line, false));
    y += lh(m, Font::Small);
  }
  y += 12;
  out.ops.push_back(rect(Op::Kind::FillRect, MARGIN, y, inner, 2));
  y += 4;

  for (size_t i = 0; i < page.rows.size(); ++i) {
    const Row& row = page.rows[i];
    const int body = bodyHeight(row, m, page.touch);
    if (y + headingHeight(row, m) + body > areaHeight) break;
    if (!row.heading.empty()) {
      y += 6;
      out.ops.push_back(text(Font::Heading, MARGIN + ROW_PAD, y, upper(row.heading), true));
      y += lh(m, Font::Heading) + 2;
    }
    const bool selected = static_cast<int>(i) == page.selected && row.enabled;
    if (selected) out.ops.push_back(rect(Op::Kind::FillRect, MARGIN, y, inner, body));

    const int left = MARGIN + ROW_PAD;
    const int right = MARGIN + inner - ROW_PAD;
    int textTop = y + ROW_PAD;
    int labelRight = right;
    if (row.role == RowRole::Rating) {
      // Stars at the right: five cells (touch: 56 px targets), each with its own target.
      const int cell = page.touch ? STAR_CELL : lh(m, Font::Row) + 8;
      const int radius = page.touch ? STAR_RADIUS : cell / 2 - 3;
      const int starsLeft = right - 5 * cell;
      const int cy = y + ROW_PAD + cell / 2;
      for (int s = 1; s <= 5; ++s) {
        Op star;
        star.kind = Op::Kind::Star;
        star.x = starsLeft + (s - 1) * cell + cell / 2;
        star.y = cy;
        star.w = radius;
        star.filled = s <= page.rating;
        star.white = selected;
        star.grey = !row.enabled;
        out.ops.push_back(star);
        if (page.touch && row.enabled) {
          Target t;
          t.x = starsLeft + (s - 1) * cell;
          t.y = y;
          t.w = cell;
          t.h = body;
          t.row = static_cast<int>(i);
          t.star = s;
          out.targets.push_back(t);
        }
      }
      labelRight = starsLeft - 8;
      textTop = cy - lh(m, Font::Row) / 2;
    } else if (!row.value.empty()) {
      const int vw = width(m, Font::Row, true, row.value);
      Op v = text(Font::Row, right - vw, textTop, row.value, true);
      v.white = selected;
      v.grey = !row.enabled;
      out.ops.push_back(v);
      labelRight = right - vw - 16;
    }
    int labelLeft = left;
    if (!row.image.empty() && row.role != RowRole::Rating) {
      // The cover at the left, centred in the taller row; the label and its second line beside it,
      // centred as a block.
      Op image = rect(Op::Kind::Image, left, y + (body - COVER_HEIGHT) / 2, COVER_WIDTH, COVER_HEIGHT, selected);
      image.text = row.image;
      out.ops.push_back(image);
      labelLeft = left + COVER_WIDTH + COVER_GAP;
      const int block = lh(m, Font::Row) + (row.sub.empty() ? 0 : 2 + lh(m, Font::Small));
      textTop = y + (body - block) / 2;
    }
    if (row.check) {
      const int size = lh(m, Font::Row) * 2 / 3;
      Op check = rect(Op::Kind::Check, left, textTop + (lh(m, Font::Row) - size) / 2, size, size, selected);
      out.ops.push_back(check);
      labelLeft = left + size + 8;
    }
    Op label = text(Font::Row, labelLeft, textTop, ellipsize(m, Font::Row, row.role == RowRole::Status, row.label, labelRight - labelLeft),
                    row.role == RowRole::Status);
    label.white = selected;
    label.grey = !row.enabled;
    out.ops.push_back(label);
    if (!row.sub.empty()) {
      const int subTop = (row.role == RowRole::Rating ? y + ROW_PAD + (page.touch ? STAR_CELL : lh(m, Font::Row) + 8)
                                                     : textTop + lh(m, Font::Row)) + 2;
      const int subLeft = row.image.empty() ? left : labelLeft;
      Op sub = text(Font::Small, subLeft, subTop, ellipsize(m, Font::Small, false, row.sub, right - subLeft));
      sub.white = selected;
      sub.grey = true;
      out.ops.push_back(sub);
    }
    if (!selected) out.ops.push_back(rect(Op::Kind::Line, MARGIN, y + body - 1, inner, 1));

    if (row.enabled && row.role != RowRole::Info) {
      Target t;
      t.x = MARGIN;
      t.y = y;
      t.w = inner;
      t.h = body;
      t.row = static_cast<int>(i);
      out.targets.push_back(t);
    }
    y += body;
  }
  out.bottom = y;
  return out;
}

const Target* hit(const Layout& layout, const int x, const int y) {
  // Stars come before their row's own target, so they win.
  for (const Target& t : layout.targets) {
    if (x >= t.x && x < t.x + t.w && y >= t.y && y < t.y + t.h) return &t;
  }
  return nullptr;
}

}  // namespace orbify::eob
