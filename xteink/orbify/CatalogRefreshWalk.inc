// SPDX-License-Identifier: GPL-3.0-or-later
void BookOrbitCatalogBrowserActivity::tickMirror() {
  constexpr unsigned long IDLE_MS = 1000;
  const unsigned long now = millis();
  const bool input = mappedInput.hasPendingActivity() || mappedInput.wasAnyPressed() || mappedInput.wasAnyReleased();
  if (input) mirrorInputAt = now;
  // The press that started the Full refresh does not close its popup: the next one does.
  if (mirrorPopupUntil != 0 && !input) mirrorPopupArmed = true;
  if (mirrorPopupUntil != 0 && ((mirrorPopupArmed && input) || now >= mirrorPopupUntil)) {
    {
      RenderLock lock(*this);
      mirrorPopupUntil = 0;
    }
    LOG_INF("BookOrbit", "Catalog: Full refresh popup closed (%s)", input ? "a press" : "timeout");
    requestUpdate();
  }
  if (!mirrorWalk.active() && OrbifyMirror::requested()) {
    mirrorWalk.begin(); syncMirrorShown(); requestUpdate();
  }
  if (!mirrorWalk.active()) return;
  // Full refresh is owned by the main-loop worker, wherever navigation goes.
  if (mirrorWalk.full()) {
    const auto status = OrbifyMirror::snapshot();
    const unsigned old = mirrorShown.percent;
    const bool wasFinished = mirrorShown.finished;
    syncMirrorShown();
    if (status.finished && !wasFinished) {
      mirrorDoneUntil = now + orbify::mirror::DONE_MS;
      mirrorPopupUntil = 0;
      requestUpdate();
      LOG_INF("ORB", "Full refresh final: %s", status.result.c_str());
      LOG_INF("BookOrbit", "Catalog: Full refresh done (%u errors)", static_cast<unsigned>(status.failures));
    }
    if (!status.finished) { if (old != status.percent) paintMirrorBadge(); return; }
  }
  if (mirrorWalk.finished()) {
    if (now >= mirrorDoneUntil) {
      mirrorWalk.end();
      syncMirrorShown();
      requestUpdate();  // the stamp comes back
    }
    return;
  }
  if (state != BrowserState::BROWSING || listOptions || now - mirrorInputAt < IDLE_MS) return;
  if (refreshConnectPending) {
    refreshConnectPending = false;
    const unsigned long began = millis();
    const bool connected = SavedWifiConnect::connect([] { return false; });
    LOG_INF("ORB", "Refresh phase: connect elapsed=%lums ok=%d", millis() - began, connected);
    if (connected) { offlineSession = false; sdFontSystem.releaseForNetwork(renderer); }
  }
  if (WiFi.status() != WL_CONNECTED) {
    if (!refreshPaused) LOG_INF("BookOrbit", "Catalog: Full refresh paused at %u%% (no network)", mirrorWalk.percent());
    if (!refreshPaused) { refreshPaused = true; requestUpdate(); }
    return;
  }
  if (refreshPaused) { refreshPaused = false; LOG_INF("ORB", "Refresh: Wi-Fi returned; resuming"); requestUpdate(); }
  mirrorWalk.step();
  syncMirrorShown();
  if (mirrorWalk.finished()) {
    const bool wasRegular = regularRefresh;
    if (regularRefresh) {
      regularRefresh = false;
      refreshing = false;
      BookOrbitCatalogListCache::clear();
      LOG_INF("BookOrbit", "Catalog: Refresh done (%u errors); saved replies ready", static_cast<unsigned>(mirrorWalk.failures()));
    }
#if CROSSINK_TAILNET_ORBIFY_SLEEP
    // A short best-effort slice on a connection already up; the normal/sleep sync has 40 s.
    OrbifySleep::topUp(APP_STATE.openEpubPath, nullptr, 1500);
    OrbifySleep::decodeCovers(renderer, nullptr);
#endif
    {
      // Open mode serves the new saved reply. Keep network work in the walk, never in the tap.
      OrbifyCache::ScopedMode saved(orbify::cache::Mode::Open);
      const int wantedSelector = selectorIndex, wantedTop = topIndex;
      // The session list was cleared above: rebuild it from the walk's saved reply, as
      // the facet/book loaders do. loadRoot(false) returns before reading that reply.
      if (navLevel == NavLevel::Root) loadRoot();
      else if (navLevel == NavLevel::FacetList) { const auto id = facetSectionId; const auto title = facetTitle; loadFacetEntries(id, title, facetPage); }
      else if (!listIsLocal) { const auto q = listQuery; const auto title = listTitle; loadBooks(q, title, topIndex / std::max(1, listPageSize) + 1, booksFromFacet); }
      if (!entries.empty()) {
        RenderLock lock(*this);
        selectorIndex = std::max(windowStart, std::min(wantedSelector, loadedEnd() - 1));
        topIndex = std::max(windowStart, std::min(wantedTop, loadedEnd() - visibleRows));
      }
    }
    if (wasRegular) {
      mirrorWalk.end(); syncMirrorShown(); mirrorDoneUntil = 0; mirrorPopupUntil = 0;
      requestUpdate();
      return;
    }
    mirrorDoneUntil = millis() + orbify::mirror::DONE_MS;
    {
      RenderLock lock(*this);
      mirrorPopupUntil = 0;  // "Done" alone
    }
    LOG_INF("BookOrbit", "Catalog: Full refresh done (%u errors)", static_cast<unsigned>(mirrorWalk.failures()));
    requestUpdate();  // "Done" / "Done with N errors" is wider than the %: the header is drawn again
    return;
  }
  paintMirrorBadge();
}

