// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of Orbify's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#pragma once

#include <CrossInkTailnetCuts.h>

#include <cstdint>

// CrossInk-Tailnet: BookOrbit sync while reading (hooked in by the background-sync patch; X4 Pro and X4 Classic).
//
// The reader asks, between page turns, whether a sync is due (observe()); when one is, it
// hands over its position and a background task joins a saved network (Tailscale starts in
// place on the X4s), syncs the book's progress under Smart sync's rules and turns WiFi off
// again. The book stays open throughout. The sync itself is BookOrbitSyncActivity's
// (runInBackground()), so the decision is BookOrbitSmartSync::decide(), exactly as for the
// sleep sync. One line per run is logged under "BOBG".

namespace BookOrbitBackgroundSync {

// The setting (BookOrbitCredentialStore::getBackgroundSync()). Persisted: keep the values.
enum Interval : uint8_t {
  OFF = 0,
  MINUTES_10,
  MINUTES_15,
  MINUTES_30,
  MINUTES_60,
  PAGES_25,
  PAGES_50,
  PAGES_100,
  CHAPTERS_1,
  CHAPTERS_2,
  INTERVAL_COUNT
};

// The reading done since the last sync (or the book was opened) against the setting:
// true when a sync is due. Pure: no clock, no storage.
constexpr bool due(const uint8_t interval, const unsigned long elapsedMs, const uint32_t pageTurns,
                   const uint32_t chapterChanges) {
  switch (interval) {
    case MINUTES_10:
      return elapsedMs >= 10UL * 60UL * 1000UL;
    case MINUTES_15:
      return elapsedMs >= 15UL * 60UL * 1000UL;
    case MINUTES_30:
      return elapsedMs >= 30UL * 60UL * 1000UL;
    case MINUTES_60:
      return elapsedMs >= 60UL * 60UL * 1000UL;
    case PAGES_25:
      return pageTurns >= 25;
    case PAGES_50:
      return pageTurns >= 50;
    case PAGES_100:
      return pageTurns >= 100;
    case CHAPTERS_1:
      return chapterChanges >= 1;
    case CHAPTERS_2:
      return chapterChanges >= 2;
    default:
      return false;
  }
}

#if CROSSINK_TAILNET_BACKGROUND_SYNC
// The setting's value as shown in the BookOrbit settings ("Every 15 min").
void intervalLabel(uint8_t interval, char* out, unsigned outSize);

// The setting is on, Smart sync is on, and there is an account and a saved network.
bool enabled();

// Called by the reader on its main task with the page on screen, when no page turn or
// render is under way. Returns the trigger ("time", "pages", "chapter") when a sync is due
// and the position moved since the last one, else nullptr. Resets for a different book.
const char* observe(const char* epubPath, int spineIndex, int page, unsigned long nowMs);

// The reader's position for a sync, as its own sync menu builds it.
struct Position {
  int spineIndex = 0;
  int page = 0;
  int pageCount = 1;
  bool hasParagraph = false;
  uint16_t paragraphIndex = 0;
  bool hasListItem = false;
  uint16_t listItemIndex = 0;
};

// Starts the background task. False when one is still running or it could not start.
bool start(const char* epubPath, const Position& position, const char* trigger);

// The reader is closing (another screen, sleep): asks a run in progress to stop at its next
// step and waits for it to end, so the sleep sync or the next screen never runs beside it.
void readerClosed();
#endif

}  // namespace BookOrbitBackgroundSync
