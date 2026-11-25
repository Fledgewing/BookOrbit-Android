// SPDX-License-Identifier: GPL-3.0-or-later
// Included inside the catalog's MIRROR guard. Keep the displayed view in place while the same
// idle-loop walk used by Full refresh updates the saved reply. Navigation reads it on next open.
void BookOrbitCatalogBrowserActivity::refreshView(const bool full) {
  const unsigned long began = millis();
  LOG_INF("BookOrbit", "Catalog: %s of view %d", full ? "Full refresh" : "Refresh", static_cast<int>(navLevel));
  if (mirrorWalk.active() && !mirrorWalk.finished()) return;
  if (full) {
    mirrorWalk.begin(/*userStarted=*/true);
    mirrorPopupUntil = millis() + orbify::mirror::START_POPUP_MS;
    mirrorPopupArmed = false; mirrorPopupLogged = false;
    syncMirrorShown(); requestUpdate();
    return;
  }
  // Joining belongs to the next idle turn too: the tap/hold always returns to its view first.
  refreshConnectPending = WiFi.status() != WL_CONNECTED;
  if (!refreshConnectPending) {
    offlineSession = false;
    sdFontSystem.releaseForNetwork(renderer);
  }
  if (full) {
    mirrorWalk.begin(/*userStarted=*/true);
  } else {
    using orbify::mirror::Kind;
    orbify::mirror::Step view;
    if (navLevel == NavLevel::Root) view = {Kind::Root, ""};
    else if (navLevel == NavLevel::FacetList) view = {Kind::Section, facetSectionId};
    else {
      if (listIsLocal) return;
      orbify::mirror::FacetQuery q;
      q.sort = listQuery.sort; q.order = listQuery.order; q.readStatus = listQuery.readStatus;
      q.shelf = listQuery.shelf; q.query = listQuery.query; q.author = listQuery.author;
      q.seriesId = listQuery.seriesId; q.series = listQuery.series;
      q.collectionId = listQuery.collectionId; q.smartScopeId = listQuery.smartScopeId; q.libraryId = listQuery.libraryId;
      view = {Kind::Books, orbify::mirror::encodeQuery(q)};
    }
    const int page = navLevel == NavLevel::Books ? topIndex / std::max(1, listPageSize) + 1 : facetPage;
    mirrorWalk.beginView(view, page);
    regularRefresh = true;
    refreshing = true;
  }
  mirrorResumeChecked = true;
  {
    RenderLock lock(*this);
    mirrorPopupUntil = full ? millis() + orbify::mirror::START_POPUP_MS : 0;
    mirrorPopupLogged = false;
    mirrorPopupArmed = false;
    mirrorBadgePainted = -1;
  }
  syncMirrorShown();
  mirrorInputAt = millis();
  requestUpdate();
  LOG_INF("ORB", "Refresh phase: queued elapsed=%lums; foreground returned", millis() - began);
}
