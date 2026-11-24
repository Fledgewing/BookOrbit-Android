#include "SleepListActivity.h"

#if CROSSINK_TAILNET_ORBIFY_SLEEP

#include <GfxRenderer.h>
#include <I18n.h>

#include <new>

#include "MappedInputManager.h"
#include "SleepSettings.h"
#include "components/TouchHeaderBackButton.h"
#include "components/UITheme.h"
#include "components/UIThemeTokens.h"
#include "components/UiAppHelpers.h"

namespace fui = freeink::ui;
namespace {
constexpr fui::ActionId ACTION_ROW = 1;
}

SleepListActivity::SleepListActivity(GfxRenderer& renderer, MappedInputManager& mappedInput, const bool pick)
    : Activity("OrbifySleepList", renderer, mappedInput),
      pick(pick),
      uiTarget(makeUiTarget(renderer)),
      app(uiTarget, uiTarget.deviceContext()) {}

void SleepListActivity::onEnter() {
  Activity::onEnter();
  OrbifySleep::choices(pick, labels, items);
  rowItems.reset(new (std::nothrow) fui::ListItem[count()]);
  if (!rowItems) {
    finish();
    return;
  }
  for (int i = 0; i < count(); ++i) {
    rowItems[i].label = labels[i].c_str();
    rowItems[i].actionValue = static_cast<int16_t>(i);
  }
  selectedIndex = topIndex = 0;
  visibleRows = 1;
  uiReady = false;
  applySharedUiTheme(app, uiTarget);
  app.on(ACTION_ROW, &SleepListActivity::onRowEvent, this);
  app.setScreen(&SleepListActivity::listScreen, this);
  requestUpdate();
}

void SleepListActivity::toggleSelected() {
  if (selectedIndex >= 0 && selectedIndex < static_cast<int>(items.size())) {
    OrbifySleep::toggle(pick, items[selectedIndex]);
  }
  app.clearTapFlash();
  requestUpdate();
}

void SleepListActivity::onRowEvent(const fui::ActionEvent& event, void* user) {
  auto* self = static_cast<SleepListActivity*>(user);
  if (event.value < 0 || event.value >= self->count()) return;
  self->selectedIndex = event.value;
  self->toggleSelected();
}

void SleepListActivity::loop() {
  if (TouchHeaderBackButton::wasTapped(mappedInput, renderer) ||
      mappedInput.wasPressed(MappedInputManager::Button::Back)) {
    finish();
    return;
  }
  if (uiReady) {
    const auto snapshot = touchSnapshotFrom(mappedInput);
    if (snapshot.touchPressed || snapshot.touchReleased) {
      const auto event = app.route(snapshot);
      if (app.invalidated()) requestUpdate();
      if (event) return;
    }
  }
  if (mappedInput.wasReleased(MappedInputManager::Button::Confirm)) {
    toggleSelected();
    return;
  }
  const int n = count();
  const auto swipe = mappedInput.wasSwipe();
  if (swipe == MappedInputManager::SwipeDir::Up || swipe == MappedInputManager::SwipeDir::Down) {
    const int next =
        scrollListBy(topIndex, swipe == MappedInputManager::SwipeDir::Up ? visibleRows : -visibleRows, visibleRows, n);
    if (next != topIndex) {
      topIndex = next;
      requestUpdate();
    }
    return;
  }
  const auto move = [this, n](const int index) {
    selectedIndex = index;
    topIndex = followListSelection(selectedIndex, topIndex, visibleRows, n);
    requestUpdate();
  };
  buttonNavigator.onNextRelease([this, n, &move] { move(ButtonNavigator::nextIndex(selectedIndex, n)); });
  buttonNavigator.onPreviousRelease([this, n, &move] { move(ButtonNavigator::previousIndex(selectedIndex, n)); });
  buttonNavigator.onNextContinuous(
      [this, n, &move] { move(ButtonNavigator::nextPageIndex(selectedIndex, n, visibleRows)); });
  buttonNavigator.onPreviousContinuous(
      [this, n, &move] { move(ButtonNavigator::previousPageIndex(selectedIndex, n, visibleRows)); });
}

void SleepListActivity::listScreen(UiApp::ScreenType& screen, void* user) {
  static_cast<SleepListActivity*>(user)->buildListScreen(screen);
}

void SleepListActivity::buildListScreen(UiApp::ScreenType& screen) {
  const auto& metrics = UITheme::getInstance().getMetrics();
  setUiContentMargin(screen, renderer,
                     fui::Insets{static_cast<int16_t>(TouchHeaderBackButton::contentTop(renderer, mappedInput)), 0,
                                 static_cast<int16_t>(UITheme::getButtonHintsReserve(renderer)), 0});
  screen.spacer(static_cast<int16_t>(metrics.verticalSpacing));
  const int n = count();
  for (int i = 0; i < n; ++i) {
    const bool real = i < static_cast<int>(items.size());
    rowItems[i].toggle = real;
    rowItems[i].toggleChecked = real && OrbifySleep::chosen(pick, items[i]);
  }
  fui::ListProps props;
  props.items = rowItems.get();
  props.count = static_cast<uint16_t>(n);
  props.selectedIndex = static_cast<int16_t>(selectedIndex);
  props.action = ACTION_ROW;
  props.inputMask = fui::InputTouch;
  props.valueInset = 8;
  props.labelText = screen.theme().bodyText;
  const auto rows = configureUiList(props, screen.theme(), screen.body());
  visibleRows = rows > 0 ? rows : 1;
  topIndex = scrollListBy(topIndex, 0, visibleRows, n);
  props.topIndex = static_cast<uint16_t>(topIndex);
  screen.list(props);
}

void SleepListActivity::render(RenderLock&&) {
  renderer.clearScreen();
  const Rect header = TouchHeaderBackButton::headerRect(renderer, mappedInput);
  // The page title, once: the header only.
  if (mappedInput.hasTouchHardware()) {
    TouchHeaderBackButton::draw(renderer, uiTarget, header, OrbifySleep::listTitle(pick), false);
  } else {
    GUI.drawHeader(renderer, header, OrbifySleep::listTitle(pick));
  }
  uiReady = false;
  renderUiApp(app, uiTarget);
  uiReady = true;
  const auto hints =
      mappedInput.mapLabels(mappedInput.withBackArrow(tr(STR_BACK)), tr(STR_SELECT), tr(STR_DIR_UP), tr(STR_DIR_DOWN));
  GUI.drawButtonHints(renderer, hints.btn1, hints.btn2, hints.btn3, hints.btn4);
  renderer.displayBuffer();
}

#endif
