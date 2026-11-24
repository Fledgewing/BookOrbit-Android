#pragma once
// Orbify sleep screen (patch 0039): Leave Out Scopes as one list of toggles, every smart scope and
// collection the last sleep sync saved, opened straight from Settings > Display > Sleep (no screen
// in between). X4 Pro and X4 only.
#include <CrossInkTailnetCuts.h>

#if CROSSINK_TAILNET_ORBIFY_SLEEP
#include <FreeInkApp.h>
#include <FreeInkUIGfxRenderer.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "activities/Activity.h"
#include "util/ButtonNavigator.h"

class SleepScopesActivity final : public Activity {
  using UiApp = freeink::ui::FreeInkApp<16, 4>;

 public:
  SleepScopesActivity(GfxRenderer& renderer, MappedInputManager& mappedInput);

  void onEnter() override;
  void loop() override;
  void render(RenderLock&&) override;

 private:
  ButtonNavigator buttonNavigator;
  int selectedIndex = 0;
  freeink::ui::GfxRendererTarget uiTarget;
  UiApp app;
  std::atomic<bool> uiReady{false};
  int visibleRows = 1;
  int topIndex = 0;
  std::vector<std::string> labels;
  std::vector<std::string> rules;
  std::unique_ptr<freeink::ui::ListItem[]> rowItems;

  int count() const { return rules.empty() ? 1 : static_cast<int>(rules.size()); }
  void toggleSelected();
  static void listScreen(UiApp::ScreenType& screen, void* user);
  static void onRowEvent(const freeink::ui::ActionEvent& event, void* user);
  void buildListScreen(UiApp::ScreenType& screen);
};
#endif
