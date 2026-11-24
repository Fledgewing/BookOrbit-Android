#include "SleepLayout.h"

#include <algorithm>
#include <cmath>

namespace orbify {
namespace sleep {

namespace {
int roundInt(const double v) { return static_cast<int>(std::lround(v)); }
}  // namespace

Corner cornerAt(const bool top, const bool left) {
  if (top) return left ? Corner::TopLeft : Corner::TopRight;
  return left ? Corner::BottomLeft : Corner::BottomRight;
}

int bandHeight(const int h, const int lines) { return roundInt(h * (lines >= 2 ? 0.10 : 0.07)); }

int inset(const int w, const int h) { return roundInt(std::min(w, h) * 0.02); }

Box coverBox(const int w, const int h, const int bandH, const int imgW, const int imgH) {
  const int areaH = h - bandH;
  if (imgW <= 0 || imgH <= 0) return Box{0, 0, w, areaH};
  const double scale = std::min(static_cast<double>(w) / imgW, static_cast<double>(areaH) / imgH);
  const int cw = roundInt(imgW * scale);
  const int ch = roundInt(imgH * scale);
  const int l = (w - cw) / 2;
  const int t = (areaH - ch) / 2;
  return Box{l, t, l + cw, t + ch};
}

Corner batteryCorner(const Corner corner, const TextPos position, const bool hasText) {
  if (!hasText) return corner;
  const bool top = cornerTop(corner);
  const bool left = cornerLeft(corner);
  switch (position) {
    case TextPos::Top:
      return top ? cornerAt(false, left) : corner;
    case TextPos::Bottom:
      return !top ? cornerAt(true, left) : corner;
    case TextPos::Right:
      return !left ? cornerAt(top, true) : corner;
    case TextPos::Left:
      return left ? cornerAt(top, false) : corner;
  }
  return corner;
}

Box textPlate(const int w, const int h, const TextPos position, const int textW, const int textH, const int pad) {
  const int in = inset(w, h);
  if (vertical(position)) {
    const int pw = textH + 2 * pad;
    const int ph = std::min(textW + 2 * pad, roundInt(h * 0.9));
    const int t = (h - ph) / 2;
    if (position == TextPos::Right) return Box{w - in - pw, t, w - in, t + ph};
    return Box{in, t, in + pw, t + ph};
  }
  const int pw = std::min(textW + 2 * pad, roundInt(w * 0.9));
  const int ph = textH + 2 * pad;
  const int l = (w - pw) / 2;
  if (position == TextPos::Top) return Box{l, in, l + pw, in + ph};
  return Box{l, h - in - ph, l + pw, h - in};
}

Box batteryPlate(const int w, const int h, const Corner corner, const int bw, const int bh, const int pad) {
  const int in = inset(w, h);
  const int pw = bw + 2 * pad;
  const int ph = bh + 2 * pad;
  const int l = cornerLeft(corner) ? in : w - in - pw;
  const int t = cornerTop(corner) ? in : h - in - ph;
  return Box{l, t, l + pw, t + ph};
}

int maxTextWidth(const int w, const int h, const Style style, const TextPos position, const int pad,
                 const int batteryW) {
  if (style == Style::Bar) return w - 2 * inset(w, h) - (batteryW > 0 ? batteryW + 2 * pad : 0);
  if (vertical(position)) return roundInt(h * 0.9) - 2 * pad;
  return roundInt(w * 0.9) - 2 * pad;
}

BarLayout bar(const int w, const int h, const int bandH) {
  const int in = inset(w, h);
  return BarLayout{Box{0, h - bandH + 2, w, h}, in, w - in};
}

}  // namespace sleep
}  // namespace orbify
