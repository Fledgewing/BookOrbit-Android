// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Orbify: one progress number for a Full refresh on the X4 Pro and X4 (CROSSINK_TAILNET_ORBIFY_MIRROR;
// docs/design/sqlite-cache.md "Xteink: the same rule", XTEINK-BUILD-NOTES "One progress number").
// The start popup the catalog and the Home's refresh boot show once, and the corner badge they keep
// in its own rectangle. The rules (the %, when to repaint, the words) are core/Mirror's.
#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_MIRROR

class GfxRenderer;

namespace OrbifyRefreshBadge {

// "Full refresh in progress · about 37% · you can keep reading and browsing", wrapped in a framed box
// where the theme puts its popups. Draws into the frame; the caller pushes it.
void drawStartPopup(const GfxRenderer& renderer, unsigned percent);
// Initial Home frame, before the scan and connection. No intermediate notices.
void drawPreparing(const GfxRenderer& renderer, bool popup);

// The badge's words right-aligned in its rectangle (x, y, w, h): "37%", "Done", "Done with 2 errors".
void drawBadge(const GfxRenderer& renderer, int x, int y, int w, int h, const char* text);

// Repaints only the badge's rectangle and pushes the frame with a fast refresh: the rest of the frame
// is the last one drawn, so the panel changes only there. The caller holds the render lock.
void repaintBadge(const GfxRenderer& renderer, int x, int y, int w, int h, const char* text);

// The badge's width: the widest "N%" (so the header's title never moves while it counts).
int badgeWidth(const GfxRenderer& renderer);

}  // namespace OrbifyRefreshBadge

#endif  // CROSSINK_TAILNET_ORBIFY_MIRROR
