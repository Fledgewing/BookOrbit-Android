#pragma once
// BookSync sleep screen extras on the X4 Pro and X4 (docs/design/lock-screen.md L1-L5): the text the
// user typed and the battery level at sleep, in a band below the cover (Bar) or on plates over it
// (Overlay). Geometry only, in panel pixels; the firmware (../SleepScreen.cpp) measures the text and
// draws. The same rules as Android's SleepLayout (SleepScreenLogic.kt); host test sleep_pick_test.cpp.
#include <cstddef>
#include <cstdint>

namespace orbify {
namespace sleep {

enum class Style : uint8_t { Bar, Overlay };
enum class TextPos : uint8_t { Right, Left, Top, Bottom };
enum class Corner : uint8_t { TopLeft, TopRight, BottomLeft, BottomRight };

struct Box {
  int left = 0, top = 0, right = 0, bottom = 0;
  int width() const { return right - left; }
  int height() const { return bottom - top; }
};

inline bool vertical(const TextPos p) { return p == TextPos::Right || p == TextPos::Left; }
inline bool cornerTop(const Corner c) { return c == Corner::TopLeft || c == Corner::TopRight; }
inline bool cornerLeft(const Corner c) { return c == Corner::TopLeft || c == Corner::BottomLeft; }
Corner cornerAt(bool top, bool left);

// L3: 7 % of the panel, 10 % with two lines of text (X4: 56 and 80 px).
int bandHeight(int h, int lines);
// L3d: the plates' inset, 2 % of the short side (X4: 10 px).
int inset(int w, int h);
// L2: the whole cover, centred, in the area above the band.
Box coverBox(int w, int h, int bandH, int imgW, int imgH);
// L3b2: the battery moves to the opposite side when the text would share its corner.
Corner batteryCorner(Corner corner, TextPos position, bool hasText);
// L3b: the text's plate. textW: the longest line as drawn; textH: all lines' height. Right and Left:
// rotated, one line (textH wide, textW tall, at most 90 % of the edge). Top and Bottom: textW wide
// (at most 90 % of the panel), centred.
Box textPlate(int w, int h, TextPos position, int textW, int textH, int pad);
// L3c: the battery's plate in its corner.
Box batteryPlate(int w, int h, Corner corner, int bw, int bh, int pad);
// The longest a line of text may be: Bar, beside the battery; Right/Left 90 % of the edge;
// Top/Bottom 90 % of the width.
int maxTextWidth(int w, int h, Style style, TextPos position, int pad, int batteryW);
// L5: lines of text: the Bar and Top/Bottom wrap to 2, Right/Left keep 1.
inline int maxLines(const Style style, const TextPos position) {
  return style == Style::Overlay && vertical(position) ? 1 : 2;
}

// Bar: what goes where in the band (its top rule, the text's left edge and the battery's right).
struct BarLayout {
  Box band;       // under the 2-px rule
  int textLeft;   // the text, left-aligned, vertically centred
  int batteryRight;
};
BarLayout bar(int w, int h, int bandH);

}  // namespace sleep
}  // namespace orbify
