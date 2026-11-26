// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of BookSync's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#include "BatteryStatsActivity.h"

#if CROSSINK_TAILNET_BATTERY_STATS >= 2

#include <GfxRenderer.h>
#include <I18n.h>

#include <cstdio>

#include "MappedInputManager.h"
#include "components/TouchHeaderBackButton.h"
#include "components/UITheme.h"
#include "fontIds.h"

void BatteryStatsActivity::onEnter() {
  Activity::onEnter();
  runExport();  // opening the page writes a fresh export; the page shows what it found
}

void BatteryStatsActivity::runExport() {
#if CROSSINK_TAILNET_BATTERY_STATS >= 3
  haveSummary = BatteryStats::exportJson(&summary);
  state = haveSummary ? State::Saved : State::Failed;
#else
  state = BatteryStats::exportJson(nullptr) ? State::Saved : State::Failed;
#endif
  requestUpdate();
}

void BatteryStatsActivity::render(RenderLock&&) {
  const int pageHeight = renderer.getScreenHeight();
  renderer.clearScreen();
  const Rect header = TouchHeaderBackButton::headerRect(renderer, mappedInput);
  if (mappedInput.hasTouchHardware()) {
    TouchHeaderBackButton::draw(renderer, header, tr(STR_BATTERY_STATS), false);
  } else {
    GUI.drawHeader(renderer, header, tr(STR_BATTERY_STATS));
  }

  int y = pageHeight / 2 - 20;
#if CROSSINK_TAILNET_BATTERY_STATS >= 3
  if (haveSummary) {
    const int lineHeight = renderer.getLineHeight(UI_10_FONT_ID) + 12;
    y = header.y + header.height + lineHeight;
    char line[64];
    const auto rateLine = [&](const char* label, bool shown, float value, const char* unit) {
      if (shown) {
        snprintf(line, sizeof(line), "%s: %.2f %s", label, static_cast<double>(value), unit);
      } else {
        snprintf(line, sizeof(line), "%s: -", label);
      }
      renderer.drawCenteredText(UI_10_FONT_ID, y, line);
      y += lineHeight;
    };
    if (summary.timeLeft) {
      const unsigned hours = static_cast<unsigned>(summary.timeLeftH + 0.5f);
      snprintf(line, sizeof(line), "%s: %u d %u h", tr(STR_BATTERY_TIME_LEFT), hours / 24, hours % 24);
    } else {
      snprintf(line, sizeof(line), "%s: -", tr(STR_BATTERY_TIME_LEFT));
    }
    renderer.drawCenteredText(UI_10_FONT_ID, y, line, true, EpdFontFamily::BOLD);
    y += lineHeight;
    rateLine(tr(STR_BATTERY_STANDBY_RATE), summary.standby, summary.standbyPctH, "%/h");
    rateLine(tr(STR_BATTERY_READING_RATE), summary.reading, summary.readingPctH, "%/h");
    rateLine(tr(STR_BATTERY_PER_100_PAGES), summary.per100, summary.per100Pages, "%");
    if (!summary.standby || !summary.reading) {
      snprintf(line, sizeof(line), "%s (%.1f h)", tr(STR_BATTERY_NOT_ENOUGH_DATA),
               static_cast<double>(summary.dataHours));
      renderer.drawCenteredText(UI_10_FONT_ID, y, line);
      y += lineHeight;
    }
    y += lineHeight;
  }
#endif
  if (state == State::Saved) {
    renderer.drawCenteredText(UI_10_FONT_ID, y, tr(STR_BATTERY_STATS_SAVED));
    renderer.drawCenteredText(UI_10_FONT_ID, y + 30, BatteryStats::EXPORT_PATH);
  } else if (state == State::Failed) {
    renderer.drawCenteredText(UI_10_FONT_ID, y, tr(STR_BATTERY_STATS_FAILED), true, EpdFontFamily::BOLD);
  }

  const auto labels = mappedInput.mapLabels(mappedInput.withBackArrow(tr(STR_BACK)), "", "", "");
  GUI.drawButtonHints(renderer, labels.btn1, labels.btn2, labels.btn3, labels.btn4);
  renderer.displayBuffer();
}

void BatteryStatsActivity::loop() {
  if (TouchHeaderBackButton::wasTapped(mappedInput, renderer) ||
      mappedInput.wasPressed(MappedInputManager::Button::Back)) {
    finish();
  }
}

#endif  // CROSSINK_TAILNET_BATTERY_STATS >= 2
