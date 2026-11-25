#pragma once
// BookSync sleep screen (patch 0039): Pick From and Leave Out Scopes, each one list of toggles (R1c,
// X8: Library, the lists for Pick From, every smart scope and collection the last sleep sync saved),
// opened straight from Settings > Display > Sleep (no screen in between). X4 Pro and X4 only.
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

class SleepListActivity final : public Activity {
  using UiApp = freeink::ui::FreeInkApp<16, 4>;

 public:
  // pick: Pick From, else Leave Out Scopes.
  SleepListActivity(GfxRenderer& renderer, MappedInputManager& mappedInput, bool pick);

  void onEnter() override;
  void loop() override;
  void render(RenderLock&&) override;

 private:
  bool pick;
  ButtonNavigator buttonNavigator;
  int selectedIndex = 0;
  freeink::ui::GfxRendererTarget uiTarget;
  UiApp app;
  std::atomic<bool> uiReady{false};
  int visibleRows = 1;
  int topIndex = 0;
  std::vector<std::string> labels;
  std::vector<std::string> items;
  std::unique_ptr<freeink::ui::ListItem[]> rowItems;

  int count() const { return items.empty() ? 1 : static_cast<int>(items.size()); }
  void toggleSelected();
  static void listScreen(UiApp::ScreenType& screen, void* user);
  static void onRowEvent(const freeink::ui::ActionEvent& event, void* user);
  void buildListScreen(UiApp::ScreenType& screen);
};
#endif
