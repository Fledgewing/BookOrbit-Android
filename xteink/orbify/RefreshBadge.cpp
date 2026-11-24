#include "RefreshBadge.h"

#if CROSSINK_TAILNET_ORBIFY_MIRROR

#include <GfxRenderer.h>

#include <algorithm>
#include <cstdio>

#include "components/UITheme.h"
#include "fontIds.h"

namespace OrbifyRefreshBadge {

void drawStartPopup(const GfxRenderer& renderer, const unsigned percent) {
  char text[96];
  snprintf(text, sizeof(text), "Full refresh in progress \xC2\xB7 about %u%% \xC2\xB7 you can keep reading and browsing",
           percent);
  const auto& metrics = UITheme::getInstance().getMetrics();
  const Rect safe = UITheme::getInstance().getScreenSafeArea(renderer, true, false);
  const int frame = std::max(1, metrics.popupFrameThickness);
  const int marginX = metrics.popupMarginX;
  const int marginY = metrics.popupMarginY;
  const int w = std::max(1, safe.width - 2 * (metrics.contentSidePadding + frame));
  // Wrapped, never cut: three lines hold it at the narrowest width.
  const auto lines = renderer.wrappedText(UI_12_FONT_ID, text, std::max(1, w - 2 * marginX), 3, EpdFontFamily::BOLD);
  const int lineH = renderer.getLineHeight(UI_12_FONT_ID);
  const int h = static_cast<int>(lines.size()) * lineH + 2 * marginY;
  const int x = safe.x + (safe.width - w) / 2;
  const int y = std::clamp(safe.y + static_cast<int>(safe.height * metrics.popupTopOffsetRatio), safe.y + frame,
                           std::max(safe.y + frame, safe.y + safe.height - h - frame));
  renderer.fillRect(x - frame, y - frame, w + 2 * frame, h + 2 * frame, true);
  renderer.fillRect(x, y, w, h, false);
  int lineY = y + marginY;
  for (const auto& line : lines) {
    const int lw = renderer.getTextWidth(UI_12_FONT_ID, line.c_str(), EpdFontFamily::BOLD);
    renderer.drawText(UI_12_FONT_ID, x + (w - lw) / 2, lineY, line.c_str(), true, EpdFontFamily::BOLD);
    lineY += lineH;
  }
}

void drawBadge(const GfxRenderer& renderer, const int x, const int y, const int w, const int h, const char* text) {
  (void)h;
  const int tw = renderer.getTextWidth(SMALL_FONT_ID, text);
  renderer.drawText(SMALL_FONT_ID, x + std::max(0, w - tw), y, text);
}

void repaintBadge(const GfxRenderer& renderer, const int x, const int y, const int w, const int h, const char* text) {
  renderer.fillRect(x, y, w, h, false);
  drawBadge(renderer, x, y, w, h, text);
  renderer.displayBuffer(HalDisplay::FAST_REFRESH);
}

int badgeWidth(const GfxRenderer& renderer) { return renderer.getTextWidth(SMALL_FONT_ID, "100%"); }

}  // namespace OrbifyRefreshBadge

#endif  // CROSSINK_TAILNET_ORBIFY_MIRROR
